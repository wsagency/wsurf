// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

actor WebViewGate {
    static let shared = WebViewGate(limit: max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    private struct Waiter {
        let permits: Int
        let continuation: CheckedContinuation<Int, Never>
    }

    private let limit: Int
    private var active = 0
    private var waiting: [Waiter] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire(exclusive: Bool) async -> Int {
        let permits = exclusive ? limit : 1
        guard waiting.isEmpty, active + permits <= limit else {
            return await withCheckedContinuation { continuation in
                waiting.append(Waiter(permits: permits, continuation: continuation))
            }
        }
        active += permits
        return permits
    }

    func release(_ permits: Int) {
        active -= permits
        while let next = waiting.first, active + next.permits <= limit {
            waiting.removeFirst()
            active += next.permits
            next.continuation.resume(returning: next.permits)
        }
    }
}

/// Requires an enclosing `.boundedWebViews` trait to acquire exclusive cache capacity.
nonisolated struct RequiresBackForwardCache: TestTrait {}

extension Trait where Self == RequiresBackForwardCache {
    static var requiresBackForwardCache: Self {
        Self()
    }
}

nonisolated struct BoundedWebViews: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else {
            try await function()
            return
        }
        let requiresCache = test.traits.contains { $0 is RequiresBackForwardCache }
        let permits = await WebViewGate.shared.acquire(exclusive: requiresCache)
        do {
            try await function()
        } catch {
            await WebViewGate.shared.release(permits)
            throw error
        }
        await WebViewGate.shared.release(permits)
    }
}

extension Trait where Self == BoundedWebViews {
    static var boundedWebViews: Self {
        Self()
    }
}

/// Some of what a test reaches for belongs to the whole process — the stub
/// that catches an app hand-off, for one. Suites that install one take this
/// so no other suite is running while they do.
actor ExclusiveResource {
    static let externalApp = ExclusiveResource()

    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

nonisolated struct ExclusiveExternalApp: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else {
            try await function()
            return
        }
        await ExclusiveResource.externalApp.acquire()
        do {
            try await function()
        } catch {
            await ExclusiveResource.externalApp.release()
            throw error
        }
        await ExclusiveResource.externalApp.release()
    }
}

extension Trait where Self == ExclusiveExternalApp {
    static var exclusiveExternalApp: Self {
        Self()
    }
}
