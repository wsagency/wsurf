// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Observation

/// One check at a time, in the order they asked. A check that is cancelled while it waits leaves the line without a turn.
/// Several centers can share one queue to read one page at a time across profiles.
@MainActor
final class PageWatchQueue {
    private var isBusy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    var pending: Int {
        waiting.count
    }

    /// True when the caller has the turn and must call `leave()`. False when it was cancelled first.
    func enter() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isBusy else {
            isBusy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.leaveLine(id) }
        }
    }

    func leave() {
        guard !waiting.isEmpty else {
            isBusy = false
            return
        }
        waiting.removeFirst().continuation.resume(returning: true)
    }

    private func leaveLine(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}

/// Keeps the person's page watches and decides when each is read. Reading, judging, notifying, the clock and sleeping
/// are all passed in, so this type holds no web view, model session or notification of its own.
@MainActor
@Observable
final class PageWatchCenter {
    enum Notice: Equatable {
        case met
        case unreachable
        case expired
    }

    enum Start: Equatable {
        case watching(PageWatch)
        case alreadyMet(PageWatchVerdict)
        case unreadable
        case noModel
        case undecided
        case duplicate(PageWatch)
        case full
        case denied
    }

    private(set) var watches: [PageWatch] = []

    static let classifyLimit = 16
    static let longestSleep: TimeInterval = 900

    private let fetch: (PageWatch) async -> PageWatchReading?
    private let judge: (PageWatch, PageWatchReading) async -> PageWatchVerdict?
    private let classify: (PageWatch, PageWatchChange.Pair) async -> PageWatchVerdict?
    private let canJudge: () -> Bool
    private let notify: (PageWatch, Notice) -> Void
    private let allows: (URL) -> Bool
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void
    private let launchHold: TimeInterval
    private let queue: PageWatchQueue

    private let file: URL?
    private let schedules: Bool
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var checking: Set<UUID> = []
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var holdUntil: Date?

    /// `file` is where the watches are kept. Pass nil for a center that must not write anything (private windows, tests).
    init(
        file: URL?,
        schedules: Bool = true,
        launchHold: TimeInterval = 60,
        queue: PageWatchQueue = PageWatchQueue(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        fetch: @escaping (PageWatch) async -> PageWatchReading?,
        judge: @escaping (PageWatch, PageWatchReading) async -> PageWatchVerdict?,
        classify: @escaping (PageWatch, PageWatchChange.Pair) async -> PageWatchVerdict?,
        canJudge: @escaping () -> Bool = { true },
        notify: @escaping (PageWatch, Notice) -> Void,
        allows: @escaping (URL) -> Bool = { _ in true }
    ) {
        self.file = file
        self.schedules = schedules
        self.launchHold = launchHold
        self.queue = queue
        self.now = now
        self.sleep = sleep
        self.fetch = fetch
        self.judge = judge
        self.classify = classify
        self.canJudge = canJudge
        self.notify = notify
        self.allows = allows
        if let file, let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([PageWatch].self, from: data) {
            watches = Array(stored.prefix(PageWatch.limit))
        }
    }

    deinit {
        loop?.cancel()
        sleeper?.cancel()
    }

    var isScheduling: Bool {
        schedules && !isShutDown
    }

    /// Starts the schedule. Nothing is read until `launchHold` seconds from now, so a launch is not slowed by page loads.
    func resume() {
        holdUntil = now() + launchHold
        wake()
    }

    func refusal(url: URL, condition: String) -> Start? {
        if let existing = watches.first(where: { $0.url == url && $0.condition == condition }) {
            return .duplicate(existing)
        }
        return watches.count < PageWatch.limit ? nil : .full
    }

    /// Reads the page once and keeps a watch on it. The caller has the person's consent for this URL and condition;
    /// `access` is `signedIn` only when the person chose their sign-ins for this watch.
    func start(
        url: URL,
        title: String,
        condition: String,
        everyMinutes minutes: Int,
        access: PageWatch.Access = .anonymous
    ) async -> Start {
        guard allows(url) else { return .denied }
        if let refusal = refusal(url: url, condition: condition) {
            return refusal
        }
        guard canJudge() else { return .noModel }
        let date = now()
        var watch = PageWatch(
            id: UUID(),
            url: url,
            title: title,
            condition: condition,
            interval: PageWatch.interval(minutes: minutes),
            access: access,
            created: date,
            nextCheck: date
        )
        guard let reading = await fetch(watch)?.bounded(), !reading.text.isEmpty else { return .unreadable }
        if let landed = reading.url, !PageWatch.isSamePage(landed, url) {
            return .unreadable
        }
        if !condition.isEmpty {
            guard let verdict = await judge(watch, reading) else { return .undecided }
            guard !verdict.met else { return .alreadyMet(verdict) }
            watch.state = verdict.state
        }
        if !reading.title.isEmpty {
            watch.title = reading.title
        }
        watch.fingerprint = reading.fingerprint
        watch.snapshot = reading.text
        watch.lastChecked = date
        watch.nextCheck = date + watch.period
        if let refusal = refusal(url: url, condition: condition) {
            return refusal
        }
        watches.append(watch)
        save()
        wake()
        return .watching(watch)
    }

    @discardableResult
    func stop(_ id: UUID) -> PageWatch? {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = watches.remove(at: index)
        save()
        wake()
        return removed
    }

    func matching(_ reference: String) -> [PageWatch] {
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return watches }
        if let id = UUID(uuidString: needle) {
            return watches.filter { $0.id == id }
        }
        return watches.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(needle)
                || $0.condition.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Checks every watch that is due, one after another, oldest first. Cancelling the caller drops the rest of the pass;
    /// they stay due and the next pass takes them.
    func checkDue() async {
        let date = now()
        let due = watches
            .filter { $0.nextWake <= date && !checking.contains($0.id) }
            .sorted { $0.nextWake < $1.nextWake }
        for watch in due {
            guard !Task.isCancelled else { return }
            // A check that ran while this pass waited has already moved the watch on.
            guard let current = watches.first(where: { $0.id == watch.id }), current.nextWake <= date else { continue }
            await check(watch.id)
        }
    }

    /// Reads one watch now, whether or not it is due. A watch already being checked is left alone. A successful check
    /// resumes a paused watch. A cancelled check is neither a failure nor a reading: the watch keeps its place in time.
    func check(_ id: UUID) async {
        guard !checking.contains(id), watches.contains(where: { $0.id == id }) else { return }
        checking.insert(id)
        defer {
            checking.remove(id)
            wake()
        }
        guard await queue.enter() else { return }
        defer { queue.leave() }
        guard let watch = watches.first(where: { $0.id == id }), !Task.isCancelled else { return }

        guard now() < watch.expires else {
            finish(id, with: .expired)
            return
        }
        guard allows(watch.url) else {
            stop(id)
            return
        }
        let fetched = await fetch(watch)
        guard !Task.isCancelled else { return }
        guard let reading = fetched?.bounded(), !reading.text.isEmpty,
              reading.url.map({ PageWatch.isSamePage($0, watch.url) }) ?? true else {
            failed(id)
            return
        }
        let fingerprint = reading.fingerprint
        if fingerprint == watch.fingerprint {
            update(id) { $0.failures = 0 }
            return
        }
        guard let current = watches.first(where: { $0.id == id }) else { return }
        guard canJudge() else {
            postpone(id)
            return
        }
        guard let verdict = await verdict(for: current, reading: reading) else {
            if !Task.isCancelled {
                postpone(id)
            }
            return
        }
        guard !Task.isCancelled, watches.contains(where: { $0.id == id }) else { return }
        if verdict.met {
            finish(id, with: .met)
            return
        }
        update(id) {
            $0.failures = 0
            $0.fingerprint = fingerprint
            $0.snapshot = reading.text
            if !verdict.state.isEmpty {
                $0.state = verdict.state
            }
            if !reading.title.isEmpty {
                $0.title = reading.title
            }
        }
    }

    private func verdict(for watch: PageWatch, reading: PageWatchReading) async -> PageWatchVerdict? {
        guard watch.condition.isEmpty else { return await judge(watch, reading) }
        let change = PageWatchChange(from: watch.snapshot ?? reading.text, to: reading.text)
        for pair in change.pairs.prefix(Self.classifyLimit) {
            guard let verdict = await classify(watch, pair) else { return nil }
            if verdict.met {
                return verdict
            }
        }
        return PageWatchVerdict(met: false, state: "", message: "")
    }

    private func failed(_ id: UUID) {
        guard let watch = watches.first(where: { $0.id == id }), !watch.isPaused else { return }
        update(id) { $0.failures += 1 }
        if let paused = watches.first(where: { $0.id == id }), paused.isPaused {
            notify(paused, .unreachable)
        }
    }

    private func postpone(_ id: UUID) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        watches[index].nextCheck = now() + watches[index].period
        save()
    }

    private func finish(_ id: UUID, with notice: Notice) {
        guard let watch = stop(id) else { return }
        notify(watch, notice)
    }

    private func update(_ id: UUID, _ change: (inout PageWatch) -> Void) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        let date = now()
        change(&watches[index])
        watches[index].lastChecked = date
        watches[index].nextCheck = date + watches[index].period
        save()
    }

    // MARK: - Storage

    /// Writes are chained so an older list can never land after a newer one.
    private func save() {
        guard let file, !isShutDown else { return }
        let snapshot = watches
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            await JSONFileStore.shared.write(snapshot, to: file)
        }
    }

    /// Waits for every write started so far.
    func flush() async {
        await saveTask?.value
    }

    // MARK: - Schedule

    private func wake() {
        guard schedules, !isShutDown else { return }
        if let loop, !loop.isCancelled {
            sleeper?.cancel()
            return
        }
        guard !watches.isEmpty else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let nap = self?.napUntilNextCheck() {
                await nap.value
                guard !Task.isCancelled, let self else { break }
                sleeper = nil
                if holdUntil.map({ now() >= $0 }) ?? true {
                    await checkDue()
                }
            }
            self?.loop = nil
        }
    }

    /// A watch that is being checked has its own turn and is not waited for, so a manual check never makes the loop spin.
    private func napUntilNextCheck() -> Task<Void, Never>? {
        guard var next = watches.filter({ !checking.contains($0.id) }).map(\.nextWake).min() else { return nil }
        if let holdUntil {
            next = max(next, holdUntil)
        }
        let delay = min(max(next.timeIntervalSince(now()), 0), Self.longestSleep)
        let sleep = self.sleep
        let nap = Task<Void, Never> {
            guard delay > 0 else { return }
            await sleep(delay)
        }
        sleeper = nap
        return nap
    }

    /// Ends the schedule and forgets the watches in memory. The stored list is left as it is for the next launch.
    func shutDown() {
        isShutDown = true
        watches = []
        loop?.cancel()
        sleeper?.cancel()
        loop = nil
    }

    func close() async {
        let running = loop
        shutDown()
        await running?.value
        await flush()
    }
}
