// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// "Code from Messages or Mail…" against real pages in both engines: the page script's own checks decide whether a picked code
/// fills, while the native field holds the focus (the page has blurred), and in which frame and field. The real `select` of the
/// page's script gives each request its token; `AutofillSuggestions.deliverCode` is the transport the dropdown uses; the bridge is
/// the real one over the page. The code is synthetic, inserted into the native field as the system inserts a picked suggestion.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MessagesCodeFillTests {
    private typealias Selection = (body: [String: Any], frame: BrowserFrame)

    private final class Harness {
        let page: BrowserPage
        let window: NSWindow
        let content: NSView
        let server: HTTPFixtureServer
        private(set) var posts: [(body: [String: Any], frame: BrowserFrame)] = []
        var endings: [MessagesCodeBridge.Ending] = []
        private(set) var bridge: MessagesCodeBridge?

        init(page: BrowserPage, window: NSWindow, content: NSView, server: HTTPFixtureServer) {
            self.page = page
            self.window = window
            self.content = content
            self.server = server
        }

        func receive(_ message: BrowserScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            posts.append((body, message.frameInfo))
        }

        /// A frame whose script said it is ready, and the script's own id of its document: WebKit's frames carry none of their own.
        struct Ready {
            let frame: BrowserFrame
            let id: String
        }

        /// The latest frame whose script is ready: the page's, or the iframe's own document (not the empty one it starts with).
        private func ready(main: Bool) -> Ready? {
            posts.last {
                $0.body["action"] as? String == "ready" && $0.frame.isMainFrame == main && (main || $0.frame.request.url?.path == "/frame")
            }.map { Ready(frame: $0.frame, id: $0.body["documentID"] as? String ?? "") }
        }

        var main: Ready? {
            ready(main: true)
        }

        var subframe: Ready? {
            ready(main: false)
        }

        func selections(in document: Ready) -> [[String: Any]] {
            posts.filter { $0.body["action"] as? String == "select" && $0.body["documentID"] as? String == document.id }.map(\.body)
        }

        @discardableResult
        func run(_ body: String, _ arguments: [String: Any] = [:], in frame: BrowserFrame?) async throws -> Any {
            try await page.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: PasswordAutofill.world)
        }

        func value(_ id: String, in document: Ready?) async throws -> String? {
            try await run("return document.getElementById(id)?.value ?? null;", ["id": id], in: document?.frame) as? String
        }

        /// Focuses field `id` in `frame` and returns the `select` its script then posts: the token of the request.
        func select(_ id: String, in document: Ready) async throws -> Selection {
            let count = selections(in: document).count
            try await run("document.getElementById(id).focus(); globalThis.__wsurfPasswords.refresh();", ["id": id], in: document.frame)
            try #require(await waitUntil { self.selections(in: document).count > count }, "\(id) is selected")
            return (try #require(selections(in: document).last), document.frame)
        }

        func destination(_ selection: Selection, in other: Ready? = nil) -> AutofillSuggestions.CodeDestination {
            AutofillSuggestions.CodeDestination(
                frame: other?.frame ?? selection.frame, world: PasswordAutofill.world, bridge: "__wsurfPasswords",
                token: selection.body["token"] as? String ?? "", url: selection.body["url"] as? String ?? "",
                documentID: selection.body["documentID"] as? String ?? ""
            )
        }

        /// Whether the page took the code. A frame that is gone throws; for the dropdown that is a refusal too.
        func deliver(_ code: String, to destination: AutofillSuggestions.CodeDestination) async -> Bool {
            (try? await AutofillSuggestions.deliverCode(code, to: destination, in: page) {}) ?? false
        }

        /// Whether the page still answers the request check `AutofillSuggestions.validate` makes: the field's geometry, while the
        /// request's token is the page's.
        func validates(_ selection: Selection) async throws -> Bool {
            try await run("""
                const model = globalThis.__wsurfAutofillForms;
                const active = globalThis.__wsurfAutofillSuggestions?.active();
                if (model?.documentID !== documentID || !active || model.id(active) !== fieldID || model.group(active)?.id !== formID) return null;
                return globalThis.__wsurfPasswords?.bounds(token, url) ?? null;
                """, [
                "documentID": selection.body["documentID"] as? String ?? "", "fieldID": selection.body["fieldID"] as? String ?? "",
                "formID": selection.body["formID"] as? String ?? "", "token": selection.body["token"] as? String ?? "",
                "url": selection.body["url"] as? String ?? "",
            ], in: selection.frame) is [String: Any]
        }

        /// The real bridge over the page, delivering through `deliverCode` to `destination`.
        func openBridge(for destination: AutofillSuggestions.CodeDestination) throws -> MessagesCodeBridge {
            let made = MessagesCodeBridge(
                page: page, rect: NSRect(x: 40, y: 40, width: 260, height: 30), site: "login.example.test", isCurrent: { true },
                deliver: { [page] code in (try? await AutofillSuggestions.deliverCode(code, to: destination, in: page) {}) ?? false },
                finished: { [weak self] _, ending in self?.endings.append(ending) }
            )
            let bridge = try #require(made)
            self.bridge = bridge
            return bridge
        }

        /// What macOS does when the person picks a suggestion: the code goes in through the text input client.
        func pick(_ code: String) {
            (bridge?.field.currentEditor() as? NSTextView)?.insertText(code, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private static let cancel = "<script>document.addEventListener('contextmenu', event => event.preventDefault());</script>"

    private static func page(crossOriginFrame: Bool) -> String {
        let host = crossOriginFrame ? "'localhost:' + location.port" : "location.host"
        return """
            <form id="f" onsubmit="return false"><input id="otp" name="otp" autocomplete="one-time-code" inputmode="numeric" maxlength="6">
            <button type="button">Verify</button></form>
            <input id="note" name="note">
            <script>
            const frame = document.createElement('iframe');
            frame.src = location.protocol + '//' + \(host) + '/frame';
            frame.width = 400; frame.height = 120;
            document.body.append(frame);
            </script>
            """
    }

    private static let frame = #"<form onsubmit="return false"><input id="fotp" autocomplete="one-time-code" inputmode="numeric" maxlength="6"></form>"#
    private static let next = #"<form onsubmit="return false"><input id="otp" autocomplete="one-time-code" inputmode="numeric" maxlength="6"></form>"#

    private func withHarness(_ engine: BrowserEngine, crossOriginFrame: Bool = false, _ body: (Harness) async throws -> Void) async throws {
        func html(_ inner: String) -> HTTPFixtureServer.Response {
            .html("<!doctype html><html><body>\(Self.cancel)\(inner)</body></html>")
        }
        let server = try await HTTPFixtureServer.start(routes: [
            "/": html(Self.page(crossOriginFrame: crossOriginFrame)), "/frame": html(Self.frame), "/next": html(Self.next),
        ])
        let url = try server.url()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), configuration: configuration), context: context
            )
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            page = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let frame = NSRect(x: 0, y: 0, width: 760, height: 660)
        let content = NSView(frame: frame)
        page.frame = NSRect(x: 30, y: 30, width: 700, height: 600)
        content.addSubview(page)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        // On screen: WebKit throttles the timers of a cross-origin frame in a page nobody can see, and the script's own selection waits on one.
        window.orderFront(nil)
        let harness = Harness(page: page, window: window, content: content, server: server)
        page.installScript(PasswordAutofillScript.source, in: PasswordAutofill.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: "wsurfPasswords", in: PasswordAutofill.world) { harness.receive($0) }
        func finish() async {
            harness.bridge?.end(.replaced)
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
            withExtendedLifetime(server) {}
        }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try #require(await waitUntil { harness.main != nil }, "the page's script is ready")
            try #require(await waitUntil { harness.subframe != nil }, "the iframe's script is ready")
            // What the policy sends a profile with password autofill on; the private test profile would get false.
            for document in [harness.main, harness.subframe].compactMap({ $0 }) {
                try await harness.run("globalThis.__wsurfPasswords.setEnabled(true);", in: document.frame)
            }
            try await body(harness)
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aPickedCodeFillsTheFieldThatAskedWhileTheNativeFieldHoldsTheFocus(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let main = try #require(harness.main)
            #expect(harness.window.makeFirstResponder(harness.page))
            let selection = try await harness.select("otp", in: main)
            #expect(selection.body["field"] as? String == "totp")
            let bridge = try harness.openBridge(for: harness.destination(selection))
            #expect(!harness.page.ownsResponder(harness.window.firstResponder), "the page does not hold the focus")
            #expect(try await harness.validates(selection), "its token still holds while the page is blurred, on \(engine)")

            harness.pick("482913")

            #expect(await waitUntil { !bridge.isOpen })
            #expect(harness.endings == [.filled])
            #expect(try await harness.value("otp", in: main) == "482913")
            #expect(try await harness.value("note", in: main) == "")
            #expect(try await harness.value("fotp", in: harness.subframe) == "", "the frame did not ask")
            #expect(bridge.field.stringValue.isEmpty)
            #expect(await harness.deliver("000000", to: harness.destination(selection)) == false, "a request fills once")
            #expect(try await harness.value("otp", in: main) == "482913")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aNavigationEndsItAndTheOldRequestFillsNothingInTheNewDocument(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let main = try #require(harness.main)
            let selection = try await harness.select("otp", in: main)
            let old = harness.destination(selection)
            let bridge = try harness.openBridge(for: old)
            harness.pick("48")

            let next = try harness.server.url("/next")
            harness.page.load(URLRequest(url: next))

            #expect(await waitUntil { !bridge.isOpen }, "the navigation ended it on \(engine)")
            #expect(harness.endings == [.pageChanged])
            try #require(await waitUntil { harness.page.url == next && !harness.page.isLoading })
            try #require(await waitUntil { harness.main.map { $0.id != main.id } == true })
            let loaded = try #require(harness.main)
            try await harness.run("globalThis.__wsurfPasswords.setEnabled(true);", in: loaded.frame)
            #expect(await harness.deliver("482913", to: old) == false, "the old document's request fills nothing")
            #expect(try await harness.value("otp", in: loaded) == "")
            // The same transport does fill a request of the new document, so the refusal above is the request's, not the harness's.
            let fresh = try await harness.select("otp", in: loaded)
            #expect(await harness.deliver("482913", to: harness.destination(fresh)) == true)
            #expect(try await harness.value("otp", in: loaded) == "482913")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases, [false, true])
    func anotherFrameOrSiteNeverTakesTheCodeAndTheFrameThatAskedDoes(engine: BrowserEngine, crossOriginFrame: Bool) async throws {
        try await withHarness(engine, crossOriginFrame: crossOriginFrame) { harness in
            let main = try #require(harness.main), sub = try #require(harness.subframe)
            #expect(sub.id != main.id && !sub.frame.isMainFrame && main.frame.isMainFrame)

            // The page's field asked: the frame it did not ask in takes nothing, then the page's own field takes it.
            let top = try await harness.select("otp", in: main)
            #expect(await harness.deliver("111111", to: harness.destination(top, in: sub)) == false, "\(engine), cross-origin \(crossOriginFrame)")
            #expect(try await harness.value("fotp", in: sub) == "")
            #expect(try await harness.value("otp", in: main) == "")
            #expect(await harness.deliver("111111", to: harness.destination(top)) == true)

            // A cross-origin frame of WebKit runs in another process, and an element there takes the focus only in a focused window,
            // which a test cannot give it; Chromium's, and a same-origin frame of either engine, do. The frame's routing is the same.
            guard engine == .chromium || !crossOriginFrame else { return }

            // The frame's field asked: the page's frame takes nothing, then the frame's own field takes it.
            let inner = try await harness.select("fotp", in: sub)
            #expect(await harness.deliver("222222", to: harness.destination(inner, in: main)) == false)
            #expect(try await harness.value("fotp", in: sub) == "")
            #expect(await harness.deliver("222222", to: harness.destination(inner)) == true)
            #expect(try await harness.value("fotp", in: sub) == "222222")
            #expect(try await harness.value("otp", in: main) == "111111", "the page's own field kept what its own request filled")
            #expect(try await harness.value("note", in: main) == "")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aFieldThatChangedIntoAFormSendingItElsewhereTakesNoCode(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let main = try #require(harness.main)
            let selection = try await harness.select("otp", in: main)
            try await harness.run("document.getElementById('f').action = 'https://elsewhere.example/collect';", in: main.frame)

            #expect(await harness.deliver("482913", to: harness.destination(selection)) == false, "\(engine)")
            #expect(try await harness.value("otp", in: main) == "")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aFieldThatWentAwayOrGotAnotherFocusTakesNoCode(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let main = try #require(harness.main)
            let selection = try await harness.select("otp", in: main)
            // The page moved its focus to another field: the request's field is no longer the focused one.
            try await harness.run("document.getElementById('note').focus();", in: main.frame)
            #expect(await harness.deliver("482913", to: harness.destination(selection)) == false, "\(engine)")
            #expect(try await harness.value("otp", in: main) == "")
            #expect(try await harness.value("note", in: main) == "")

            let again = try await harness.select("otp", in: main)
            try await harness.run("document.getElementById('otp').remove();", in: main.frame)
            #expect(await harness.deliver("482913", to: harness.destination(again)) == false, "a field that left the page takes nothing")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func theNativeAuthorityIsAskedAtTheDispatchBoundaryAndARefusalFillsNothing(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let main = try #require(harness.main)
            let selection = try await harness.select("otp", in: main)
            let asked = Counter()

            await #expect(throws: ContactAutofillError.self) {
                _ = try await AutofillSuggestions.deliverCode("482913", to: harness.destination(selection), in: harness.page) {
                    asked.count += 1
                    throw ContactAutofillError.changedPage
                }
            }
            #expect(asked.count == 1)
            #expect(try await harness.value("otp", in: main) == "", "a refused request put nothing on the page, on \(engine)")

            let allowed = try await AutofillSuggestions.deliverCode("482913", to: harness.destination(selection), in: harness.page) { asked.count += 1 }
            #expect(allowed == true)
            #expect(asked.count == 2)
            #expect(try await harness.value("otp", in: main) == "482913")
        }
    }

    @MainActor
    private final class Counter {
        var count = 0
    }
}

/// A code the person picked leaves no trace in the page's own Input History: the fill is the page's untrusted event, which the
/// capture never records, and the native field is not part of the page at all.
@MainActor
struct MessagesCodeInputHistoryTests {
    private final class Posts {
        var all: [(body: [String: Any], frame: BrowserFrame)] = []
    }

    @Test(.boundedWebViews) func aFilledCodeIsNeverWrittenToInputHistory() async throws {
        let rig = InputHistoryCaptureRig(recording: true, formModel: true)
        let posts = Posts()
        rig.page.installScript(
            AutofillSuggestionScript.source + PasswordAutofillScript.clientSource, in: PasswordAutofill.world,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        rig.page.addScriptMessageHandler(name: "wsurfPasswords", in: PasswordAutofill.world) { message in
            guard let body = message.body as? [String: Any] else { return }
            posts.all.append((body, message.frameInfo))
        }
        // A page that is not in a window is throttled: the script's own timer would never post the selection.
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = rig.page
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        do {
            rig.page.loadHTMLString(
                "<!doctype html><title>Verify</title><form onsubmit='return false'><input id='otp' autocomplete='one-time-code' inputmode='numeric' maxlength='6'></form>"
                    + "<input id='note' name='note'>",
                baseURL: URL(string: "https://login.example/")
            )
            #expect(await PageSettle.untilIdle(rig.page, timeout: .seconds(20)))
            #expect(await waitUntil { rig.capture.documentCount(in: rig.page) >= 1 })
            try #require(await waitUntil { posts.all.contains { $0.body["action"] as? String == "ready" } })
            let main = try #require(posts.all.last { $0.body["action"] as? String == "ready" }?.frame)
            func run(_ body: String) async throws -> Any {
                try await rig.page.callAsyncJavaScript(body, arguments: [:], in: main, contentWorld: PasswordAutofill.world)
            }
            _ = try await run("globalThis.__wsurfPasswords.setEnabled(true);")
            try #require(await waitUntil {
                try await rig.page.callAsyncJavaScript(
                    "return globalThis.__wsurfInputHistory?.__test.enabled();", arguments: [:], in: nil, contentWorld: AutofillPage.world
                ) as? Bool == true
            })

            _ = try await run("document.getElementById('otp').focus(); globalThis.__wsurfPasswords.refresh();")
            try #require(await waitUntil { posts.all.contains { $0.body["action"] as? String == "select" } })
            let selection = try #require(posts.all.last { $0.body["action"] as? String == "select" }?.body)
            let destination = AutofillSuggestions.CodeDestination(
                frame: main, world: PasswordAutofill.world, bridge: "__wsurfPasswords", token: selection["token"] as? String ?? "",
                url: selection["url"] as? String ?? "", documentID: selection["documentID"] as? String ?? ""
            )
            #expect(try await AutofillSuggestions.deliverCode("482913", to: destination, in: rig.page) {} == true)
            #expect(try await run("return document.getElementById('otp').value;") as? String == "482913")

            // The person's own typing in another field is recorded, so the capture is working; the code is not.
            let hook = "const field = id => document.getElementById(id); return globalThis.__wsurfInputHistory.__test."
            _ = try await rig.page.callAsyncJavaScript(
                hook + "edit(field('note'), 'dummy-note-1')", arguments: [:], in: nil, contentWorld: AutofillPage.world
            )
            for call in ["blur(field('otp'))", "blur(field('note'))", "leave()"] {
                _ = try await rig.page.callAsyncJavaScript(hook + call, arguments: [:], in: nil, contentWorld: AutofillPage.world)
            }
            #expect(try await waitUntil { try await rig.entries().count == 1 })
            let entries = try await rig.entries()
            #expect(entries.map(\.payload.value) == ["dummy-note-1"], "the code is not among what Input History kept")
        } catch {
            await rig.tearDown()
            throw error
        }
        await rig.tearDown()
    }
}
