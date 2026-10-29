import CCef
import Foundation

/// Drives CEF's message loop from the main run loop (external message pump).
///
/// CEF requests work via `on_schedule_message_pump_work(delay_ms)`. An immediate request runs the loop now. A delayed
/// request replaces the earlier delayed one and runs the loop when it is due; an immediate request leaves a pending
/// delayed one alone. A request that arrives while the loop is already running (a nested loop, for example a modal
/// dialog) is run again as soon as the outer pass returns, so it is never dropped.
///
/// Requests alone are not enough: measured with exact requests and nothing else, a warm page load took 2 to 3 s
/// instead of 0.2 to 0.4 s. CEF cuts a pass short after about 10 ms and then asks for no further pass while that work
/// waits, so the pump has to come back on its own. So each pass that a request caused, and each pass that ran long
/// enough to have been cut short, starts or extends a busy window in which the loop also runs every 33 ms; the window
/// ends shortly after the last such pass. A slow safety-net timer runs the loop once a second while a browser is alive.
/// With no browser alive, no request pending and the settling time after the last browser closed (or after start) over,
/// nothing repeats: an idle runtime costs the host no wakeups.
///
/// Timers come from an injectable source and the loop from an injectable closure, so a test can drive the pump
/// without a run loop or a CEF framework. All work happens on the main thread.
@MainActor
final class CefMessagePump {
    /// Cancels a timer that a ``TimerSource`` started.
    typealias CancelTimer = @MainActor () -> Void

    /// Starts a timer that calls `fire` after `interval` seconds (every `interval` seconds when `repeats`), and
    /// returns the closure that cancels it.
    typealias TimerSource = @MainActor (
        _ interval: TimeInterval,
        _ tolerance: TimeInterval,
        _ repeats: Bool,
        _ fire: @escaping @MainActor () -> Void
    ) -> CancelTimer

    /// Period of the poll while the pump is busy (33 ms, about 30 Hz).
    static let busyInterval: TimeInterval = 0.033
    /// How long the busy window outlasts the last request while a browser is alive.
    static let busyLingerWithBrowser: TimeInterval = 0.5
    /// The same with no browser alive, where requests are rare and a long tail would only cost wakeups.
    static let busyLingerWithoutBrowser: TimeInterval = 0.1
    /// Period of the safety-net timer while a browser is alive.
    static let fallbackInterval: TimeInterval = 1
    /// How far the system may delay the safety-net timer to coalesce it with other wakeups.
    static let fallbackTolerance: TimeInterval = 0.25
    /// How long the safety-net timer keeps running after the last browser closed, or after start, so the work that
    /// follows (a browser's teardown, the first context setup) has it as well.
    static let settleInterval: TimeInterval = 5
    /// Longest wait for one request. CEF asks for a huge delay when it has nothing scheduled.
    static let longestRequestDelay: TimeInterval = 60
    /// A pass at least this long did work and may have been cut short (CEF's slice is about 10 ms; an idle pass takes well
    /// under 1 ms). CEF does not ask for the rest, so such a pass keeps the busy poll going.
    static let workingPassDuration: TimeInterval = 0.002

    /// The default source: timers on the main run loop in `.common` mode, so the pump keeps running during window
    /// drags and menus.
    static let runLoopTimers: TimerSource = { interval, tolerance, repeats, fire in
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            // Fires on the main run loop; CEF's UI thread is the main thread with an external pump.
            MainActor.assumeIsolated { fire() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    private let startTimer: TimerSource
    private let runLoopWork: @MainActor () -> Void
    private let now: @MainActor () -> TimeInterval
    private var cancelFallback: CancelTimer?
    private var cancelSettle: CancelTimer?
    private var cancelBusyPoll: CancelTimer?
    private var cancelBusyEnd: CancelTimer?
    /// CEF's pending delayed request. Only a newer delayed request replaces it.
    private var cancelDelayed: CancelTimer?
    /// The rerun of a request that arrived inside a running loop.
    private var cancelReplay: CancelTimer?
    private var isPerformingWork = false
    private var workWasRequestedWhilePerforming = false
    private var isRunning = false
    /// Browsers that are alive, counted through ``browserDidOpen()`` and ``browserDidClose()``.
    private(set) var liveBrowserCount = 0

    init(
        timers: @escaping TimerSource = CefMessagePump.runLoopTimers,
        runLoopWork: @escaping @MainActor () -> Void = { cef_do_message_loop_work() },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        startTimer = timers
        self.runLoopWork = runLoopWork
        self.now = now
    }

    /// Whether the safety-net timer is running.
    var hasFallbackTimer: Bool { cancelFallback != nil }

    /// Whether the busy poll is running.
    var isPollingBusy: Bool { cancelBusyPoll != nil }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startFallback()
        settleAfterQuiet()
    }

    func stop() {
        isRunning = false
        for cancel in [cancelFallback, cancelSettle, cancelBusyPoll, cancelBusyEnd, cancelDelayed, cancelReplay] {
            cancel?()
        }
        cancelFallback = nil
        cancelSettle = nil
        cancelBusyPoll = nil
        cancelBusyEnd = nil
        cancelDelayed = nil
        cancelReplay = nil
    }

    /// A browser now exists: keep the safety-net timer running until its ``browserDidClose()``.
    func browserDidOpen() {
        liveBrowserCount += 1
        cancelSettle?()
        cancelSettle = nil
        startFallback()
    }

    /// A browser is gone. After the last one, the safety-net timer stops once the settling time has passed.
    func browserDidClose() {
        guard liveBrowserCount > 0 else { return }
        liveBrowserCount -= 1
        if liveBrowserCount == 0 {
            settleAfterQuiet()
        }
    }

    /// Entry point for `on_schedule_message_pump_work`. May be called from any thread.
    nonisolated func scheduleWork(delayMilliseconds: Int64) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.requestWork(delayMilliseconds: delayMilliseconds)
            }
        }
    }

    /// The main-thread half of ``scheduleWork(delayMilliseconds:)``.
    func requestWork(delayMilliseconds: Int64) {
        guard isRunning else { return }
        if delayMilliseconds <= 0 {
            // Only a newer delayed request replaces a pending delayed one (CEF's contract), so this leaves it alone.
            runRequestedWork()
            return
        }
        cancelDelayed?()
        let delay = min(TimeInterval(delayMilliseconds) / 1000.0, Self.longestRequestDelay)
        cancelDelayed = startTimer(delay, 0, false) { [weak self] in
            self?.cancelDelayed = nil
            self?.runRequestedWork()
        }
    }

    /// One pass of CEF's loop. A request that arrives while a pass is running is run again after it, and a pass that ran
    /// long keeps the busy poll going: CEF may have left work for the next pass without asking for it.
    func performWork() {
        guard isRunning else { return }
        guard !isPerformingWork else {
            workWasRequestedWhilePerforming = true
            return
        }
        isPerformingWork = true
        let started = now()
        runLoopWork()
        isPerformingWork = false
        if now() - started >= Self.workingPassDuration {
            extendBusyWindow()
        }
        if workWasRequestedWhilePerforming {
            workWasRequestedWhilePerforming = false
            cancelReplay?()
            cancelReplay = startTimer(0, 0, false) { [weak self] in
                self?.cancelReplay = nil
                self?.performWork()
            }
        }
    }

    /// A pass that CEF asked for: it also starts or extends the busy window.
    private func runRequestedWork() {
        extendBusyWindow()
        performWork()
    }

    private func extendBusyWindow() {
        if cancelBusyPoll == nil {
            cancelBusyPoll = startTimer(Self.busyInterval, 0, true) { [weak self] in
                self?.performWork()
            }
        }
        cancelBusyEnd?()
        let linger = liveBrowserCount > 0 ? Self.busyLingerWithBrowser : Self.busyLingerWithoutBrowser
        cancelBusyEnd = startTimer(linger, 0, false) { [weak self] in
            self?.cancelBusyPoll?()
            self?.cancelBusyPoll = nil
            self?.cancelBusyEnd = nil
        }
    }

    private func startFallback() {
        guard isRunning, cancelFallback == nil else { return }
        cancelFallback = startTimer(Self.fallbackInterval, Self.fallbackTolerance, true) { [weak self] in
            self?.performWork()
        }
    }

    private func settleAfterQuiet() {
        cancelSettle?()
        cancelSettle = startTimer(Self.settleInterval, 1, false) { [weak self] in
            self?.settle()
        }
    }

    private func settle() {
        cancelSettle = nil
        guard liveBrowserCount == 0 else { return }
        cancelFallback?()
        cancelFallback = nil
    }
}
