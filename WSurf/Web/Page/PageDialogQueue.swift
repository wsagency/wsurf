// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The JavaScript dialogs one tab's page has open, and who answers them.
///
/// A dialog normally gets a native sheet. While an external connection controls the tab, it is held here instead, so the
/// connection can read it and answer it; the page stays blocked until it does. A dialog the connection leaves unanswered,
/// or loses interest in, goes to the user. It is never answered on the user's behalf.
@MainActor
final class PageDialogQueue {
    nonisolated enum Kind: String, Codable, Sendable {
        case alert, confirm, prompt, beforeUnload
    }

    nonisolated struct Request: Sendable {
        var kind: Kind
        var message: String
        /// Scheme, host and port only. Build it with `PageDialogText.origin`.
        var origin: String
        var defaultText: String?
        var isReload = false
    }

    /// OK or Leave is `accepted`; Cancel or Stay is not. `text` is a prompt's reply.
    nonisolated struct Answer: Sendable, Equatable {
        var accepted: Bool
        var text: String?
    }

    /// What a connection may know about an open dialog. The text is the page's: bounded, links cleaned, still untrusted.
    nonisolated struct Summary: Codable, Sendable, Equatable {
        let id: String
        let kind: Kind
        let message: String
        let truncated: Bool
        let origin: String
        let defaultText: String?
        let isReload: Bool
        /// The native sheet is up, or this dialog may not be answered by a connection.
        let userMustAnswer: Bool
    }

    /// What lets a connection apply an accepted prompt reply. A prompt carries the user's words into the page, so without one
    /// of these the queue refuses the reply.
    nonisolated enum Authorization: Sendable {
        /// The user approved this reply in WSurf.
        case consent
        /// The connection has development access and the page is on this Mac. A later release replaces this gate with
        /// the Developer tier (paired client, Developer profile, developer site).
        case developer
    }

    /// Held while a call that can act on the tab runs. Dialogs that call opens come to its connection.
    final class Claim {
        let connection: UUID
        fileprivate let isAuthorized: () -> Bool
        private weak var queue: PageDialogQueue?

        fileprivate init(connection: UUID, isAuthorized: @escaping () -> Bool, queue: PageDialogQueue) {
            self.connection = connection
            self.isAuthorized = isAuthorized
            self.queue = queue
        }

        /// The call returned: dialogs no longer come to this connection.
        func end() {
            queue?.claims.removeAll { $0 === self }
        }

        /// Ends the claim after `PageDialogQueue.claimLinger`. Only a navigation call uses this: Chromium asks about its
        /// beforeunload dialog a moment after the call that started it has returned.
        func endAfterNavigation() {
            queue?.linger(self)
        }
    }

    nonisolated enum Race<T: Sendable>: Sendable {
        case finished(T)
        case dialog
    }

    private enum Resolution {
        case answered(Answer)
        case native
        case cancelled
    }

    private final class Entry {
        enum State { case agent, user, done }
        let id = UUID().uuidString
        let request: Request
        let connection: UUID
        let message: String
        let truncated: Bool
        let defaultText: String?
        var state: State
        var continuation: CheckedContinuation<Resolution, Never>?
        var timeout: Task<Void, Never>?

        init(request: Request, connection: UUID, state: State) {
            self.request = request
            self.connection = connection
            self.state = state
            let text = PageDialogText.forAgent(request.message)
            message = text.text
            truncated = text.truncated
            // A secret prompt is the user's, so a value the page pre-filled in it is not shown either.
            let asksForSecret = request.kind == .prompt && PageDialogText.looksSecret(request.message)
            defaultText = asksForSecret ? nil : request.defaultText.map { PageDialogText.forAgent($0).text }
        }
    }

    /// The most dialogs held at once; further ones get the native sheet.
    static let maxOpen = 8
    /// "Stay" answers a connection may give per document. A later beforeunload dialog goes to the user, so a connection
    /// cannot keep the user on a page.
    static let maxAgentStays = 2

    var clock: any Clock<Duration> = ContinuousClock()
    /// How long a connection has to answer before the user is shown the dialog.
    var timeout: Duration = .seconds(60)
    /// How long a navigation call's claim outlives the call.
    var claimLinger: Duration = .seconds(2)
    /// After the user's own click or key press in the page, a dialog is the user's for this long, whoever holds the tab.
    var gestureWindow: Duration = .seconds(3)
    /// How long answering waits for the work the dialog was blocking.
    var settleCeiling: Duration = .seconds(5)
    /// The connection holding an authorized development lease on this tab, if any.
    var leaseHolder: (() -> UUID?)?

    private var entries: [Entry] = []
    private var claims: [Claim] = []
    private var arrivalWaiters: [UUID: () -> Void] = [:]
    private var parked: [UUID: Task<Void, Never>] = [:]
    private var agentStays = 0
    private var lastGesture: ContinuousClock.Instant?

    init() {
        PageUserGesture.installIfNeeded()
    }

    // MARK: Routing

    func claim(connection: UUID, isAuthorized: @escaping () -> Bool) -> Claim {
        let claim = Claim(connection: connection, isAuthorized: isAuthorized, queue: self)
        claims.append(claim)
        return claim
    }

    fileprivate func linger(_ claim: Claim) {
        let (clock, wait) = (clock, claimLinger)
        Task {
            try? await clock.sleep(for: wait)
            claim.end()
        }
    }

    /// Whether a connection currently controls the tab. A tab nobody controls takes the native path with no other cost.
    var isIntercepting: Bool {
        controller != nil
    }

    /// The one connection acting on the tab now: it holds an authorized claim, or the development lease. With two
    /// connections in play nobody can say whose action opened the dialog, so there is none and the user answers. So does
    /// the user's own input: it ends every claim and keeps the lease from taking a dialog that follows it.
    private var controller: (connection: UUID, viaClaim: Bool)? {
        let claimants = Set(claims.filter { $0.isAuthorized() }.map(\.connection))
        let lease = recentlyTouchedByUser ? nil : leaseHolder?()
        let acting = claimants.union(lease.map { [$0] } ?? [])
        guard acting.count == 1, let connection = acting.first else { return nil }
        return (connection, claimants.contains(connection))
    }

    private var recentlyTouchedByUser: Bool {
        lastGesture.map { ContinuousClock.now - $0 < gestureWindow } ?? false
    }

    /// The user clicked or typed in the page. Whatever dialog follows is theirs: every claim ends.
    func userInteracted() {
        claims.removeAll()
        lastGesture = ContinuousClock.now
    }

    private func agentMayAnswer(_ request: Request, viaClaim: Bool) -> Bool {
        switch request.kind {
        case .prompt:
            // A secret is never the connection's to answer. Any other prompt can be, but only with an authorization.
            return !PageDialogText.looksSecret(request.message)
        case .beforeUnload:
            // A lease alone never takes a beforeunload: only a call that is acting on the tab can have caused it.
            return viaClaim && agentStays < Self.maxAgentStays
        case .alert, .confirm:
            return true
        }
    }

    /// Runs `request`: held for the connection that controls the tab, else `native` straight away. Nil means the page
    /// went away and no answer is needed.
    func run(_ request: Request, native: @MainActor () async -> Answer) async -> Answer? {
        guard let control = controller, entries.count < Self.maxOpen else { return await native() }
        let entry = Entry(
            request: request, connection: control.connection,
            state: agentMayAnswer(request, viaClaim: control.viaClaim) ? .agent : .user)
        entries.append(entry)
        defer { remove(entry) }
        announce()
        if entry.state == .agent {
            switch await wait(for: entry) {
            case .answered(let answer):
                return answer
            case .cancelled:
                return nil
            case .native:
                break
            }
        }
        return await native()
    }

    private func wait(for entry: Entry) async -> Resolution {
        let (clock, limit) = (clock, timeout)
        entry.timeout = Task { [weak self, weak entry] in
            try? await clock.sleep(for: limit)
            guard !Task.isCancelled, let self, let entry else { return }
            resolve(entry, .native)
        }
        return await withCheckedContinuation { entry.continuation = $0 }
    }

    private func resolve(_ entry: Entry, _ resolution: Resolution) {
        guard let continuation = entry.continuation else { return }
        entry.continuation = nil
        entry.timeout?.cancel()
        entry.timeout = nil
        if case .native = resolution {
            entry.state = .user
        } else {
            entry.state = .done
        }
        continuation.resume(returning: resolution)
    }

    private func remove(_ entry: Entry) {
        entry.state = .done
        entries.removeAll { $0 === entry }
    }

    private func announce() {
        let waiters = arrivalWaiters
        arrivalWaiters = [:]
        waiters.values.forEach { $0() }
    }

    // MARK: Reading and answering

    private var open: [Entry] {
        entries.filter { $0.state != .done }
    }

    /// True while any dialog, whoever must answer it, blocks the page.
    var hasOpenDialog: Bool {
        !open.isEmpty
    }

    func pending(for connection: UUID) -> [Summary] {
        open.filter { $0.connection == connection }.map { entry in
            Summary(
                id: entry.id, kind: entry.request.kind, message: entry.message, truncated: entry.truncated,
                origin: entry.request.origin, defaultText: entry.defaultText, isReload: entry.request.isReload,
                userMustAnswer: entry.state != .agent)
        }
    }

    /// What the page asked, whole, for checks that must see more than `Summary` keeps.
    func request(of id: String) -> Request? {
        entries.first { $0.id == id }?.request
    }

    /// Answers a dialog held for `connection`. False when it is gone, belongs to another connection, is the user's, or is a
    /// prompt being accepted without an `authorization`.
    func answer(_ id: String, connection: UUID, with answer: Answer, authorization: Authorization? = nil) -> Bool {
        guard let entry = entries.first(where: { $0.id == id && $0.connection == connection }),
            entry.state == .agent, entry.continuation != nil
        else { return false }
        if entry.request.kind == .prompt, answer.accepted, authorization == nil {
            return false
        }
        var answer = answer
        if entry.request.kind == .prompt, answer.accepted, answer.text == nil {
            answer.text = entry.request.defaultText ?? ""
        } else if entry.request.kind != .prompt {
            answer.text = nil
        }
        if entry.request.kind == .beforeUnload, !answer.accepted {
            agentStays += 1
        }
        resolve(entry, .answered(answer))
        return true
    }

    /// The connection is gone: its dialogs go to the user.
    func handBack(connection: UUID) {
        for entry in entries where entry.connection == connection && entry.state == .agent {
            resolve(entry, .native)
        }
    }

    /// The page is gone (replaced, crashed or closed): nobody needs to answer.
    func cancelAll() {
        for entry in entries {
            resolve(entry, .cancelled)
            entry.state = .done
        }
        entries.removeAll()
        parked.removeAll()
    }

    /// A new document committed, so the stay limit starts again.
    func documentCommitted() {
        agentStays = 0
    }

    // MARK: Work a dialog blocks

    /// Waits for `task` or for a dialog to open, whichever comes first. Nil: the caller was cancelled.
    func race<T: Sendable>(_ task: Task<T, Never>) async -> Race<T>? {
        guard !hasOpenDialog else { return .dialog }
        let token = UUID()
        defer { arrivalWaiters[token] = nil }
        // The ceiling only keeps the gate's contract; the work and the dialog decide.
        return await PageReply<Race<T>>.awaiting(within: .seconds(24 * 3_600)) { gate in
            arrivalWaiters[token] = { gate.finish(.dialog) }
            Task { gate.finish(.finished(await task.value)) }
        }
    }

    /// Keeps a handle on work that is stuck behind a dialog, so answering can wait for it to finish.
    func park<T: Sendable>(_ task: Task<T, Never>) {
        let key = UUID()
        parked[key] = Task { [weak self] in
            _ = await task.value
            self?.parked[key] = nil
        }
    }

    /// Returns when the parked work has finished, a new dialog opened, or `settleCeiling` passed.
    func settleParked() async {
        let tasks = Array(parked.values)
        guard !tasks.isEmpty, !hasOpenDialog else { return }
        let token = UUID()
        defer { arrivalWaiters[token] = nil }
        _ = await PageReply<Bool>.awaiting(within: settleCeiling) { gate in
            arrivalWaiters[token] = { gate.finish(false) }
            Task {
                for task in tasks {
                    await task.value
                }
                gate.finish(true)
            }
        }
    }
}
