// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import os

// D4 phase 2: the two lifecycle rules of the Chromium service, as logic with no XPC, no CEF and no real clock in it.
//
// - `CefRemoteLinger` (the service's side): with no browser open the service stays up for the linger, then exits. Memory
//   pressure ends the wait at once.
// - `CefRemoteRelaunchPolicy` (WSurf's side): when the service dies, relaunch it at once, unless it keeps dying.

/// How long an idle service stays up, and when it leaves.
///
/// The owner tells it how many browsers exist (`browserCountChanged`) and whether the system is short of memory
/// (`memoryPressureChanged`); it calls `onExit` once, when the service should flush and quit. The timer comes from outside
/// (`CefRemoteScheduler`), so a test runs it on a clock it controls.
public final class CefRemoteLinger: Sendable {
    public enum Reason: Equatable, Sendable {
        /// No browser for the whole linger.
        case lingerOver
        /// The system is short of memory and no browser is open.
        case memoryPressure
    }

    /// The linger when the hello names none (decision Q4).
    public static let defaultSeconds: TimeInterval = 60
    /// The shortest linger a hello may ask for.
    public static let minimumSeconds: TimeInterval = 1

    private struct State {
        var seconds: TimeInterval
        var browsers = 0
        var underPressure = false
        var cancelTimer: (@Sendable () -> Void)?
        /// Which wait the timer slot belongs to: bumped whenever a wait starts or is ended. A timer that fires late, or a
        /// start that attaches late, checks it, so it can only act on its own wait.
        var generation = 0
        var exited = false
    }

    /// Ends the current wait: the slot is emptied and its cancel is handed back, to be called outside the lock.
    private static func endWait(_ state: inout State) -> (@Sendable () -> Void)? {
        state.generation += 1
        defer { state.cancelTimer = nil }
        return state.cancelTimer
    }

    private let schedule: CefRemoteScheduler
    private let onExit: @Sendable (Reason) -> Void
    private let state: OSAllocatedUnfairLock<State>

    public init(
        seconds: TimeInterval = CefRemoteLinger.defaultSeconds,
        schedule: @escaping CefRemoteScheduler,
        onExit: @escaping @Sendable (Reason) -> Void
    ) {
        self.schedule = schedule
        self.onExit = onExit
        state = OSAllocatedUnfairLock(initialState: State(seconds: max(Self.minimumSeconds, seconds)))
    }

    /// The service is up with no browser: the linger starts now, so if nothing ever opens, it leaves. Call it once, after the
    /// hello has set the linger.
    public func start() {
        startTimerIfNeeded()
    }

    public var seconds: TimeInterval { state.withLock { $0.seconds } }
    public var hasExited: Bool { state.withLock { $0.exited } }

    /// Takes the hello's linger (never below the minimum). It applies to the next wait; one already running keeps its end.
    public func setSeconds(_ seconds: TimeInterval) {
        state.withLock { $0.seconds = max(Self.minimumSeconds, seconds) }
    }

    /// The number of open browsers changed. Zero starts the linger; anything above zero cancels it.
    public func browserCountChanged(_ count: Int) {
        let (reason, cancel): (Reason?, (@Sendable () -> Void)?) = state.withLock { state in
            guard !state.exited else { return (nil, nil) }
            state.browsers = count
            if count > 0 {
                return (nil, Self.endWait(&state))
            }
            guard state.underPressure else { return (nil, nil) }
            return (Reason.memoryPressure, Self.exit(&state))
        }
        cancel?()
        if let reason {
            onExit(reason)
        } else if count <= 0 {
            startTimerIfNeeded()
        }
    }

    /// The system's memory pressure rose or fell. Under pressure a service with no browser leaves at once, and so does one
    /// that loses its last browser later; a service with browsers open is not touched.
    public func memoryPressureChanged(isUnder: Bool) {
        let cancel: (@Sendable () -> Void)? = state.withLock { state in
            state.underPressure = isUnder
            guard isUnder, !state.exited, state.browsers == 0 else { return nil }
            return Self.exit(&state) ?? {}
        }
        if let cancel {
            cancel()
            onExit(.memoryPressure)
        }
    }

    private func startTimerIfNeeded() {
        let wait: (delay: TimeInterval, generation: Int)? = state.withLock { state in
            guard !state.exited, state.browsers == 0, state.cancelTimer == nil else { return nil }
            state.generation += 1
            state.cancelTimer = {}  // The slot is taken before the timer exists, so two callers cannot both start one.
            return (state.seconds, state.generation)
        }
        guard let wait else { return }
        let cancel = schedule(wait.delay) { [weak self] in self?.timerFired(generation: wait.generation) }
        let attached: Bool = state.withLock { state in
            // The slot may have been ended, or taken by a newer wait, while the timer was being made.
            guard state.generation == wait.generation, !state.exited, state.browsers == 0 else { return false }
            state.cancelTimer = cancel
            return true
        }
        if !attached {
            cancel()
        }
    }

    private func timerFired(generation: Int) {
        let cancel: (@Sendable () -> Void)? = state.withLock { state in
            // A browser that opened while the timer was already firing is the reason this check exists, and `generation` is
            // why a timer of an earlier wait cannot end a later one: a cancelled timer may still fire.
            guard !state.exited, state.browsers == 0, state.generation == generation else { return nil }
            return Self.exit(&state) ?? {}
        }
        if let cancel {
            cancel()
            onExit(.lingerOver)
        }
    }

    /// The service is leaving: no wait is left. Returns the cancel of the wait that was running, to be called outside the lock.
    private static func exit(_ state: inout State) -> (@Sendable () -> Void)? {
        state.exited = true
        return endWait(&state)
    }
}

/// What WSurf does when the Chromium service ends.
///
/// WSurf cannot tell a crash from the service's own idle exit (the linger, memory pressure): both arrive as an interrupted
/// or invalid connection. The rule is on what WSurf had in the service: an end while WSurf has at least one browser in it or
/// a request pending is a death; an end with neither is an idle exit, which is neither recorded nor relaunched (the next
/// page launches the service). Without that rule an idle service would be relaunched at once, linger, exit and be relaunched
/// again every linger, and every idle exit would count toward the crash-loop cap. The caller says which case it is with
/// `serviceWasInUse`.
///
/// A death relaunches at once. If the service dies `maxDeaths` times within `window` seconds it is in a crash loop: no more
/// automatic relaunches until the person reloads a page (`userReload`). All times come from the caller, so a test passes its
/// own clock; production passes a monotonic one (`ProcessInfo.systemUptime`), never wall time.
public struct CefRemoteRelaunchPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case relaunch
        /// The service keeps dying. Pages show their crash state until `userReload`.
        case crashLooping
        /// The service ended with no browser in it and no request pending: not a death. Do not relaunch.
        case idleExit
    }

    public let maxDeaths: Int
    public let window: TimeInterval
    /// Times of the deaths that still count, oldest first.
    public private(set) var recentDeaths: [TimeInterval] = []
    public private(set) var isCrashLooping = false

    public init(maxDeaths: Int = 3, window: TimeInterval = 30) {
        self.maxDeaths = maxDeaths
        self.window = window
    }

    /// The service ended at `now`. `serviceWasInUse` is whether WSurf had a browser in it or a request pending; false makes it
    /// an idle exit (`.idleExit`, nothing recorded, the crash-loop state untouched). A death while already crash-looping stays
    /// a crash loop.
    public mutating func recordDeath(at now: TimeInterval, serviceWasInUse: Bool = true) -> Decision {
        guard serviceWasInUse else { return .idleExit }
        recentDeaths.removeAll { now - $0 >= window }
        recentDeaths.append(now)
        if isCrashLooping || recentDeaths.count >= maxDeaths {
            isCrashLooping = true
            return .crashLooping
        }
        return .relaunch
    }

    /// The person reloaded a page: the count starts over and the next death relaunches again.
    public mutating func userReload() {
        recentDeaths.removeAll()
        isCrashLooping = false
    }
}
