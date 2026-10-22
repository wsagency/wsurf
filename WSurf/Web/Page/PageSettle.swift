// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

@MainActor
enum PageSettle {
    static let loadCeiling: Duration = .seconds(12)
    nonisolated static let navigationGrace: Duration = .milliseconds(400)
    /// No DOM change and no finished resource for this long counts as quiet.
    static let quietWindow: Duration = .milliseconds(120)
    @TaskLocal static var interactionObserver: (@MainActor @Sendable () -> Void)?

    /// How `untilQuiet` waits. `event` asks the page once and lets it answer when it has been quiet; `polling` samples a
    /// signature on an interval. `event` falls back to `polling` when the page cannot be asked.
    enum Strategy: Sendable { case event, polling }
    @TaskLocal static var strategy = Strategy.event

    /// How long an interaction waits for a navigation to start and for the page to go quiet afterwards.
    nonisolated struct Limits: Sendable {
        var grace: Duration = PageSettle.navigationGrace
        var quietCeiling: Duration = .milliseconds(1500)
    }
    @TaskLocal static var limits = Limits()

    /// Adds up the time a call spends waiting here, for the cost a client is shown.
    @MainActor
    final class Meter {
        private(set) var elapsed: Duration = .zero

        func add(_ duration: Duration) {
            elapsed += duration
        }
    }
    @TaskLocal static var meter: Meter?

    @discardableResult
    static func untilIdle(
        _ webView: BrowserPage,
        timeout: Duration = loadCeiling,
        clock: some Clock<Duration> = ContinuousClock()
    ) async -> Bool {
        await wait(on: webView, timeout: timeout, clock: clock) { !$0.isLoading }
    }

    static func afterInteraction(
        _ webView: BrowserPage,
        grace: Duration = limits.grace,
        quietCeiling: Duration = limits.quietCeiling,
        clock: some Clock<Duration> = ContinuousClock()
    ) async {
        interactionObserver?()
        let navigated = await wait(on: webView, timeout: grace, clock: clock) { $0.isLoading }
        if navigated {
            await untilIdle(webView, clock: clock)
        }
        await untilQuiet(webView, ceiling: quietCeiling, clock: clock)
        // A navigation the page started while it settled is followed to its end, not reported half loaded.
        if webView.isLoading, !Task.isCancelled {
            await untilIdle(webView, clock: clock)
            await untilQuiet(webView, ceiling: min(quietCeiling, .milliseconds(500)), clock: clock)
        }
    }

    /// Whether the page is loading, or is no longer on `document` and `url`, within a moment: an action navigated it.
    static func pageWasLeft(_ webView: BrowserPage, document: String?, url: URL?) async -> Bool {
        await wait(on: webView, timeout: .milliseconds(500), clock: ContinuousClock()) {
            $0.isLoading || $0.mainDocumentID != document || $0.url != url
        }
    }

    /// Returns once the page has stopped changing or `ceiling` has passed. With the real clock the page is asked once
    /// (`quietScript`) and answers when its own DOM and resource timeline have been quiet; an injected clock, a failed ask
    /// or `Strategy.polling` samples a signature on `interval` instead.
    static func untilQuiet(
        _ webView: BrowserPage,
        ceiling: Duration = .milliseconds(2500),
        interval: Duration = .milliseconds(120),
        clock: some Clock<Duration> = ContinuousClock()
    ) async {
        let started = ContinuousClock.now
        defer { meter?.add(started.duration(to: .now)) }
        var remaining = ceiling
        if strategy == .event, clock is ContinuousClock {
            while remaining > .zero, !Task.isCancelled {
                let begun = ContinuousClock.now
                switch await quiet(webView, ceiling: remaining) {
                case .quiet, .ceiling:
                    return
                case .unloading:
                    await untilIdle(webView, timeout: min(loadCeiling, remaining))
                    remaining -= begun.duration(to: .now)
                case nil:
                    remaining -= begun.duration(to: .now)
                    await poll(webView, ceiling: remaining, interval: interval, clock: clock)
                    return
                }
            }
            return
        }
        await poll(webView, ceiling: remaining, interval: interval, clock: clock)
    }

    enum Quiet: Sendable { case quiet, ceiling, unloading }

    /// Self-contained: it needs none of the page runtime. Quiet means no DOM mutation (other than the highlight ring) and no
    /// resource that finished loading for `quiet` ms; `pagehide` means the document is being replaced.
    private static let quietScript = """
        const quiet = QUIET, ceiling = CEILING;
        return await new Promise(resolve => {
          let done = false, timer = null, observer = null, resources = null;
          const finish = reason => {
            if (done) return;
            done = true;
            observer?.disconnect(); resources?.disconnect(); clearTimeout(timer); clearTimeout(cap);
            window.removeEventListener('pagehide', onHide);
            resolve(reason);
          };
          const ring = n => n.nodeType === 1 && n.classList.contains('__wsurf-ring');
          const noise = r => ring(r.target) || (r.type === 'childList' && [...r.addedNodes, ...r.removedNodes].every(ring));
          const arm = () => { clearTimeout(timer); timer = setTimeout(() => finish('quiet'), quiet); };
          const onHide = () => finish('unloading');
          const cap = setTimeout(() => finish('ceiling'), ceiling);
          observer = new MutationObserver(records => { if (!records.every(noise)) arm(); });
          observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
          try { resources = new PerformanceObserver(arm); resources.observe({ type: 'resource' }); } catch (e) {}
          window.addEventListener('pagehide', onHide, { once: true });
          arm();
        });
        """

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func quiet(_ webView: BrowserPage, ceiling: Duration) async -> Quiet? {
        let body = quietScript
            .replacingOccurrences(of: "QUIET", with: String(milliseconds(quietWindow)))
            .replacingOccurrences(of: "CEILING", with: String(max(1, milliseconds(ceiling))))
        // The page answers by its own ceiling; the host waits a little longer for a page that never does.
        guard let answer = await webView.callAsyncJavaScript(body, within: ceiling + .milliseconds(750), in: PageDriver.selectedFrame?.frame) else {
            return nil
        }
        switch answer {
        case "quiet":
            return .quiet
        case "ceiling":
            return .ceiling
        case "unloading":
            return .unloading
        default:
            return nil
        }
    }

    private static func poll(_ webView: BrowserPage, ceiling: Duration, interval: Duration, clock: some Clock<Duration>) async {
        var monitor = QuiescenceMonitor()
        let deadline = clock.now.advanced(by: ceiling)
        while clock.now < deadline, !Task.isCancelled {
            let remaining = clock.now.duration(to: deadline)
            guard let signature = await signature(of: webView, timeout: remaining) else { return }
            if monitor.record(signature) {
                return
            }
            do {
                try await clock.sleep(for: max(.zero, min(interval, clock.now.duration(to: deadline))))
            } catch { return }
        }
    }

    private static func signature(of webView: BrowserPage, timeout: Duration) async -> Int? {
        let script = """
        (() => {
          const elements = document.getElementsByTagName('*').length;
          const text = document.body ? document.body.textContent.length : 0;
          const ready = document.readyState === 'complete' ? 1 : 0;
          return elements * 1000003 + text * 7 + ready;
        })()
        """
        return await withCheckedContinuation { continuation in
            let gate = PageSettleSignatureGate(continuation)
            webView.evaluateJavaScript(script) { value, _ in
                let signature = (value as? NSNumber)?.intValue
                Task.detached(priority: .userInitiated) {
                    await gate.close(with: signature)
                }
            }
            let timeoutTask = Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await gate.close(with: nil)
            }
            Task.detached(priority: .userInitiated) {
                await gate.install(timeoutTask)
            }
        }
    }

    private static func wait(
        on webView: BrowserPage,
        timeout: Duration,
        clock: some Clock<Duration>,
        until isSatisfied: @escaping @MainActor (BrowserPage) -> Bool
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if isSatisfied(webView) {
            return true
        }
        let started = ContinuousClock.now
        defer { meter?.add(started.duration(to: .now)) }
        let gate = Gate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation)
                gate.observation = webView.observe(\.isLoading, options: [.new]) { view, _ in
                    MainActor.assumeIsolated {
                        if isSatisfied(view) {
                            gate.close(satisfied: true)
                        }
                    }
                }
                gate.timeoutTask = Task {
                    try? await clock.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    gate.close(satisfied: false)
                }
                if isSatisfied(webView) {
                    gate.close(satisfied: true)
                }
            }
        } onCancel: {
            Task { @MainActor in gate.close(satisfied: false) }
        }
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Bool, Never>?
        var observation: NSKeyValueObservation?
        var timeoutTask: Task<Void, Never>?

        func arm(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func close(satisfied: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            observation?.invalidate()
            observation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(returning: satisfied)
        }
    }
}

private actor PageSettleSignatureGate {
    private var continuation: CheckedContinuation<Int?, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Int?, Never>) {
        self.continuation = continuation
    }

    func install(_ task: Task<Void, Never>) {
        guard continuation != nil else {
            task.cancel()
            return
        }
        timeoutTask = task
    }

    func close(with signature: Int?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: signature)
    }
}

nonisolated struct QuiescenceMonitor {
    private var previous: Int?
    private var matches = 0
    private let required: Int

    init(requiredMatches: Int = 2) {
        required = requiredMatches
    }

    mutating func record(_ signature: Int) -> Bool {
        if signature == previous {
            matches += 1
        } else {
            previous = signature
            matches = 1
        }
        return matches >= required
    }
}
