// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserPage {
    /// The script's answer as `Value`, or nil when it errors, answers another type, or the page has not
    /// answered within `ceiling`. A page that stops answering never completes the underlying call, so
    /// the wait is bounded here rather than by awaiting it.
    func evaluateJavaScript<Value: Sendable>(_ script: String, within ceiling: Duration, as type: Value.Type) async -> Value? {
        await PageReply<Value>.awaiting(within: ceiling) { gate in
            Task { gate.finish((try? await self.evaluateJavaScript(script)) as? Value) }
        }
    }
}

/// Resumes its caller once, with the first of the answer or the ceiling.
@MainActor
final class PageReply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var ceiling: Task<Void, Never>?

    private init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value?) {
        continuation?.resume(returning: value)
        continuation = nil
        ceiling?.cancel()
    }

    static func awaiting(within ceiling: Duration, _ start: (PageReply<Value>) -> Void) async -> Value? {
        await withCheckedContinuation { continuation in
            let gate = PageReply(continuation)
            gate.ceiling = Task {
                try? await Task.sleep(for: ceiling)
                gate.finish(nil)
            }
            start(gate)
        }
    }
}
