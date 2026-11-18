// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Testing

@testable import WSurf

extension FloatingToolbarTests {
    @Test(arguments: [false, true])
    func returningFromAnotherWindowEndsOnlyAnEditLeftForThePage(returnToPanel: Bool) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = try rig.open()
        let second = try rig.open()
        let window = try #require(first.nativeWindow)
        try detach(rig, first)
        let controller = try #require(host(of: first).floatingBar)
        let panel = try #require(controller.panel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        panel.contentView?.addSubview(field)
        controller.appIsActive = { true }
        controller.isKey = { $0 === panel }
        controller.memberBecameKey()
        await nextTurn()
        try #require(panel.makeFirstResponder(field))
        try #require(panel.firstResponder is NSTextView)

        controller.isKey = { _ in false }
        rig.app.focus(second)
        controller.memberResignedKey()
        await nextTurn()
        #expect(panel.firstResponder is NSTextView, "another window parks the edit")

        controller.isKey = { $0 === (returnToPanel ? panel : window) }
        controller.memberBecameKey()
        await nextTurn()
        #expect((panel.firstResponder is NSTextView) == returnToPanel)
    }

    @Test func aLateResignClearsTheOldProfilesExtensionFocusOnly() throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = try rig.open()
        let otherContext = BrowserProfileContext(profile: .privateBrowsing())
        let second = AppCoordinator(browser: BrowserModel(context: otherContext, windowID: UUID()))
        rig.app.register(second)
        defer { second.closeWindow() }
        try #require(first.extensions !== second.extensions)
        rig.app.focus(first)
        rig.app.focus(second)
        let oldRevision = first.extensions.actionRevision
        let newRevision = second.extensions.actionRevision
        first.windowDidResignKey()
        #expect(first.extensions.actionRevision > oldRevision, "the old profile hears that it lost focus")
        #expect(second.extensions.actionRevision == newRevision, "the destination profile retains focus")
    }
}
