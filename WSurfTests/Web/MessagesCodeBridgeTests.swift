// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What the native code field takes for a code. Every value here is synthetic: no real code, and no Messages or Mail.
struct MessagesCodeTests {
    @Test func aCodeIsTrimmedAndThreeToTwelveLettersAndDigits() {
        #expect(MessagesCode.plausible("123456") == "123456")
        #expect(MessagesCode.plausible(" 482913\n") == "482913")
        #expect(MessagesCode.plausible("AB12cd") == "AB12cd")
        #expect(MessagesCode.plausible("123") == "123")
        #expect(MessagesCode.plausible("123456789012") == "123456789012")
        for text in ["", "12", "1234567890123", "12 34", "12-34", "1234!", "١٢٣٤٥٦", "12\u{200B}34"] {
            #expect(MessagesCode.plausible(text) == nil, "\(text)")
        }
    }

    @Test func onlyAWholeCodeInOneEditCounts() {
        #expect(MessagesCode.inserted(from: "", to: "123456") == "123456")
        #expect(MessagesCode.inserted(from: "", to: "1") == nil, "a typed character")
        #expect(MessagesCode.inserted(from: "12", to: "123") == nil, "typing a third character is not a code arriving")
        #expect(MessagesCode.inserted(from: "123456", to: "12345") == nil, "deleting")
        #expect(MessagesCode.inserted(from: "", to: "12") == nil, "too short")
        #expect(MessagesCode.inserted(from: "", to: "12 34 56") == nil, "not letters and digits only")
    }
}

/// "Code from Messages or Mail…" in the browser window: a native field over the page's field, which ends without filling anything on
/// every reason the plan names, and hands the page a code once. macOS's own list is not involved: the system inserts a picked code
/// into the focused field through its text input, which these tests do with the field editor.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MessagesCodeBridgeTests {
    private final class FlippedView: NSView {
        override var isFlipped: Bool {
            true
        }
    }

    private final class Rig {
        let page: BrowserPage
        let window: NSWindow
        let content: NSView
        var isCurrent = true
        var answer = true
        var delivered: [String] = []
        var valueAtDelivery: String?
        var endings: [MessagesCodeBridge.Ending] = []
        private(set) var bridge: MessagesCodeBridge?

        init(flipped: Bool = false) {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration),
                context: BrowserProfileContext(profile: .privateBrowsing())
            )
            page.url = URL(string: "https://login.example.test/verify")
            page.hasOnlySecureContent = true
            let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            content = flipped ? FlippedView(frame: frame) : NSView(frame: frame)
            page.frame = NSRect(x: 100, y: 50, width: 600, height: 400)
            content.addSubview(page)
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            window.orderBack(nil)
        }

        func open(rect: NSRect = NSRect(x: 40, y: 60, width: 300, height: 30), lifetime: Duration = MessagesCodeBridge.lifetime) throws -> MessagesCodeBridge {
            let made = MessagesCodeBridge(
                page: page, rect: rect, site: "login.example.test", isCurrent: { [unowned self] in isCurrent }, lifetime: lifetime,
                deliver: { [unowned self] code in
                    delivered.append(code)
                    valueAtDelivery = self.bridge?.field.stringValue
                    return answer
                },
                finished: { [unowned self] _, ending in endings.append(ending) }
            )
            let bridge = try #require(made)
            self.bridge = bridge
            return bridge
        }

        var editor: NSTextView? {
            bridge?.field.currentEditor() as? NSTextView
        }

        /// What macOS does when the person picks a suggestion: the code is inserted at once through the text input client.
        func insert(_ text: String) {
            editor?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        func command(_ selector: Selector) {
            editor?.doCommand(by: selector)
        }

        var pageHasFocus: Bool {
            page.ownsResponder(window.firstResponder)
        }

        func close() async {
            bridge?.end(.replaced)
            window.contentView = nil
            window.close()
            await page.close()
            await page.context.endPrivateSession()
        }
    }

    private func withRig(flipped: Bool = false, _ body: (Rig) async throws -> Void) async throws {
        let rig = Rig(flipped: flipped)
        do {
            try await body(rig)
        } catch {
            await rig.close()
            throw error
        }
        await rig.close()
    }

    // MARK: - Where it is

    @Test(arguments: [false, true])
    func theFieldSitsInsideTheWindowOverThePageField(flipped: Bool) async throws {
        try await withRig(flipped: flipped) { rig in
            let rect = NSRect(x: 40, y: 60, width: 300, height: 30)
            let bridge = try rig.open(rect: rect)
            let target = rig.page.convert(rect, to: rig.content)
            let field = rig.content.convert(bridge.field.bounds, from: bridge.field)

            #expect(abs(field.minX - target.minX) < 0.5 && abs(field.width - 300) < 0.5, "over the page field's width")
            #expect(abs(field.midY - target.midY) < 0.5, "on the page field's line")
            #expect(bridge.box.superview === rig.content && bridge.box.window === rig.window, "a view of the window itself, no popover")
            #expect(rig.content.subviews.last === bridge.box, "above the page")
            #expect(rig.content.bounds.contains(bridge.box.frame))
            #expect(bridge.box.frame.contains(field))
            #expect(rig.window.firstResponder === bridge.field.currentEditor(), "focused")
            #expect(bridge.field.contentType == .oneTimeCode)
            #expect(bridge.field.accessibilityLabel()?.contains("login.example.test") == true, "named for the site")
            #expect((bridge.field.currentEditor() as? NSTextView)?.allowsUndo == false, "nothing to undo")
        }
    }

    @Test func aNarrowPageFieldGetsAUsableWidthAndAFieldNearTheEdgeStaysInside() async throws {
        try await withRig { rig in
            let narrow = NSRect(x: 40, y: 60, width: 100, height: 30)
            let bridge = try rig.open(rect: narrow)
            let target = rig.page.convert(narrow, to: rig.content)
            let field = rig.content.convert(bridge.field.bounds, from: bridge.field)
            #expect(field.width >= MessagesCodeBridge.minimumFieldWidth && abs(field.minX - target.minX) < 0.5)
            bridge.end(.replaced)

            let edge = try rig.open(rect: NSRect(x: 560, y: 380, width: 40, height: 20))
            #expect(rig.content.bounds.contains(edge.box.frame), "never outside the window")
        }
    }

    // MARK: - A code

    @Test func aWholeCodeIsDeliveredOnceTheFieldIsEmptyAndThePageHasItsFocusBack() async throws {
        try await withRig { rig in
            let changes = NSPasteboard.general.changeCount
            let bridge = try rig.open()

            rig.insert("482913")

            #expect(bridge.field.stringValue.isEmpty, "emptied before the code goes anywhere")
            #expect(await waitUntil { !bridge.isOpen })
            #expect(rig.delivered == ["482913"] && rig.endings == [.filled])
            #expect(rig.valueAtDelivery == "", "the owner never saw it in the field")
            #expect(bridge.field.stringValue.isEmpty && bridge.box.superview == nil)
            #expect(rig.pageHasFocus)
            #expect(NSPasteboard.general.changeCount == changes, "nothing was put on the pasteboard")
        }
    }

    @Test func aCodeTypedACharacterAtATimeWaitsForReturn() async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            for character in "4829" {
                rig.insert(String(character))
            }
            #expect(rig.delivered.isEmpty && bridge.isOpen && bridge.field.stringValue == "4829")

            rig.command(#selector(NSResponder.insertNewline(_:)))

            #expect(await waitUntil { !bridge.isOpen })
            #expect(rig.delivered == ["4829"] && rig.endings == [.filled])
            #expect(bridge.field.stringValue.isEmpty)
        }
    }

    @Test func aRefusedDeliveryStillClosesAndAGivenBackFocusFollows() async throws {
        try await withRig { rig in
            rig.answer = false
            let bridge = try rig.open()
            rig.insert("482913")
            #expect(await waitUntil { !bridge.isOpen })
            #expect(rig.endings == [.refused] && rig.pageHasFocus && bridge.field.stringValue.isEmpty)
        }
    }

    // MARK: - Nothing is filled

    @Test func escapeEndsItWithoutFillingAnythingAndEmptiesTheField() async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            rig.insert("48")

            rig.command(#selector(NSResponder.cancelOperation(_:)))

            #expect(!bridge.isOpen && rig.endings == [.cancelled] && rig.delivered.isEmpty)
            #expect(bridge.field.stringValue.isEmpty && bridge.box.superview == nil)
            #expect(rig.pageHasFocus)
        }
    }

    @Test func losingFocusEndsItAndKeepsWhatWasTypedNowhere() async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            rig.insert("48")

            #expect(rig.window.makeFirstResponder(nil))

            #expect(!bridge.isOpen && rig.endings == [.lostFocus] && rig.delivered.isEmpty)
            #expect(bridge.field.stringValue.isEmpty && bridge.box.superview == nil)
            #expect(!rig.pageHasFocus, "the person moved the focus elsewhere; it is not taken back")
        }
    }

    @Test func aClickElsewhereInTheWindowEndsIt() async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            rig.insert("48")

            // Away from the field and from the page's: the content view's corner. A click on the field itself is the field's.
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 3, y: 3), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )))

            #expect(!bridge.isOpen && rig.endings == [.lostFocus] && rig.delivered.isEmpty)
            #expect(bridge.field.stringValue.isEmpty)
        }
    }

    @Test(arguments: ["a new address", "a load", "a hidden page", "another tab's page parked", "the page left the window", "the owner's say"])
    func thePageNoLongerBeingTheOneAskedEndsItWithNothingFilled(change: String) async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            rig.insert("48")
            switch change {
            case "a new address":
                rig.page.url = URL(string: "https://login.example.test/other")
            case "a load":
                rig.page.isLoading = true
            case "a hidden page":
                rig.page.isHidden = true
            case "another tab's page parked":
                let shelf = WebViewParkingShelf(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                rig.content.addSubview(shelf)
                shelf.addSubview(rig.page)
            case "the page left the window":
                rig.page.removeFromSuperview()
            default:
                rig.isCurrent = false
            }

            #expect(await waitUntil { !bridge.isOpen }, "\(change)")
            #expect(rig.endings == [.pageChanged] && rig.delivered.isEmpty)
            #expect(bridge.field.stringValue.isEmpty && bridge.box.superview == nil)
            #expect(!rig.pageHasFocus, "a page that is no longer the one in front is not given the focus")
        }
    }

    @Test func switchingTabsEndsItThroughTheDropdownsReset() async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            AutofillSuggestions.shared.messagesCode = bridge

            AutofillSuggestions.shared.reset()

            #expect(!bridge.isOpen && rig.endings == [.replaced] && rig.delivered.isEmpty)
            AutofillSuggestions.shared.messagesCode = nil
        }
    }

    @Test(arguments: [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification])
    func theWindowLosingKeyClosingMovingOrResizingEndsIt(name: Notification.Name) async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            rig.insert("48")

            NotificationCenter.default.post(name: name, object: rig.window)

            #expect(!bridge.isOpen && rig.endings == [.windowChanged] && rig.delivered.isEmpty)
            #expect(bridge.field.stringValue.isEmpty && bridge.box.superview == nil)
        }
    }

    @Test func aCodeThatArrivesAfterThePageStoppedBeingCurrentIsNotDelivered() async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            rig.isCurrent = false

            rig.insert("482913")

            #expect(!bridge.isOpen && rig.endings == [.pageChanged] && rig.delivered.isEmpty)
            #expect(bridge.field.stringValue.isEmpty)
        }
    }

    @Test func itEndsOnItsOwnAfterItsLifetimeAndGivesTheFocusBack() async throws {
        try await withRig { rig in
            let bridge = try rig.open(lifetime: .milliseconds(400))
            #expect(await waitUntil { !bridge.isOpen })
            #expect(rig.endings == [.timedOut] && rig.delivered.isEmpty && rig.pageHasFocus)
        }
    }

    @Test func endingTwiceReportsOnce() async throws {
        try await withRig { rig in
            let bridge = try rig.open()
            bridge.end(.cancelled)
            bridge.end(.pageChanged)
            #expect(rig.endings == [.cancelled])
        }
    }
}
