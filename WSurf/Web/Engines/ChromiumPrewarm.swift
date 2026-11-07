// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit

/// Starts Chromium before the first Chromium tab asks for it, when the session is going to use it, and only at a moment the
/// person is not using the app.
///
/// `ChromiumRuntime.ensureInitialized` blocks the main thread for 110-260 ms (framework load, `cef_initialize`, helper launch).
/// Run by the first Chromium tab it lands on a click or a switch. A session that restored a Chromium tab, a Chromium
/// favourite or has a Chromium site rule will pay that start anyway, so it pays it once the app has been left alone for
/// `idleInterval` after launch. A session without any of them never starts Chromium here: the helpers cost ~100 MB and some
/// wakeups, which only people who use Chromium should carry.
///
/// One attempt per launch: the wait ends at the first idle moment, whether or not it started anything.
@MainActor
final class ChromiumPrewarm {
    static let idleInterval: Duration = .seconds(2)

    private let clock: any Clock<Duration>
    private let idleInterval: Duration
    private let usesChromium: @MainActor () -> Bool
    private let isStarted: @MainActor () -> Bool
    private let isBusy: @MainActor () -> Bool
    private let start: @MainActor () -> Void
    private var wait: Task<Void, Never>?
    private var inputMonitor: Any?
    /// Whether the attempt is over: the app was idle once and the decision was made.
    private(set) var isFinished = false

    init(
        clock: any Clock<Duration> = ContinuousClock(),
        idleInterval: Duration = ChromiumPrewarm.idleInterval,
        usesChromium: @escaping @MainActor () -> Bool,
        isStarted: @escaping @MainActor () -> Bool,
        isBusy: @escaping @MainActor () -> Bool = ChromiumPrewarm.isTrackingInput,
        start: @escaping @MainActor () -> Void
    ) {
        self.clock = clock
        self.idleInterval = idleInterval
        self.usesChromium = usesChromium
        self.isStarted = isStarted
        self.isBusy = isBusy
        self.start = start
    }

    isolated deinit {
        wait?.cancel()
        removeInputMonitor()
    }

    /// Begins waiting for an idle moment. Call once the front window has drawn.
    func arm() {
        guard !isFinished else { return }
        restartWait()
    }

    /// The person did something in the app: the idle time starts again.
    func noteInput() {
        guard wait != nil, !isFinished else { return }
        restartWait()
    }

    /// Stops without a decision.
    func cancel() {
        wait?.cancel()
        wait = nil
        removeInputMonitor()
    }

    /// Counts this app's own key presses, clicks and scrolls as input. Local monitors see only events sent to this app and need
    /// no permission.
    func watchInput() {
        guard inputMonitor == nil, !isFinished else { return }
        let kinds: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            MainActor.assumeIsolated { self?.noteInput() }
            return event
        }
    }

    private func removeInputMonitor() {
        if let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
        }
        inputMonitor = nil
    }

    private static let busyPoll: Duration = .milliseconds(250)

    private func restartWait() {
        wait?.cancel()
        wait = Task { [weak self, clock, idleInterval] in
            do {
                while true {
                    try await clock.sleep(for: idleInterval)
                    guard !Task.isCancelled, let self else { return }
                    if !isBusy() {
                        idleElapsed()
                        return
                    }
                    // In use without an event the monitor saw (a drag, a menu): look again soon, and count the idle time from
                    // the moment it is over, so Chromium does not start the instant a drag ends.
                    while await isBusyAfter(clock) {}
                }
            } catch {
                return
            }
        }
    }

    /// Waits one poll of the clock, then answers whether the app is still busy.
    private func isBusyAfter(_ clock: any Clock<Duration>) async -> Bool {
        guard (try? await clock.sleep(for: Self.busyPoll)) != nil, !Task.isCancelled else { return false }
        return isBusy()
    }

    /// A mouse button held down, or a modal tracking loop (a drag, a menu, a resize) running: the app is in use although no event
    /// reached the local monitor.
    static func isTrackingInput() -> Bool {
        NSEvent.pressedMouseButtons != 0 || RunLoop.main.currentMode == .eventTracking
    }

    private func idleElapsed() {
        guard !isFinished else { return }
        isFinished = true
        wait = nil
        removeInputMonitor()
        guard !isStarted(), usesChromium() else { return }
        start()
    }

    /// Whether the session will need Chromium: a site is set to it, or a tab of a window, a Chromium favourite among them,
    /// belongs to a site that runs in it. Reads the tabs' addresses and settings only; no page is built or loaded.
    static func sessionUsesChromium(models: [BrowserModel], permissions: [SitePermissions]) -> Bool {
        // A record is only a Chromium rule if the site still resolves to Chromium (a site kept WebKit-only has none).
        permissions.contains { permission in permission.engineOrigins.contains { permission.engine(for: $0) == .chromium } }
            || models.contains { model in model.tabs.contains { model.engine(for: $0) == .chromium } }
    }
}

extension BrowserApplication {
    /// Starts Chromium once the app is idle after launch, in a session that uses it (`ChromiumPrewarm`).
    func armChromiumPrewarm() {
        // A test host must not start Chromium on its own.
        guard !AppDatabase.isRunningTests, chromiumPrewarm == nil else { return }
        let prewarm = ChromiumPrewarm(
            usesChromium: { [weak self] in
                // Never start Chromium while the app is quitting.
                guard let self, !isTerminating else { return false }
                let permissions = ProfileStore.shared.profiles.map { BrowserProfileContext.shared(for: $0).sitePermissions }
                return ChromiumPrewarm.sessionUsesChromium(models: windows.filter { !$0.isClosed }.map(\.browser), permissions: permissions)
            },
            isStarted: { ChromiumRuntime.shared.isInitialized },
            start: { ChromiumRuntime.shared.startEarly() }
        )
        chromiumPrewarm = prewarm
        prewarm.watchInput()
        prewarm.arm()
    }
}
