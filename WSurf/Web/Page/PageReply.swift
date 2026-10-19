// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

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

extension BrowserPage {
    /// The string an async function `body` returns in the automation world, or nil when the call fails, the caller is
    /// cancelled or `ceiling` passes first. A body that waits in the page ends with the page's own timer long before
    /// the ceiling, which only guards a page that never answers.
    func callAsyncJavaScript(_ body: String, within ceiling: Duration, in frame: BrowserFrame?) async -> String? {
        await PageReply<String>.awaiting(within: ceiling) { gate in
            Task {
                gate.finish((try? await self.callAsyncJavaScript(body, in: frame, contentWorld: PageAutomationGuard.world)) as? String)
            }
        }
    }
}

extension BrowserPage {
    /// What an async function `body` returns in `world`, as `Value`, or nil when the call fails, answers another type, the
    /// caller is cancelled or `ceiling` passes first. `arguments` reach the body as variables.
    ///
    /// Unlike the plain script calls, which Chromium runs as a user gesture, this never claims one: a script that only reads
    /// the page must not hand it an activation it never had. WebKit uses the native completion handler for the reason
    /// `evaluateJavaScript(_:within:as:)` does, and repeats the synchronous guards of the call it replaces.
    func callAsyncJavaScript<Value: Sendable>(
        _ body: String,
        arguments: [String: any Sendable] = [:],
        in world: WKContentWorld,
        within ceiling: Duration,
        as type: Value.Type
    ) async -> Value? {
        await PageReply<Value>.awaiting(within: ceiling) { gate in
            guard let native = webKit else {
                Task {
                    let answer = try? await self.callAsyncJavaScript(
                        body, in: nil, contentWorld: world, prepareArguments: { arguments }
                    )
                    gate.finish(answer as? Value)
                }
                return
            }
            guard !isClosed, PageAutomationGuard.allowsExecution, PageDriver.selectedFrame == nil else {
                gate.finish(nil)
                return
            }
            native.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { gate.finish((try? $0.get()) as? Value) }
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
