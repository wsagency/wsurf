// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// The detachable Minimal toolbar: the panel that holds the bar while it is detached, and everything that treats the window and
/// the panel as one. No window is made key (a test host in the background cannot): the key state is read through a seam, and
/// the key unit's rule is a pure struct. Every test that detaches a bar puts the placement back.
@MainActor
@Suite(.serialized)
struct FloatingToolbarTests {
    private func source(_ path: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Windows

    /// The windows a test opened, and the app-wide choices as they were. `finish` closes the windows and puts the choices back.
    private final class Rig {
        let app = BrowserApplication()
        let settings = BrowserSettings.application
        private var coordinators: [AppCoordinator] = []
        private let style: BrowserWindowStyle
        private let placement: MinimalBarPlacement

        private let edge: MinimalBarEdge
        private let offset: CGPoint?

        init() {
            let current = BrowserSettings.application
            style = current.windowStyle
            placement = current.minimalBarPlacement
            edge = current.minimalBarEdge
            offset = current.minimalBarFloatOffset
            current.windowStyle = .minimal
            current.minimalBarPlacement = .window
            current.minimalBarFloatOffset = nil
        }

        func open(micro: Bool = false) throws -> AppCoordinator {
            let browser = BrowserModel(windowID: UUID(), database: .temporary())
            if micro {
                browser.windowKind = .micro
            }
            let coordinator = AppCoordinator(browser: browser)
            app.register(coordinator)
            coordinators.append(coordinator)
            coordinator.showBrowser(activate: false)
            return coordinator
        }

        func finish() {
            coordinators.forEach { $0.closeWindow() }
            settings.minimalBarPlacement = placement
            settings.minimalBarFloatOffset = offset
            settings.minimalBarEdge = edge
            settings.windowStyle = style
        }
    }

    private func panels(of window: NSWindow?) -> [FloatingBarPanel] {
        (window?.childWindows ?? []).compactMap { $0 as? FloatingBarPanel }
    }

    private func host(of coordinator: AppCoordinator) throws -> BrowserHost {
        try #require(coordinator.nativeWindow?.delegate as? BrowserHost)
    }

    /// The host acts on the setting when the observation hops to the main actor; a test asks for the same thing directly.
    private func detach(_ rig: Rig, _ coordinator: AppCoordinator) throws {
        rig.settings.minimalBarPlacement = .floating
        try host(of: coordinator).syncFloatingBar()
    }

    @Test func aDetachedMinimalWindowHasExactlyOnePanelAndDockingRemovesIt() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let window = try #require(coordinator.nativeWindow)
        #expect(panels(of: window).isEmpty, "off by default: no panel exists")

        try detach(rig, coordinator)
        #expect(panels(of: window).count == 1)
        try detach(rig, coordinator)
        #expect(panels(of: window).count == 1, "syncing again makes no second panel")
        let panel = try #require(panels(of: window).first)
        #expect(panel.parent === window)

        coordinator.dockToolbar()
        try host(of: coordinator).syncFloatingBar()
        #expect(panels(of: window).isEmpty)
        #expect(rig.settings.minimalBarPlacement == .window)
    }

    @Test func theHostFollowsThePlacementSettingWithoutBeingAsked() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let window = try #require(coordinator.nativeWindow)

        rig.settings.minimalBarPlacement = .floating
        #expect(await waitUntil(timeout: .seconds(10)) { panels(of: window).count == 1 })

        rig.settings.minimalBarPlacement = .window
        #expect(await waitUntil(timeout: .seconds(10)) { panels(of: window).isEmpty })
    }

    @Test func noPanelIsMadeUnlessTheWindowIsMinimal() throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.settings.minimalBarPlacement = .floating

        rig.settings.windowStyle = .standard
        let standard = try rig.open()
        try host(of: standard).syncFloatingBar()
        #expect(panels(of: standard.nativeWindow).isEmpty, "a Standard window has its own toolbar")

        rig.settings.windowStyle = .minimal
        let micro = try rig.open(micro: true)
        try host(of: micro).syncFloatingBar()
        #expect(panels(of: micro.nativeWindow).isEmpty, "a micro window keeps its bar in the window")
        #expect(!micro.barFloats)
    }

    /// A full-screen window has room for the bar and the child-window path is the least tried: the bar docks for the while, and
    /// the window draws it (`MinimalShell` skips the bar only while `barFloats`).
    @Test func fullScreenDocksTheBarAndLeavingFullScreenBringsThePanelBack() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let window = try #require(coordinator.nativeWindow)
        let bar = try host(of: coordinator)
        try detach(rig, coordinator)
        #expect(coordinator.barFloats)

        bar.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(panels(of: window).isEmpty)
        #expect(!coordinator.barFloats, "the in-window bar is drawn")
        #expect(rig.settings.minimalBarPlacement == .floating, "full screen does not change the choice")

        bar.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(panels(of: window).count == 1)
        #expect(coordinator.barFloats)
    }

    /// Float on Top puts the window above other windows; the bar's panel stays level with it, so the bar is never under its own
    /// window (a child window at a lower level is covered by its parent).
    @Test func thePanelIsAtItsWindowsLevelWhileItFloatsOnTop() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let window = try #require(coordinator.nativeWindow)
        let bar = try host(of: coordinator)
        try detach(rig, coordinator)
        let panel = try #require(panels(of: window).first)
        #expect(panel.level == .normal && window.level == .normal)

        coordinator.floatsOnTop = true
        #expect(window.level == .floating)
        #expect(panel.level == .floating, "the panel follows the window up")

        coordinator.dockToolbar()
        bar.syncFloatingBar()
        try detach(rig, coordinator)
        let second = try #require(panels(of: window).first)
        #expect(second.level == .floating, "a panel made while the window floats starts at its level")

        bar.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(window.level == .normal && panels(of: window).isEmpty, "full screen: normal level, and no panel")
        bar.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        let back = try #require(panels(of: window).first)
        #expect(window.level == .floating && back.level == .floating, "and both are back above other windows")

        coordinator.floatsOnTop = false
        #expect(window.level == .normal && back.level == .normal, "the panel follows the window down")
    }

    @Test func thePanelItsHostingViewItsControllerAndTheWindowAreAllReleased() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let panels = WindowLeakCheck()
        let windows = WindowLeakCheck()
        weak var controller: FloatingBarController?
        weak var hosting: NSView?
        let coordinator = try rig.open()
        let hostObject = try host(of: coordinator)
        do {
            try detach(rig, coordinator)
            let bar = try #require(hostObject.floatingBar)
            let panel = try #require(bar.panel)
            panels.track(panel)
            windows.track(coordinator.nativeWindow)
            controller = bar
            hosting = panel.contentView
        }
        coordinator.dockToolbar()
        hostObject.syncFloatingBar()
        // Counted like every other window leak test: a closed window can sit in an autorelease pool, which is no leak.
        #expect(await waitUntil(timeout: .seconds(10)) { panels.live == 0 && hosting == nil },
                "the docked panel or its hosting view is still alive: \(panels.liveDescription)")

        do {
            try detach(rig, coordinator)
            let bar = try #require(hostObject.floatingBar)
            let panel = try #require(bar.panel)
            panels.track(panel)
            hosting = panel.contentView
        }
        coordinator.closeWindow()
        #expect(await waitUntil(timeout: .seconds(10)) { panels.live == 0 && windows.live == 0 && hosting == nil && controller == nil },
                "the panel, its view, its controller or the window outlived the window: \(panels.liveDescription) \(windows.liveDescription)")
    }

    @Test func aWindowThatNeverFloatsItsBarHasNoControllerAtAll() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let hostObject = try host(of: coordinator)
        #expect(hostObject.floatingBar == nil, "off by default: nothing is made for the window")

        rig.settings.minimalBarPlacement = .floating
        hostObject.syncFloatingBar()
        #expect(hostObject.floatingBar?.panel != nil, "made the first time the bar floats")
    }

    @Test func aFailedFullScreenRestoresThePanelAndTheLevel() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let window = try #require(coordinator.nativeWindow)
        let bar = try host(of: coordinator)
        try detach(rig, coordinator)
        coordinator.floatsOnTop = true

        bar.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(panels(of: window).isEmpty && window.level == .normal)
        bar.windowDidFailToEnterFullScreen(window)
        #expect(!coordinator.windowIsFullScreen, "the flag does not stick")
        #expect(panels(of: window).count == 1, "the panel is back")
        #expect(window.level == .floating && panels(of: window).first?.level == .floating)
    }

    // MARK: - The panel

    private final class SpyWindow: NSWindow {
        var calls: [String] = []
        var answer = true

        override func performMiniaturize(_ sender: Any?) {
            calls.append("miniaturize")
        }

        override func performZoom(_ sender: Any?) {
            calls.append("zoom")
        }

        override func toggleFullScreen(_ sender: Any?) {
            calls.append("fullScreen")
        }

        override func performClose(_ sender: Any?) {
            calls.append("close")
        }

        override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            calls.append("validate")
            return answer
        }
    }

    private func spyWithPanel() -> (SpyWindow, FloatingBarPanel) {
        let spy = SpyWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        spy.isReleasedWhenClosed = false
        let panel = FloatingBarPanel(frame: NSRect(x: 120, y: 120, width: 300, height: 76))
        spy.addChildWindow(panel, ordered: .above)
        return (spy, panel)
    }

    private func tearDown(_ spy: SpyWindow, _ panel: FloatingBarPanel) {
        spy.removeChildWindow(panel)
        panel.close()
        spy.close()
    }

    @Test func thePanelTakesTheKeyboardButIsNeverTheMainWindow() {
        let panel = FloatingBarPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 76))
        defer { panel.close() }

        #expect(panel.canBecomeKey, "the address is typed in it")
        #expect(!panel.canBecomeMain)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.isExcludedFromWindowsMenu)
        #expect(!panel.isReleasedWhenClosed)
        #expect(!panel.isRestorable)
        #expect(panel.accessibilityLabel() == String(localized: "WSurf Toolbar"))
        #expect(panel.accessibilitySubrole() == .floatingWindow)
    }

    @Test func aSheetFromThePanelGoesToTheBrowserWindow() {
        let (spy, panel) = spyWithPanel()
        defer { tearDown(spy, panel) }

        #expect(panel.sheetHost === spy)
        #expect(spy.sheetHost === spy, "any other window is its own host")
        let alone = FloatingBarPanel(frame: .zero)
        defer { alone.close() }
        #expect(alone.sheetHost === alone, "a panel that left its window has nowhere better to go")
    }

    /// The root cause of a certificate sheet, a confirm alert or the pin editor landing on a 44 pt panel: every place that picks
    /// the key window to hang a sheet from goes through `sheetHost`. The Passwords window's own identity check is the exception.
    @Test func everyPlaceThatPicksTheKeyWindowForASheetGoesThroughSheetHost() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "WSurf")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "PasswordsWindow.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("NSApp.keyWindow") && !line.contains("NSApp.keyWindow?.sheetHost")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(url.lastPathComponent):\(number + 1)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func theWindowCommandsAReForwardedToTheBrowserWindow() throws {
        let (spy, panel) = spyWithPanel()
        defer { tearDown(spy, panel) }

        panel.performMiniaturize(nil)
        panel.performZoom(nil)
        panel.toggleFullScreen(nil)
        panel.performClose(nil)
        #expect(spy.calls == ["miniaturize", "zoom", "fullScreen", "close"])

        let item = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        spy.answer = true
        #expect(panel.validateMenuItem(item), "answered by the browser window")
        spy.answer = false
        #expect(!panel.validateMenuItem(item))
        #expect(spy.calls.suffix(2) == ["validate", "validate"])
        for action in [#selector(NSWindow.performZoom(_:)), #selector(NSWindow.toggleFullScreen(_:)), #selector(NSWindow.performClose(_:))] {
            spy.answer = true
            #expect(panel.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")), "\(action)")
        }
    }

    private final class RecordingWindow: NSWindow {
        var madeKey = 0

        override func makeKey() {
            madeKey += 1
        }
    }

    private final class KeyedBarPanel: FloatingBarPanel {
        var keyed = true

        override var isKeyWindow: Bool {
            keyed
        }
    }

    /// The address is edited in the panel; when the edit ends the keyboard goes back to the window, whose first responder is the
    /// page, so Space scrolls it again. Moving into another text field, or a panel that is not key, hands nothing back.
    @Test func whenTheAddressEditEndsTheKeyboardGoesBackToTheWindow() {
        let window = RecordingWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panel = KeyedBarPanel(frame: NSRect(x: 120, y: 120, width: 300, height: 76))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let other = NSTextField(frame: NSRect(x: 0, y: 30, width: 200, height: 24))
        panel.contentView?.addSubview(field)
        panel.contentView?.addSubview(other)
        window.addChildWindow(panel, ordered: .above)
        defer {
            window.removeChildWindow(panel)
            panel.close()
            window.close()
        }

        #expect(panel.makeFirstResponder(field))
        #expect(window.madeKey == 0, "starting an edit hands nothing back")
        #expect(panel.makeFirstResponder(other))
        #expect(window.madeKey == 0, "moving to another field is still editing")
        #expect(panel.makeFirstResponder(nil))
        #expect(window.madeKey == 1, "Return or Escape ended the edit: the window has the keyboard again")

        panel.keyed = false
        #expect(panel.makeFirstResponder(field))
        #expect(panel.makeFirstResponder(nil))
        #expect(window.madeKey == 1, "a panel that was not key has nothing to hand back")
    }

    @Test func aPanelWithNoWindowRefusesTheWindowCommands() {
        let panel = FloatingBarPanel(frame: .zero)
        defer { panel.close() }

        let item = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        #expect(!panel.validateMenuItem(item))
        panel.performMiniaturize(nil)
        #expect(!panel.isMiniaturized)
    }

    @Test func theBarsOwnPanelIsNotSomethingHangingFromTheWindow() {
        let (spy, panel) = spyWithPanel()
        defer { tearDown(spy, panel) }
        spy.orderFront(nil)
        panel.orderFront(nil)
        #expect(panel.isVisible)

        #expect(!MicroShell.isEditing(in: spy), "the bar's panel is the bar, not a reason to hold it")

        let other = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        spy.addChildWindow(other, ordered: .above)
        other.orderFront(nil)
        defer {
            spy.removeChildWindow(other)
            other.close()
        }
        #expect(MicroShell.isEditing(in: spy), "any other panel still holds it")
    }

    @Test func appKitDoesNotMoveThePanelBackIntoTheScreen() {
        let panel = FloatingBarPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 76))
        defer { panel.close() }

        #expect(panel.constrainFrameRect(NSRect(x: -5_000, y: 9_000, width: 300, height: 76), to: NSScreen.main)
            == NSRect(x: -5_000, y: 9_000, width: 300, height: 76), "AppKit does not move the bar back; the clamp does")
    }

    // MARK: - The key unit

    @Test func theKeyboardMovingBetweenTheWindowAndItsPanelIsNotNews() {
        var unit = KeyUnit()

        let first = unit.becameKey()
        #expect(first, "the window became key: the app is told")
        let second = unit.becameKey()
        #expect(!second, "the panel became key as well: the unit was key already")
        let toPanel = unit.resigned(windowIsKey: false, panelIsKey: true)
        #expect(!toPanel, "the window resigned, the panel has the keyboard: the unit still does")
        #expect(unit.isKey)
        let gone = unit.resigned(windowIsKey: false, panelIsKey: false)
        #expect(gone, "neither has it: the unit resigned")
        #expect(!unit.isKey)
        let again = unit.resigned(windowIsKey: false, panelIsKey: false)
        #expect(!again, "once")
        let back = unit.becameKey()
        #expect(back)
    }

    @Test func aWindowThatIsStillKeyDoesNotResignTheUnit() {
        var unit = KeyUnit()
        _ = unit.becameKey()

        let stillKey = unit.resigned(windowIsKey: true, panelIsKey: false)
        #expect(!stillKey)
        #expect(unit.isKey)
        unit.seed(isKey: false)
        #expect(!unit.isKey)
        let nothing = unit.resigned(windowIsKey: false, panelIsKey: false)
        #expect(!nothing, "a unit that was not key has nothing to resign")
    }

    private final class KeyedWindow: NSWindow {
        var keyed = false

        override var isKeyWindow: Bool {
            keyed
        }
    }

    private final class KeyedPanel: FloatingBarPanel {
        var keyed = false

        override var isKeyWindow: Bool {
            keyed
        }
    }

    @Test func aWindowIsKeyWhileItsPanelIsAndNotForAnotherWindowsPanel() {
        let window = KeyedWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panel = KeyedPanel(frame: NSRect(x: 120, y: 120, width: 300, height: 76))
        let stranger = KeyedPanel(frame: NSRect(x: 120, y: 120, width: 300, height: 76))
        window.addChildWindow(panel, ordered: .above)
        defer {
            window.removeChildWindow(panel)
            panel.close()
            stranger.close()
            window.close()
        }

        #expect(!window.isKeyUnit)
        window.keyed = true
        #expect(window.isKeyUnit)
        window.keyed = false
        panel.keyed = true
        #expect(window.isKeyUnit, "typing in the bar is typing in this window")
        panel.keyed = false
        stranger.keyed = true
        #expect(!window.isKeyUnit, "a panel that is not its child is no part of the unit")
        #expect(!panel.isKeyUnit, "nor is a panel the unit of anything: its window answers")
    }

    /// One run-loop turn of the main queue: what `FloatingBarController.memberResignedKey` queued before this has run by then.
    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// The window and the panel as the delegate calls reach the host, with the key state read through the seam. Nothing is
    /// suspended and nothing is forgotten while the keyboard only moves between the two; the app hears when the unit as a whole
    /// gains or loses it.
    @Test func theKeyboardMovingToThePanelDoesNotResignTheWindow() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let other = try rig.open()
        let window = try #require(coordinator.nativeWindow)
        try detach(rig, coordinator)
        let bar = try host(of: coordinator)
        let controller = try #require(bar.floatingBar)
        let panel = try #require(controller.panel)
        let windowKey = Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        let panelKey = Notification(name: NSWindow.didBecomeKeyNotification, object: panel)

        controller.isKey = { $0 === window }
        rig.app.focus(other)
        bar.windowDidBecomeKey(windowKey)
        #expect(rig.app.activeWindowID == coordinator.windowID, "the window became key: the app is told")

        rig.app.focus(other)
        controller.isKey = { $0 === panel }
        controller.windowDidBecomeKey(panelKey)
        #expect(rig.app.activeWindowID == other.windowID, "the panel became key while the unit was: not news")

        coordinator.controlDownAt = 1
        bar.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        await nextTurn()
        #expect(coordinator.controlDownAt == 1, "the window resigned but the panel has the keyboard: nothing was resigned")

        controller.isKey = { _ in false }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        await nextTurn()
        #expect(coordinator.controlDownAt == nil, "neither has it: the window resigned")

        rig.app.focus(other)
        bar.windowDidBecomeKey(windowKey)
        #expect(rig.app.activeWindowID == coordinator.windowID, "and when it comes back the app is told again")
    }

    @Test func withNoPanelTheWindowsKeyChangesAreToldAtOnceAsTheyAlwaysWere() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let other = try rig.open()
        let window = try #require(coordinator.nativeWindow)
        let bar = try host(of: coordinator)

        rig.app.focus(other)
        bar.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(rig.app.activeWindowID == coordinator.windowID)
        rig.app.focus(other)
        bar.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(rig.app.activeWindowID == coordinator.windowID, "told every time, as before")

        coordinator.controlDownAt = 1
        bar.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(coordinator.controlDownAt == nil, "and the resign is not deferred")
    }

    // MARK: - Review fixes: what typing in, clicking in and putting a sheet on the panel must do

    private func keyEvent(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    /// M1: with the address being typed in the panel, the window's key monitor asks the field editor and not the page.
    @Test func escapeTypedInTheFloatingAddressIsLeftToTheFieldAndStopsNothingElse() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        try detach(rig, coordinator)
        let controller = try #require(host(of: coordinator).floatingBar)
        let panel = try #require(controller.panel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        panel.contentView?.addSubview(field)
        controller.isKey = { $0 === panel }
        coordinator.isMinimalTabListOpen = true
        let escape = try keyEvent(53, "\u{1b}")

        #expect(panel.makeFirstResponder(field))
        #expect(panel.firstResponder is NSTextView, "the field editor of the panel has the keyboard")
        #expect(coordinator.keyUnitResponder is NSText, "and that is who the key monitor asks")
        #expect(!coordinator.handleKey(escape), "Escape is the field's: it cancels the edit")
        #expect(coordinator.isMinimalTabListOpen, "the tab list stays")

        #expect(panel.makeFirstResponder(nil))
        #expect(!(coordinator.keyUnitResponder is NSText))
        #expect(coordinator.handleKey(escape), "typing nothing, Escape does its other jobs")
        #expect(!coordinator.isMinimalTabListOpen)
    }

    /// M2: a sheet begun on the panel, by AppKit or by a SwiftUI `.sheet` in the bar, is the browser window's.
    @Test func aSheetBegunOnThePanelAttachesToTheBrowserWindowNotThePanel() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let panel = FloatingBarPanel(frame: NSRect(x: 120, y: 120, width: 300, height: 76))
        parent.addChildWindow(panel, ordered: .above)
        parent.orderFront(nil)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer {
            parent.removeChildWindow(panel)
            panel.close()
            parent.close()
        }

        panel.beginSheet(sheet) { _ in }
        #expect(parent.attachedSheet === sheet, "the browser window holds the sheet")
        #expect(panel.attachedSheet == nil, "the 76 pt strip holds none")
        panel.endSheet(sheet)
        #expect(await waitUntil(timeout: .seconds(10)) { parent.attachedSheet == nil })

        let critical = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        critical.isReleasedWhenClosed = false
        panel.beginCriticalSheet(critical) { _ in }
        #expect(parent.attachedSheet === critical && panel.attachedSheet == nil)
        panel.endSheet(critical, returnCode: .abort)
        #expect(await waitUntil(timeout: .seconds(10)) { parent.attachedSheet == nil })
    }

    private final class KeyUnitSpy: NSWindow {
        var keyed = false
        var raised = 0

        override var isKeyWindow: Bool {
            keyed
        }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            raised += 1
            keyed = true
        }
    }

    private func mouse(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    /// M3: a click in window A's bar while window B has the keyboard acts for A, so A's certificate sheet, the install consent
    /// and a confirm alert are A's, not B's.
    @Test func aClickInAPanelMakesItsOwnWindowTheKeyUnitBeforeAnythingActs() throws {
        let frame = NSRect(x: 100, y: 100, width: 600, height: 400)
        let first = KeyUnitSpy(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let second = KeyUnitSpy(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        let panel = FloatingBarPanel(frame: NSRect(x: 120, y: 120, width: 300, height: 76))
        first.addChildWindow(panel, ordered: .above)
        second.keyed = true
        defer {
            first.removeChildWindow(panel)
            panel.close()
            first.close()
            second.close()
        }

        #expect(!first.isKeyUnit)
        panel.sendEvent(try mouse(.leftMouseDown, in: panel))
        #expect(first.raised == 1 && first.isKeyUnit, "the click made its own window the key unit")
        #expect(second.raised == 0)
        panel.sendEvent(try mouse(.leftMouseDown, in: panel))
        #expect(first.raised == 1, "already the key unit: nothing more")
        first.keyed = false
        panel.sendEvent(try mouse(.leftMouseUp, in: panel))
        #expect(first.raised == 1, "only a press takes the keyboard")

        #expect(CertificatePanel.sheetWindow(for: panel) === first, "the certificate sheet is given its window, not the key one")
        #expect(CertificatePanel.sheetWindow(for: second) === second)
    }

    /// M4: the keyboard went from the panel to the window (a click on the page): the address edit ends.
    @Test func thePanelLosingTheKeyboardToItsWindowEndsTheAddressEdit() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let window = try #require(coordinator.nativeWindow)
        try detach(rig, coordinator)
        let controller = try #require(host(of: coordinator).floatingBar)
        let panel = try #require(controller.panel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        panel.contentView?.addSubview(field)
        controller.listensToAsk = false
        controller.extrasChanged(true)
        let resign = Notification(name: NSWindow.didResignKeyNotification, object: panel)

        #expect(panel.makeFirstResponder(field))
        #expect(panel.firstResponder is NSTextView)
        controller.appIsActive = { false }
        controller.isKey = { $0 === window }
        controller.windowDidResignKey(resign)
        await nextTurn()
        #expect(panel.firstResponder is NSTextView, "the whole app deactivating leaves the edit, as the window's bar does")

        controller.appIsActive = { true }
        controller.isKey = { _ in false }
        controller.windowDidResignKey(resign)
        await nextTurn()
        #expect(panel.firstResponder is NSTextView, "another window took the keyboard: the edit waits")

        controller.isKey = { $0 === window }
        controller.windowDidResignKey(resign)
        await nextTurn()
        #expect(!(panel.firstResponder is NSTextView), "the page has the keyboard: the edit is over")
    }

    /// S1: a window's resign that runs after the next window took focus must not clear that window's extension focus.
    @Test func aResignAfterTheNextWindowBecameKeyDoesNotClearItsExtensionFocus() throws {
        let first = UUID()
        let second = UUID()
        #expect(AppCoordinator.clearsExtensionFocus(activeWindowID: nil, resigning: first), "no window took over: cleared")
        #expect(AppCoordinator.clearsExtensionFocus(activeWindowID: first, resigning: first), "this one was the focused one")
        #expect(!AppCoordinator.clearsExtensionFocus(activeWindowID: second, resigning: first), "another took it: left alone")

        let rig = Rig()
        defer { rig.finish() }
        let one = try rig.open()
        let two = try rig.open()
        rig.app.focus(two)
        let before = one.extensions.actionRevision
        one.windowDidResignKey()
        #expect(one.extensions.actionRevision == before, "two is the focused window: one's late resign touches no extension focus")

        rig.app.focus(one)
        let focused = one.extensions.actionRevision
        one.windowDidResignKey()
        #expect(one.extensions.actionRevision > focused, "the focused window resigning still clears it")
    }

    /// S2: a display that went away, a window that was dragged away, and ⌘L with nothing on screen.
    @Test func aBarWithNoScreenIsDockedAndOneOnAGoneDisplayIsBroughtBack() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let window = try #require(coordinator.nativeWindow)
        try detach(rig, coordinator)
        let controller = try #require(host(of: coordinator).floatingBar)
        let panel = try #require(controller.panel)
        let small = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        controller.screens = { [small] }
        controller.windowDidSettle()
        let row = FloatingBarMetrics.row(inPanel: panel.frame, opensUpward: controller.model.opensUpward, hasExtras: false)
        #expect(small.contains(row), "after the other display went away the bar is on the one that is left: \(row)")

        window.setFrameOrigin(NSPoint(x: 3_000, y: 3_000))
        controller.windowDidMoveOrResize()
        #expect(await waitUntil(timeout: .seconds(10)) {
            small.contains(FloatingBarMetrics.row(inPanel: panel.frame, opensUpward: controller.model.opensUpward, hasExtras: false))
        }, "a window dragged away does not take the bar off every screen")

        controller.screens = { [] }
        controller.makeKey()
        #expect(rig.settings.minimalBarPlacement == .window, "nowhere to put it: docked, and no invisible panel took the keyboard")
        #expect(panels(of: window).isEmpty)
    }

    // MARK: - Dragging and Ask

    @Test func aDragSavesThePlaceOnceKeepsItOnAScreenAndEveryWindowFollows() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = try rig.open()
        let second = try rig.open()
        let window = try #require(first.nativeWindow)
        let otherWindow = try #require(second.nativeWindow)
        try detach(rig, first)
        try detach(rig, second)
        let controller = try #require(host(of: first).floatingBar)
        let panel = try #require(controller.panel)
        let otherPanel = try #require(host(of: second).floatingBar?.panel)
        #expect(rig.settings.minimalBarFloatOffset == nil, "nothing is saved until a drag ends")

        panel.setFrame(NSRect(origin: NSPoint(x: -4_000, y: -4_000), size: panel.frame.size), display: false)
        panel.onDragEnd?()

        let up = controller.model.opensUpward
        let row = FloatingBarMetrics.row(inPanel: panel.frame, opensUpward: up, hasExtras: false)
        #expect(FloatingBarMetrics.clamped(row: row, in: NSScreen.screens.map(\.visibleFrame)) == row, "back on a screen")
        let saved = try #require(rig.settings.minimalBarFloatOffset)
        #expect(saved == FloatingBarMetrics.offset(of: row, in: window.frame), "relative to the window's origin")

        #expect(await waitUntil(timeout: .seconds(10)) {
            let follower = FloatingBarMetrics.row(inPanel: otherPanel.frame, opensUpward: up, hasExtras: false)
            let place = FloatingBarMetrics.offset(of: follower, in: otherWindow.frame)
            return abs(place.x - saved.x) < 0.001 && abs(place.y - saved.y) < 0.001
        }, "the other Minimal window shows its panel at the same relative place")
    }

    @Test func askMakesRoomOnceWhenItOpensAndGivesItBackWhenItCloses() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        try detach(rig, coordinator)
        let controller = try #require(host(of: coordinator).floatingBar)
        let panel = try #require(controller.panel)
        controller.listensToAsk = false
        let before = panel.frame
        let up = controller.model.opensUpward

        controller.extrasChanged(true)
        #expect(panel.frame.height == before.height + FloatingBarMetrics.askHeadroom)
        let opened = FloatingBarMetrics.row(inPanel: panel.frame, opensUpward: up, hasExtras: true)
        let closed = FloatingBarMetrics.row(inPanel: before, opensUpward: up, hasExtras: false)
        #expect(abs(opened.minY - closed.minY) < 0.001 && abs(opened.minX - closed.minX) < 0.001, "the row did not move")
        #expect(controller.model.opensUpward == up, "the direction is frozen while Ask is open")

        let resized = panel.frame
        controller.extrasChanged(true)
        #expect(panel.frame == resized, "the same answer again changes nothing")

        controller.extrasChanged(false)
        #expect(abs(panel.frame.height - before.height) < 0.001 && abs(panel.frame.minY - before.minY) < 0.001)
    }

    // MARK: - Entry points

    @Test func theViewMenuNamesWhatItWillDoAndDocksToTheEdgeItIsSentTo() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let items = try #require(NSApp.mainMenu).items.compactMap(\.submenu).flatMap(\.items)
        let detach = try #require(items.first { $0.title == String(localized: "Detach Toolbar") })

        #expect(menu.validateMenuItem(detach))
        #expect(detach.title == String(localized: "Detach Toolbar"))
        coordinator.toggleToolbarDetached()
        #expect(rig.settings.minimalBarPlacement == .floating)
        #expect(menu.validateMenuItem(detach))
        #expect(detach.title == String(localized: "Dock Toolbar"))

        let edge = rig.settings.minimalBarEdge
        coordinator.moveMinimalBar()
        #expect(rig.settings.minimalBarPlacement == .window, "Move Bar docks to the edge it is sent to")
        #expect(rig.settings.minimalBarEdge != edge)
    }

    @Test func theViewMenuItemIsOnlyForTheMinimalWindow() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let items = try #require(NSApp.mainMenu).items.compactMap(\.submenu).flatMap(\.items)
        let detach = try #require(items.first { $0.title == String(localized: "Detach Toolbar") })

        rig.settings.windowStyle = .standard
        #expect(!menu.validateMenuItem(detach), "a Standard window has its own toolbar")
        coordinator.toggleToolbarDetached()
        #expect(rig.settings.minimalBarPlacement == .window, "and the command does nothing there")

        let micro = try rig.open(micro: true)
        rig.settings.windowStyle = .minimal
        #expect(!MainMenu(coordinator: micro).validateMenuItem(detach), "a micro window holds one page")
    }

    @Test func theBarFloatsOnlyInAMinimalWindowThatIsNotFullScreen() throws {
        let rig = Rig()
        defer { rig.finish() }
        let coordinator = try rig.open()

        #expect(!coordinator.barFloats, "off by default")
        rig.settings.minimalBarPlacement = .floating
        #expect(coordinator.barFloats)
        coordinator.windowIsFullScreen = true
        #expect(!coordinator.barFloats)
        coordinator.windowIsFullScreen = false
        rig.settings.windowStyle = .standard
        #expect(!coordinator.barFloats)
    }

    // MARK: - Sources

    @Test func thePanelHostsTheSameBarAndTheShellOnlyReadsTheDerivedFlag() throws {
        for file in [
            "WSurf/UI/Shell/Minimal/MinimalShell.swift", "WSurf/UI/Shell/BrowserView.swift", "WSurf/UI/Shell/BrowserHost.swift",
        ] {
            let text = try source(file)
            #expect(!text.contains("minimalBarPlacement"), "\(file) decides on barFloats, never on the setting alone")
        }
        #expect(try source("WSurf/UI/Shell/BrowserHost.swift").contains(".browserWindowEnvironment(coordinator)"))
        #expect(try source("WSurf/UI/Shell/Minimal/FloatingBarController.swift").contains(".browserWindowEnvironment(coordinator)"))
    }

    @Test func theDockButtonAndTheContextMenuAreLabelled() throws {
        let sidebar = try source("WSurf/UI/Sidebar/Sidebar.swift")
        #expect(sidebar.contains(#"symbol: "dock.rectangle""#))
        #expect(sidebar.contains(#".accessibilityLabel(Text("Dock Toolbar"))"#))
        #expect(try source("WSurf/UI/Shell/Minimal/IslandBar.swift").contains(".contextMenu"))
    }
}
