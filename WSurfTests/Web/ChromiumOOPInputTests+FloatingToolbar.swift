// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Testing

@testable import CefKit
@testable import WSurf

extension ChromiumOOPInputTests {
    private final class KeyPanel: FloatingBarPanel {
        override var isKeyWindow: Bool {
            true
        }
    }

    @Test func latePageKeysAndFocusCannotLeaveTheFloatingAddress() async throws {
        let rig = try makeRig()
        do {
            let window = try #require(rig.window as? KeyWindow)
            let panel = KeyPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 76))
            window.addChildWindow(panel, ordered: .above)
            defer {
                window.removeChildWindow(panel)
                panel.close()
            }
            let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            panel.contentView?.addSubview(address)
            let nextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
            rig.page.addSubview(nextField)
            rig.view.nextKeyView = nextField
            nextField.nextKeyView = rig.view
            try await withMenu { hits in
                let find = try Self.key("f", code: 3, flags: .command, in: window)
                try #require(rig.view.performKeyEquivalent(with: find))
                window.keyed = false
                try #require(panel.makeFirstResponder(address))
                try #require(panel.firstResponder is NSTextView)
                try #require(window.firstResponder === rig.view, "the inactive window retains its page responder")
                rig.remote.remoteEvent(unhandled(rig, code: 3, modifiers: ChromiumRemoteContentView.modifiers(.command)))
                #expect(hits.hits.isEmpty, "a delayed page-first chord cannot invoke the app menu")
                #expect(rig.view.sentKeyDowns.isEmpty, "the stale report is consumed")
                for forward in [true, false] {
                    let take = CefRemoteMessage(CefRemote.Event.takeFocus, browser: rig.remote.id)
                    take.set(CefRemote.Key.flag, forward)
                    rig.remote.remoteEvent(take)
                    #expect(window.firstResponder === rig.view, "a delayed Tab cannot move the inactive window's focus")
                    #expect(panel.firstResponder is NSTextView)
                }
            }
        } catch {
            await rig.end()
            throw error
        }
        await rig.end()
    }
}
