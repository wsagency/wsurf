// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import os

// D4 phase 2: the table of requests WSurf has sent to the Chromium service and is waiting on.
//
// Contract: every request ends exactly once, on one of three events (`CefRemoteReply`): the service answered, the connection
// to it was interrupted, or the timeout ran out. Whoever takes the request out of the table first ends it; the others find
// nothing and do nothing. So a reply that arrives after its timeout is dropped, and a timer that fires after its reply does
// nothing. Nothing in WSurf waits on the service: a request is a completion that runs later, or an `await`.

/// How a request ended.
public enum CefRemoteReply<Value: Sendable>: Sendable {
    case value(Value)
    /// The timeout ran out before any reply.
    case timedOut
    /// The service's connection was interrupted or invalidated (a crash, an exit, a relaunch) before any reply.
    case interrupted
}

extension CefRemoteReply: Equatable where Value: Equatable {}

/// Calls `fire` after `seconds` and returns the closure that cancels it. Nothing assumes a cancelled timer is really stopped:
/// a timer that fires late finds its work already done. The clock of production is ``cefRemoteTimer(on:)``; a test passes a
/// scheduler it fires by hand.
public typealias CefRemoteScheduler = @Sendable (_ seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> @Sendable () -> Void

/// The timer of production: `fire` runs on `queue` after the delay.
public func cefRemoteTimer(on queue: DispatchQueue) -> CefRemoteScheduler {
    { seconds, fire in
        // DispatchWorkItem.cancel() may be called from any thread.
        nonisolated(unsafe) let item = DispatchWorkItem(block: fire)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }
}

public final class CefRemoteRequests<Value: Sendable>: Sendable {
    public typealias Completion = @Sendable (CefRemoteReply<Value>) -> Void

    private struct Pending {
        let completion: Completion
        let cancelTimer: @Sendable () -> Void
    }

    private struct State {
        var next: Int64 = 1
        var pending: [Int64: Pending] = [:]
    }

    /// The timeout of a request that names none.
    public let defaultTimeout: TimeInterval
    private let schedule: CefRemoteScheduler
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(defaultTimeout: TimeInterval = 5, schedule: CefRemoteScheduler? = nil) {
        self.defaultTimeout = defaultTimeout
        self.schedule = schedule ?? cefRemoteTimer(on: DispatchQueue(label: "wsurf.cef-remote.requests", qos: .userInitiated))
    }

    /// A table that goes away with requests pending ends them with `.interrupted`, so a `begin(completion:)` caller whose table
    /// is replaced (a new one per connection, say) still gets its one completion.
    deinit {
        interruptAll()
    }

    /// Requests that have been started and not ended.
    public var pendingCount: Int { state.withLock { $0.pending.count } }

    /// Registers a request and returns its id, which goes out in the message (`Key.identifier`). `completion` runs once, on
    /// whatever thread ends the request (the connection's queue, the timer's queue, or the caller's for `interruptAll`).
    /// Register first, send second: a reply can come before `send` returns.
    public func begin(timeout: TimeInterval? = nil, completion: @escaping Completion) -> Int64 {
        let id = state.withLock { table in
            defer { table.next += 1 }
            table.pending[table.next] = Pending(completion: completion, cancelTimer: {})
            return table.next
        }
        // The request is in the table before the timer exists, so a timer that fires at once finds it. The timer's cancel
        // is attached afterwards, unless the request has already ended, in which case the timer is cancelled here.
        let cancel = schedule(timeout ?? defaultTimeout) { [weak self] in
            self?.end(id, with: .timedOut)
        }
        let stillWaiting: Bool = state.withLock { table in
            guard let pending = table.pending[id] else { return false }
            table.pending[id] = Pending(completion: pending.completion, cancelTimer: cancel)
            return true
        }
        if !stillWaiting {
            cancel()
        }
        return id
    }

    /// Registers a request, sends it through `send` (given the request's id) and returns how it ended. Cancelling the
    /// awaiting task does not end the request early: the timeout still does.
    public func request(timeout: TimeInterval? = nil, send: @Sendable (Int64) -> Void) async -> CefRemoteReply<Value> {
        await withCheckedContinuation { continuation in
            let id = begin(timeout: timeout) { continuation.resume(returning: $0) }
            send(id)
        }
    }

    /// The service answered request `id`. False when the request is not (or no longer) waiting, for example because its
    /// timeout already ended it: the late reply is dropped.
    @discardableResult
    public func reply(_ id: Int64, _ value: Value) -> Bool {
        end(id, with: .value(value))
    }

    /// The connection ended: every waiting request ends with `.interrupted`. Returns how many it ended.
    @discardableResult
    public func interruptAll() -> Int {
        let ids = state.withLock { Array($0.pending.keys) }
        return ids.filter { end($0, with: .interrupted) }.count
    }

    @discardableResult
    private func end(_ id: Int64, with outcome: CefRemoteReply<Value>) -> Bool {
        guard let pending = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return false }
        pending.cancelTimer()
        pending.completion(outcome)
        return true
    }
}
