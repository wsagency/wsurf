// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Testing

@testable import WSurf

/// The credential sheet is physically owned by the awaiting task: real windows and real alerts, no authenticator and no user.
@MainActor
struct NativeSheetTests {
    private func anchor() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func alert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Native sheet test"
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// Dismisses what the test left open, so no sheet outlives its window.
    private func close(_ windows: [NSWindow]) {
        for window in windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            window.close()
        }
    }

    @Test func cancellingTheAwaitingTaskDismissesItsSheetAndAnswersCancelled() async throws {
        let window = anchor(), alert = alert()
        defer { close([window]) }
        let presenting = Task { await NativeSheet.present(alert, in: window, until: nil) }

        #expect(await waitUntil { window.attachedSheet === alert.window }, "the sheet is shown on its own window")
        presenting.cancel()
        let outcome = await presenting.value

        guard case .cancelled = outcome else {
            Issue.record("a cancelled request answered \(outcome)")
            return
        }
        #expect(await waitUntil { window.attachedSheet == nil }, "the cancelled request left no sheet alive")
    }

    @Test func aTaskCancelledBeforeItPresentsNeverShowsASheet() async throws {
        let window = anchor(), alert = alert()
        defer { close([window]) }
        let presenting = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await NativeSheet.present(alert, in: window, until: nil)
        }
        presenting.cancel()
        let outcome = await presenting.value

        guard case .cancelled = outcome else {
            Issue.record("an already-cancelled request answered \(outcome)")
            return
        }
        #expect(window.attachedSheet == nil, "an already-cancelled task shows nothing")
        #expect(!alert.window.isVisible)
    }

    @Test func cancellingOneRequestEndsOnlyItsOwnSheet() async throws {
        let first = anchor(), second = anchor(), firstAlert = alert(), secondAlert = alert()
        defer { close([first, second]) }
        let cancelled = Task { await NativeSheet.present(firstAlert, in: first, until: nil) }
        let kept = Task { await NativeSheet.present(secondAlert, in: second, until: nil) }
        #expect(await waitUntil { first.attachedSheet === firstAlert.window && second.attachedSheet === secondAlert.window })

        cancelled.cancel()
        _ = await cancelled.value

        #expect(await waitUntil { first.attachedSheet == nil })
        #expect(second.attachedSheet === secondAlert.window, "another request's sheet is untouched")
        // The surviving request still answers like any sheet: its own button.
        second.endSheet(secondAlert.window, returnCode: .alertFirstButtonReturn)
        guard case .response(let response) = await kept.value else {
            Issue.record("the untouched request did not answer")
            return
        }
        #expect(response == .alertFirstButtonReturn)
    }
}
