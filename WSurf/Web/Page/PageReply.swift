// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserPage {
    /// The script's answer as `Value`, or nil when it errors, answers another type, the caller is
    /// cancelled, or the page has not answered within `ceiling`.
    ///
    /// A WebKit page that never answers never completes its call, so a task awaiting
    /// `evaluateJavaScript` would hold this page, and with it the busy web-content process, for
    /// good. The WebKit branch therefore uses the native completion handler, which captures only the
    /// gate. It repeats the two synchronous guards `evaluateJavaScript(_:in:contentWorld:)` applies
    /// to a call with no frame. A Chromium page answers or fails within its own command timeout, and
    /// `close()` fails what is pending, so it keeps the existing async call.
    func evaluateJavaScript<Value: Sendable>(_ script: String, within ceiling: Duration, as type: Value.Type) async -> Value? {
        await PageReply<Value>.awaiting(within: ceiling) { gate in
            guard let native = webKit else {
                Task { gate.finish((try? await self.evaluateJavaScript(script)) as? Value) }
                return
            }
            guard !isClosed, PageAutomationGuard.allowsExecution, PageDriver.selectedFrame == nil else {
                gate.finish(nil)
                return
            }
            native.evaluateJavaScript(script, in: nil, in: .page) { gate.finish((try? $0.get()) as? Value) }
        }
    }
}

/// Resumes its caller once, with the first of the answer, the caller's cancellation or the ceiling.
@MainActor
final class PageReply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var ceiling: Task<Void, Never>?
    private var isFinished = false

    func finish(_ value: Value?) {
        guard !isFinished else { return }
        isFinished = true
        ceiling?.cancel()
        continuation?.resume(returning: value)
        continuation = nil
    }

    static func awaiting(within ceiling: Duration, _ start: (PageReply<Value>) -> Void) async -> Value? {
        let gate = PageReply<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.continuation = continuation
                guard !Task.isCancelled else {
                    gate.finish(nil)
                    return
                }
                gate.ceiling = Task {
                    try? await Task.sleep(for: ceiling)
                    gate.finish(nil)
                }
                start(gate)
            }
        } onCancel: {
            Task { @MainActor in gate.finish(nil) }
        }
    }
}
