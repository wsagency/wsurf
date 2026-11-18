// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Where Pick Credential… appears in the REAL context menu of both engines, and where it must not. A loopback page with a text
/// field, a password field, a read-only field, a disabled field, a field under an overlay, a field under an overlay that lets the
/// pointer through and a login form whose prefilled username is read-only is right-clicked with AppKit events made in process
/// (`window.sendEvent`; WebKit) or DevTools input (Chromium): nothing is posted to the system. The menu is the one the engine
/// built, as `TabWebView.willOpenMenu` (WebKit) or `on_before_context_menu` (Chromium) left it, read while it tracks
/// (`ContextMenuReader`).
///
/// The fixture is plain HTTP, which the tab's own policy refuses (`CredentialPicker.isOffered` needs HTTPS: neither engine can load
/// an HTTPS fixture here), so the tests that look at WHERE the item goes put the tab's answer in by hand (`Rig.offer`). The one that
/// looks at the tab's own answer leaves the wiring as `BrowserTab` made it. `CredentialPickerTests` covers the policy itself and
/// Edit ▸ Pick Credential…; `ChromiumContextMenuTests` the Chromium decision on a hand-built menu model.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PickCredentialRealMenuTests {
    // MARK: - Fixture

    /// The fields of the fixture, by the element a right-click on them lands on. `user` and `pw2` are one form: a prefilled
    /// username the page made read-only, and the password field beside it, which takes input.
    nonisolated enum Field: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case text, pw, through, ro, cover, plain, dis, user, pw2

        var testDescription: String {
            rawValue
        }

        /// The fields whose menu the engine always opens: a disabled one is the engine's call (`aDisabledFieldGetsNoItem`).
        static let withMenu = allCases.filter { $0 != .dis }

        /// Whether the item is offered there, in both engines. A field the page marked `readonly` or disabled takes no input, and
        /// Chromium's `is_editable` says so; WebKit's menu for a read-only field has Cut, Copy and Paste like a writable one's, so
        /// there the page's own hit test tells it (`TabWebView.contextFieldResolved`). The password field beside a read-only
        /// username takes input and gets the item.
        var offersPick: Bool {
            switch self {
            case .text, .pw, .through, .pw2:
                true
            case .ro, .cover, .plain, .dis, .user:
                false
            }
        }

        /// WebKit's own sign that the right-click landed in something editable (its Paste item): present for every input that
        /// opens a menu (read-only ones too), absent elsewhere. Not asked for `dis`, whose menu is the engine's call.
        var webKitHasPaste: Bool {
            switch self {
            case .text, .pw, .through, .ro, .pw2, .user:
                true
            case .cover, .plain, .dis:
                false
            }
        }

        /// The middle of the element in the viewport, in points (see `page`).
        var point: CGPoint {
            let top: [Field: Double] = [.text: 10, .pw: 50, .ro: 90, .cover: 130, .through: 170, .plain: 210, .dis: 250, .user: 290, .pw2: 330]
            return CGPoint(x: 140, y: (top[self] ?? 0) + 15)
        }
    }

    /// `cover` is an overlay over the input `covered` (a label, mask or icon that takes the pointer); `screen` is one over `through`
    /// that does not (`pointer-events: none`). Every `contextmenu` event is noted in `__ctx`, with whether the page cancelled it
    /// by the time it reached the window.
    private static func page(cancelling: Bool) -> String {
        """
        <!doctype html><title>Fields</title>
        <style>
          body { margin: 0 }
          input, div, p { position: absolute; left: 20px; width: 240px; height: 30px; box-sizing: border-box; margin: 0 }
        </style>
        <input id="text" style="top: 10px">
        <input id="pw" type="password" style="top: 50px">
        <input id="ro" readonly value="read only" style="top: 90px">
        <input id="covered" style="top: 130px"><div id="cover" style="top: 130px"></div>
        <input id="through" style="top: 170px"><div id="screen" style="top: 170px; pointer-events: none"></div>
        <p id="plain" style="top: 210px">Plain text</p>
        <input id="dis" disabled value="disabled" style="top: 250px">
        <form><input id="user" readonly value="ada@example.test" style="top: 290px"><input id="pw2" type="password" style="top: 330px"></form>
        <script>
          window.__ctx = [];
          addEventListener('contextmenu', event => { window.__ctx.push({ id: event.target.id, prevented: false }); }, true);
          \(cancelling ? "document.addEventListener('contextmenu', event => event.preventDefault());" : "")
          addEventListener('contextmenu', event => { window.__ctx[window.__ctx.length - 1].prevented = event.defaultPrevented; });
        </script>
        """
    }

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/fields": .html(page(cancelling: false)),
        "/cancel": .html(page(cancelling: true)),
    ]

    nonisolated static let pick = String(localized: "Pick Credential…")
    /// No reason, then each reason the tab can give for a withheld item.
    nonisolated static let refusals: [CredentialPicker.Refusal?] = {
        var all: [CredentialPicker.Refusal?] = [nil]
        for reason in CredentialPicker.Refusal.allCases {
            all.append(reason)
        }
        return all
    }()

    /// What the open menu held when it was read.
    @MainActor
    struct Shown {
        var appeared = false
        var titles: [String] = []
        var identifiers: [String] = []
        var chosen = false

        /// Pick Credential… is the first item, then a rule.
        var offersPick: Bool {
            titles.first == PickCredentialRealMenuTests.pick && titles.dropFirst().first == "—"
        }

        /// WebKit's own signal that the right-click landed in something editable (`TabContextMenu.isEditable`).
        var hasPaste: Bool {
            identifiers.contains(TabContextMenu.pasteItem)
        }
    }

    @MainActor
    final class Rig {
        let engine: BrowserEngine
        let server: HTTPFixtureServer
        let browser: BrowserModel
        let tab: BrowserTab
        let window: NSWindow
        private var menuObserver: NSObjectProtocol?
        private var shown = Shown()
        private var menuDone = false
        private var watchdogFired = false
        private var movedSeen = false
        /// How many times the engine's menu ran Pick Credential…'s action.
        private(set) var picked = 0

        init(engine: BrowserEngine, server: HTTPFixtureServer, browser: BrowserModel, tab: BrowserTab, window: NSWindow) {
            self.engine = engine
            self.server = server
            self.browser = browser
            self.tab = tab
            self.window = window
        }

        var page: BrowserPage {
            tab.page
        }

        func close() {
            if let menuObserver {
                NotificationCenter.default.removeObserver(menuObserver)
            }
            window.contentView = nil
            window.close()
        }

        /// Puts the tab's answer for Pick Credential… into the engine's menu by hand: whether it is offered, and, if not, the reason.
        func offer(_ offered: Bool, refusal: CredentialPicker.Refusal? = nil) throws {
            let choose: (CredentialPicker.Menu) -> Void = { [weak self] _ in self?.picked += 1 }
            if let chromium = page.chromium {
                chromium.canPickCredential = { offered }
                chromium.credentialRefusal = { refusal }
                chromium.onPickCredential = choose
            } else {
                let view = try #require(page.webKit as? TabWebView, "the tab's WebKit view is a TabWebView")
                view.canPickCredential = { offered }
                view.credentialRefusal = { refusal }
                view.onPickCredential = choose
            }
        }

        /// What the page was told: one entry per `contextmenu` event it saw.
        func events() async throws -> [(id: String, prevented: Bool)] {
            let json = try await page.evaluateJavaScript("JSON.stringify(window.__ctx ?? [])") as? String ?? "[]"
            let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
            return list.map { ($0["id"] as? String ?? "?", $0["prevented"] as? Bool ?? false) }
        }

        /// Chromium takes no input into a page it has not drawn yet and drops the first click without telling anyone, so it is
        /// moved over the page until the page says a mouse event reached it. WebKit takes its events through the window.
        private func awaitInput(at point: CGPoint) async throws {
            guard !movedSeen, let chromium = page.chromium else { return }
            _ = try await page.evaluateJavaScript("window.__moved = false; addEventListener('mousemove', () => { window.__moved = true }, true); 0")
            try #require(await waitUntil {
                _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                    "type": "mouseMoved", "x": Double(point.x), "y": Double(point.y), "buttons": 0,
                ])
                return try await self.page.evaluateJavaScript("window.__moved") as? Bool == true
            }, "the Chromium page took mouse input")
            movedSeen = true
        }

        /// Right-clicks `field` and reads the menu that opens, choosing the first item `choose` accepts. With `expectingMenu` false
        /// (the page cancels the event) it waits until the page has seen the event, then a while longer, and returns what appeared.
        func rightClick(
            _ field: Field, expectingMenu: Bool = true, controlClick: Bool = false,
            choosing choose: @escaping @MainActor (String) -> Bool = { _ in false }
        ) async throws -> Shown {
            let point = field.point
            let hit = try await page.evaluateJavaScript("document.elementFromPoint(\(point.x), \(point.y))?.id ?? ''") as? String
            try #require(hit == field.rawValue, "\(field.rawValue) is where the fixture put it; the element there is \(hit ?? "none")")
            try await awaitInput(at: point)
            let before = try await events().count
            shown = Shown()
            menuDone = false
            watchdogFired = false
            if let menuObserver {
                NotificationCenter.default.removeObserver(menuObserver)
            }
            menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                // Posted on the main thread, while the menu tracks; the test touches the menu only there.
                nonisolated(unsafe) let tracked = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let self, let menu = tracked, !self.shown.appeared else { return }
                    self.shown.appeared = true
                    ContextMenuReader.start(menu, after: 0.15, choosing: choose) { titles, identifiers, chose in
                        self.shown.titles = titles
                        self.shown.identifiers = identifiers
                        self.shown.chosen = chose
                    } finished: { watchdogFired in
                        self.watchdogFired = watchdogFired
                        self.menuDone = true
                    }
                }
            }
            try await PageRightClick.send(at: point, in: page, window: window, left: controlClick, control: controlClick)
            if expectingMenu {
                _ = await waitUntil(timeout: .seconds(10)) { self.menuDone }
            } else {
                try #require(await waitUntil { try await self.events().count > before }, "the page saw the right-click on \(field.rawValue)")
                try await Task.sleep(for: .milliseconds(1500))
                if shown.appeared {
                    _ = await waitUntil(timeout: .seconds(10)) { self.menuDone }
                }
            }
            #expect(!watchdogFired, "the menu was cancelled by the watchdog, not read")
            try await Task.sleep(for: .milliseconds(100))
            return shown
        }
    }

    private func withRig(_ engine: BrowserEngine, path: String = "/fields", body: (Rig) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let url = try server.url(path)
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("PickCredentialRealMenu-\(UUID().uuidString).json"))
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
            permissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let tab = browser.newTab(url: url)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        let rig = Rig(engine: engine, server: server, browser: browser, tab: tab, window: window)
        defer { rig.close() }
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading && tab.page.mainDocumentID != nil })
        #expect((tab.page.chromium != nil) == (engine == .chromium), "the tab runs on \(engine)")
        try #require(await waitUntil { try await tab.page.evaluateJavaScript("window.__ctx !== undefined") as? Bool == true }, "the fixture ran")
        try await Task.sleep(for: .milliseconds(300))
        try await body(rig)
        withExtendedLifetime(server) {}
    }

    // MARK: - Where it goes

    /// The item is on top of the menu of an editable field, password field included, and nowhere else, in both engines. A field
    /// under an overlay is not what the pointer is over; an overlay that lets the pointer through (`pointer-events: none`) leaves
    /// the field editable; a read-only field gets nothing, though WebKit's menu for it is as editable as a writable field's (its
    /// Paste item is there: the item is withheld by the page's hit test, `Field.offersPick`); the password field beside a read-only
    /// username still gets it.
    @Test(arguments: BrowserEngine.allCases, Field.withMenu)
    func theItemIsOnTopOfAnEditableFieldsMenuAndOnNoOther(engine: BrowserEngine, field: Field) async throws {
        try await withRig(engine) { rig in
            try rig.offer(true)
            let menu = try await rig.rightClick(field)
            try #require(menu.appeared, "a menu opened on \(field)")
            let note: Comment = "\(engine) \(field): the menu held \(menu.titles) \(menu.identifiers)"
            #expect(menu.offersPick == field.offersPick, note)
            if engine == .webKit {
                #expect(menu.hasPaste == field.webKitHasPaste, "WebKit offers Paste where the right-click landed in an input: \(note)")
                if field.offersPick {
                    #expect(menu.identifiers.first == CredentialPicker.menuItemIdentifier.rawValue, note)
                }
            }
            #expect(rig.picked == 0, "looking at the menu runs nothing")
            #expect(try await rig.events().last?.prevented == false, "the page did not cancel this right-click")
        }
    }

    @Test(arguments: [Field.ro, .user, .dis, .pw2])
    func aControlClickOffersCredentialsOnlyOnEditableFields(field: Field) async throws {
        try await withRig(.webKit) { rig in
            try rig.offer(true)
            let menu = try await rig.rightClick(field, controlClick: true)
            if field != .dis {
                try #require(menu.appeared, "Control-click opened the menu on \(field)")
            }
            #expect(menu.offersPick == field.offersPick, "Control-click on \(field): \(menu.titles)")
            #expect(rig.picked == 0)
        }
    }

    /// A disabled field gets no item in either engine. Whether the engine opens a menu over a disabled control at all is its own
    /// decision, so a menu is not required here, only that none that opened has the item (also with the reason, which only an
    /// editable field's menu shows).
    @Test(arguments: BrowserEngine.allCases, PickCredentialRealMenuTests.refusals)
    func aDisabledFieldGetsNoItem(engine: BrowserEngine, refusal: CredentialPicker.Refusal?) async throws {
        try await withRig(engine) { rig in
            try rig.offer(refusal == nil, refusal: refusal)
            let menu = try await rig.rightClick(.dis)
            #expect(!menu.offersPick && !menu.titles.contains { $0.hasPrefix(Self.pick) }, "\(engine) disabled: the menu held \(menu.titles)")
            #expect(rig.picked == 0)
        }
    }

    /// The password field next to a read-only, prefilled username is an editable field like any other: it gets the item, and
    /// choosing it runs the picker (what the picker then fills is `CredentialPickerTests`, for the form this fixture has).
    @Test(arguments: BrowserEngine.allCases)
    func theEditablePasswordFieldBesideAReadOnlyUsernameStillGetsTheItem(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            try rig.offer(true)
            let username = try await rig.rightClick(.user)
            try #require(username.appeared)
            #expect(!username.offersPick, "the read-only username: \(username.titles)")
            let password = try await rig.rightClick(.pw2) { $0 == Self.pick }
            try #require(password.appeared && password.offersPick, "the password field beside it: \(password.titles)")
            #expect(password.chosen)
            #expect(await waitUntil { rig.picked == 1 }, "choosing it ran the picker once")
        }
    }

    /// Choosing the item of a real menu is what runs the picker, from a text field and from a password field alike.
    @Test(arguments: BrowserEngine.allCases, [Field.text, Field.pw])
    func choosingTheItemOfTheRealMenuRunsThePicker(engine: BrowserEngine, field: Field) async throws {
        try await withRig(engine) { rig in
            try rig.offer(true)
            let menu = try await rig.rightClick(field) { $0 == Self.pick }
            try #require(menu.appeared && menu.offersPick, "the menu offers it: \(menu.titles)")
            #expect(menu.chosen)
            #expect(await waitUntil { rig.picked == 1 }, "choosing it ran the picker once")
        }
    }

    /// Where the tab refuses for a reason a person can see, the item is there with the reason in its title, on an editable field
    /// only; it runs nothing.
    @Test(arguments: BrowserEngine.allCases, CredentialPicker.Refusal.allCases)
    func aWithheldItemShowsItsReasonOnAnEditableFieldOnly(engine: BrowserEngine, refusal: CredentialPicker.Refusal) async throws {
        try await withRig(engine) { rig in
            try rig.offer(false, refusal: refusal)
            let field = try await rig.rightClick(.pw)
            try #require(field.appeared)
            #expect(field.titles.first == refusal.menuTitle && field.titles.dropFirst().first == "—", "the reason: \(field.titles)")
            let plain = try await rig.rightClick(.plain)
            try #require(plain.appeared)
            #expect(!plain.titles.contains(refusal.menuTitle) && !plain.titles.contains(Self.pick), "nothing on text: \(plain.titles)")
            #expect(rig.picked == 0)
        }
    }

    /// The tab's own answer, as `BrowserTab` wired it, for the plain HTTP fixture: not offered, with no reason to show, so the
    /// menu of an editable field has no item. WebKit's Paste is there, which makes this the policy and not a missed field.
    @Test(arguments: BrowserEngine.allCases)
    func theTabsOwnPolicyOffersNothingOnAPlainHTTPPage(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            let menu = try await rig.rightClick(.text)
            try #require(menu.appeared)
            #expect(!menu.titles.contains(Self.pick) && !menu.titles.contains { $0.hasPrefix(Self.pick) }, "\(menu.titles)")
            if engine == .webKit {
                #expect(menu.hasPaste, "the field is editable; only the policy withheld the item")
            }
        }
    }

    // MARK: - A page that cancels the right-click

    /// A page that cancels `contextmenu` gets no native menu in either engine: WebKit never calls `willOpenMenu` and CEF never calls
    /// `on_before_context_menu`, so no item can be added to a menu that does not exist. WSurf has no bypass (the investigation's
    /// B3). Edit ▸ Pick Credential… is the way in there (`CredentialPickerTests`, the menu command on a page that cancels it).
    @Test(arguments: BrowserEngine.allCases, [Field.text, Field.pw])
    func aPageThatCancelsTheRightClickShowsNoNativeMenuAndSoNoItem(engine: BrowserEngine, field: Field) async throws {
        try await withRig(engine, path: "/cancel") { rig in
            try rig.offer(true)
            let menu = try await rig.rightClick(field, expectingMenu: false)
            let seen = try await rig.events()
            #expect(seen.map { $0.id } == [field.rawValue] && seen.map { $0.prevented } == [true], "the page saw the right-click and cancelled it")
            #expect(!menu.appeared, "no native menu: it held \(menu.titles)")
            #expect(rig.picked == 0)
        }
    }
}
