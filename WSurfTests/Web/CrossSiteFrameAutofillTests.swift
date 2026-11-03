// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit
import WSurfVault

@testable import WSurf

/// Autofill in another site's frame, mostly in Chromium, where such a frame runs in another process and gets the autofill scripts
/// through a DevTools session of its own (`ChromiumDevTools+CrossSiteFrames`). The fixture is one loopback server under three host
/// names, each its own site: the page on 127.0.0.1, a login frame on localhost and, inside one, a frame on app.localhost. Loopback
/// documents are secure contexts in both engines but they are http, which the native autofill policies refuse; those are covered
/// with the frames the engines report for https pages.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct CrossSiteFrameAutofillTests {
    @MainActor
    private final class Harness {
        let page: BrowserPage
        let window: NSWindow
        let port: Int
        private(set) var posts: [(name: String, body: [String: Any], frame: BrowserFrame)] = []
        private(set) var invalidated: [String] = []
        /// What the services world's handlers heard (`withPage(media: true)`).
        private(set) var servicesPosts: [(name: String, body: Any, frame: BrowserFrame)] = []

        init(page: BrowserPage, window: NSWindow, port: Int) {
            self.page = page
            self.window = window
            self.port = port
            page.addCredentialInvalidationObserver { [weak self] _, documentID in
                if let documentID {
                    self?.invalidated.append(documentID)
                }
            }
        }

        func receive(_ message: BrowserScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            posts.append((message.name, body, message.frameInfo))
        }

        func receiveFromServices(_ message: BrowserScriptMessage) {
            servicesPosts.append((message.name, message.body, message.frameInfo))
        }

        func posted(_ action: String, by name: String = "wsurfPasswords") -> [(body: [String: Any], frame: BrowserFrame)] {
            posts.filter { $0.name == name && $0.body["action"] as? String == action }.map { ($0.body, $0.frame) }
        }

        var main: BrowserFrame? {
            posted("ready").last { $0.frame.isMainFrame }?.frame
        }

        /// The frame whose document is on `host` and whose password script reported ready.
        func ready(_ host: String) async throws -> BrowserFrame {
            func isOn(_ frame: BrowserFrame) -> Bool {
                frame.securityOrigin.host == host && frame.request.url?.host() == host
            }
            try #require(await waitUntil { self.posted("ready").contains { isOn($0.frame) } }, "\(host)'s script is ready")
            return try #require(posted("ready").last { isOn($0.frame) }?.frame)
        }

        /// Runs in the autofill world of `frame` (the page's main frame when nil).
        @discardableResult
        func run(_ body: String, _ arguments: [String: Any] = [:], in frame: BrowserFrame?) async throws -> Any {
            try await page.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: PasswordAutofill.world)
        }

        func value(_ id: String, in frame: BrowserFrame?) async throws -> String? {
            try await run("return document.getElementById(id)?.value ?? null;", ["id": id], in: frame) as? String
        }

        /// The middle of element `id` in the page's viewport: `path` is the frames it is in, outermost first, each the only iframe
        /// of the document before it.
        func center(of id: String, path: [BrowserFrame]) async throws -> CGPoint {
            func numbers(_ value: Any?) -> [Double] {
                (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            }
            let inner = numbers(try await run(
                "const r = document.getElementById(id).getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2];",
                ["id": id], in: path.last
            ))
            try #require(inner.count == 2, "\(id) is on the page")
            var point = CGPoint(x: inner[0], y: inner[1])
            for document in [nil] + path.dropLast() {
                let offset = numbers(try await run(
                    "const f = document.querySelector('iframe'); const r = f.getBoundingClientRect(); return [r.x + f.clientLeft, r.y + f.clientTop];",
                    in: document
                ))
                try #require(offset.count == 2, "the iframe is on the page")
                point.x += offset[0]
                point.y += offset[1]
            }
            return point
        }

        /// A right-click on `id` (inside the frames of `path`) and what the frame that got it reported. Chromium hit-tests an
        /// out-of-process frame only once it has been drawn; until then the click lands on a frame around it, on no field. Only
        /// that is tried again.
        func rightClick(_ id: String, path: [BrowserFrame]) async throws -> (body: [String: Any], frame: BrowserFrame) {
            for attempt in 1...10 {
                let point = try await center(of: id, path: path)
                let count = posted("context").count
                try await PageRightClick.send(at: point, in: page, window: window)
                try #require(await waitUntil { self.posted("context").count > count }, "the right-click on \(id) reached its frame")
                let last = try #require(posted("context").last)
                let landedOutside = last.frame.isMainFrame || path.dropLast().contains { $0.documentID == last.frame.documentID }
                guard attempt < 10, landedOutside, last.body["token"] is NSNull || last.body["token"] == nil else { return last }
                try await Task.sleep(for: .milliseconds(200))
            }
            return try #require(posted("context").last)
        }

        func pickFill(_ context: (body: [String: Any], frame: BrowserFrame), in frame: BrowserFrame, _ fields: [String: Any]) async throws -> Int {
            let answer = try await run(
                "return globalThis.__wsurfPasswords.pickFill(token, url, fields);",
                ["token": context.body["token"] as? String ?? "", "url": context.body["url"] as? String ?? "", "fields": fields], in: frame
            )
            return (answer as? NSNumber)?.intValue ?? 0
        }

        /// The frame of the page's own origin that took over its first, empty document's window (`takeover`): the one whose password
        /// script reported ready from the frame's own document.
        func takenOver() async throws -> BrowserFrame {
            func isIt(_ frame: BrowserFrame) -> Bool { !frame.isMainFrame && frame.request.url?.path == "/frame" }
            try #require(await waitUntil { self.posted("ready").contains { isIt($0.frame) } }, "the frame's own document runs the password script")
            let frame = try #require(posted("ready").last { isIt($0.frame) }?.frame)
            // Chromium: until the scripts ran again for this document, the empty document's instances still answer.
            try #require(await waitUntil {
                try await self.run("return [...(globalThis.__wsurfStartRuns?.values() ?? [])].every(run => run.document === document);", in: frame)
                    as? Bool == true
            }, "the frame's own document has its own instances")
            return frame
        }

        /// A person typing `text` into field `id` of `frame`: the field has focus, and the engine inserts the text as typed input.
        func type(_ text: String, into id: String, in frame: BrowserFrame) async throws {
            try await run("document.getElementById(id).focus();", ["id": id], in: frame)
            if let webView = page.webKit {
                #expect(window.makeFirstResponder(webView))
            }
            try await page.insertText(text)
        }

        /// A real left click on `id`, inside the frames of `path` (see `center`).
        func click(_ id: String, path: [BrowserFrame]) async throws {
            let point = try await center(of: id, path: path)
            if let chromium = page.chromium {
                for (type, buttons) in [("mousePressed", 1), ("mouseReleased", 0)] {
                    _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                        "type": type, "x": Double(point.x), "y": Double(point.y), "button": "left", "buttons": buttons, "clickCount": 1,
                    ])
                }
                return
            }
            let location = try #require(page.webKit).convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                )))
            }
        }

        /// Waits until everything posted so far from `frame` has arrived, so that an absence can be asserted.
        func settle(_ frame: BrowserFrame?) async throws {
            let marker = UUID().uuidString
            try await run("globalThis.__wsurfSend('wsurfPasswords', {action: 'ping', marker});", ["marker": marker], in: frame)
            #expect(await waitUntil { self.posts.contains { $0.body["marker"] as? String == marker } })
        }
    }

    private static let cancel = "<script>document.addEventListener('contextmenu', event => event.preventDefault());</script>"

    /// An iframe of the same server under `host`, another site, at `path`.
    private static func iframe(_ host: String, _ path: String, sandbox: String? = nil) -> String {
        let attribute = sandbox.map { "frame.setAttribute('sandbox', '\($0)');" } ?? ""
        return """
            <script>
            const frame = document.createElement('iframe');
            \(attribute)
            frame.src = 'http://\(host):' + location.port + '\(path)';
            frame.width = 440; frame.height = 240;
            document.body.append(frame);
            </script>
            """
    }

    /// A frame of the page's own origin that the page reads at once after inserting it, as Apple's sign-in does with its widget
    /// (`authService.js` keeps `window.frames[name]`). Chromium then sets up the frame's first, empty document, and the frame's own
    /// document takes over that window (HTML's window reuse), with no new start of its scripts.
    private static let takeover = """
        <script>
        const frame = document.createElement('iframe');
        frame.src = location.origin + '/frame';
        frame.name = 'widget';
        frame.width = 440; frame.height = 240;
        document.body.append(frame);
        window.widget = window.frames[frame.name];
        </script>
        """

    private static func login(_ prefix: String) -> String {
        #"<form id="\#(prefix)form" onsubmit="return false"><input id="\#(prefix)u" autocomplete="username">"#
            + #"<input id="\#(prefix)p" type="password" autocomplete="current-password"><button id="\#(prefix)go" type="button">Sign in</button></form>"#
    }

    /// Each one tries to post as the other site from its own main world.
    private static let forge = """
        <script>
        document.documentElement.dataset.relay = typeof __wsurfSend;
        try {
          __wsurfSend('wsurfPasswords', {action: 'context', marker: location.hostname, token: crypto.randomUUID(),
            documentID: crypto.randomUUID(), field: 'text',
            url: location.hostname === 'localhost' ? 'http://127.0.0.1:' + location.port + '/' : 'http://localhost:' + location.port + '/frame'});
        } catch {}
        </script>
        """

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/": .html(page(cancel + login("t") + iframe("localhost", "/frame"))),
        "/frame": .html(page(cancel + login("f"))),
        "/takeover": .html(page(cancel + login("t") + takeover)),
        "/nested": .html(page(cancel + login("t") + iframe("localhost", "/middle"))),
        "/middle": .html(page(cancel + login("f") + iframe("app.localhost", "/inner"))),
        "/inner": .html(page(cancel + login("i"))),
        "/sandboxed": .html(page(login("t") + iframe("localhost", "/srcdoc", sandbox: "allow-scripts allow-forms"))),
        "/srcdoc": .html(page(login("f") + #"<iframe srcdoc="<form><input id='su' autocomplete='username'><input id='sp' type='password'></form>"></iframe>"#)),
        "/plain": .html(page(login("t") + iframe("localhost", "/srcdoc"))),
        "/forging": .html(page(login("t") + forge + iframe("localhost", "/forging-frame"))),
        "/forging-frame": .html(page(login("f") + forge)),
        "/workers": .html(page(login("t") + worker + iframe("localhost", "/worker-frame"))),
        "/worker-frame": .html(page(login("f") + worker)),
        "/worker.js": .bytes(Data("postMessage(navigator.userAgent);".utf8), contentType: "text/javascript"),
    ]

    /// Starts a dedicated worker and writes what it answers on the root element.
    private static let worker = """
        <script>
        const worker = new Worker('/worker.js');
        worker.onmessage = event => { document.documentElement.dataset.worker = event.data; };
        </script>
        """

    private static func page(_ body: String) -> String {
        "<!doctype html><html><body>\(body)</body></html>"
    }

    /// `media`: the iframe-audio script and its handler in the services world as the app installs them, plus a stand-in for another
    /// service's handler there.
    private func withPage(_ engine: BrowserEngine, _ path: String, media: Bool = false, body: (Harness) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        defer { withExtendedLifetime(server) {} }
        let url = try server.url(path)
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 640), configuration: configuration), context: context)
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            page = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        let harness = Harness(page: page, window: window, port: url.port ?? 0)
        page.installScript(PasswordAutofillScript.source, in: PasswordAutofill.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(AutofillSaveScript.clientSource, in: AutofillPage.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        for name in ["wsurfPasswords", "wsurfAutofillSave"] {
            page.addScriptMessageHandler(name: name, in: PasswordAutofill.world) { harness.receive($0) }
        }
        if media {
            page.installScript(MediaScript.source, in: BrowserPage.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            for name in [MediaCenter.frameScriptHandlerName, "wsurfSiteGuard"] {
                page.addScriptMessageHandler(name: name, in: BrowserPage.servicesWorld) { harness.receiveFromServices($0) }
            }
        }
        // A page-world handler of the same name: the page's main world gets a relay, which must reach it alone.
        page.addScriptMessageHandler(name: "wsurfPasswords", in: .page) { harness.receive(BrowserScriptMessage(
            page: $0.page, body: $0.body, frameInfo: $0.frameInfo, name: "page:" + $0.name
        )) }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try #require(await waitUntil { harness.main != nil })
            try await body(harness)
        } catch {
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        await page.close()
        await context.endPrivateSession()
    }

    // MARK: Frame identity

    @Test(arguments: BrowserEngine.allCases)
    func aCrossSiteFrameRunsTheAutofillScriptsUnderItsOwnOrigin(engine: BrowserEngine) async throws {
        try await withPage(engine, "/") { harness in
            let main = try #require(harness.main)
            let frame = try await harness.ready("localhost")
            #expect(main.securityOrigin.host == "127.0.0.1" && main.hasTrustedSecurityOrigin)
            #expect(!frame.isMainFrame && frame.hasTrustedSecurityOrigin)
            #expect(frame.securityOrigin == BrowserSecurityOrigin(protocol: "http", host: "localhost", port: harness.port))
            #expect(try await harness.run("return location.href;", in: frame) as? String == "http://localhost:\(harness.port)/frame")
            #expect(harness.posted("ready", by: "wsurfAutofillSave").contains { $0.frame.securityOrigin.host == "localhost" },
                    "the save script runs there too")
            guard let chromium = harness.page.chromium else { return }
            #expect(frame.chromiumParentID == main.chromiumID, "the frame names the page's frame as its parent")
            #expect(chromium.devTools.sessions.count == 1, "the cross-site frame has a session of its own")
            #expect(try await chromium.isLive(frame: frame))
            #expect(try await chromium.devTools.framesIncludingCrossSiteFrames().contains { $0.chromiumID == frame.chromiumID })
        }
    }

    /// Chromium only. The media script runs in the services world of a cross-site frame and nowhere else there: the autofill
    /// world has none of it and the services world none of autofill's, and what the services world sends reaches the media handler
    /// alone, never an autofill handler nor another service's.
    @Test func theMediaScriptReachesACrossSiteFrameInTheServicesWorldOnly() async throws {
        try await withPage(.chromium, "/", media: true) { harness in
            let frame = try await harness.ready("localhost")
            let services = BrowserPage.servicesWorld
            @MainActor func probe(in world: WKContentWorld) async throws -> [String: Any] {
                let script = """
                    return {media: window.__wsurfMedia === true, passwords: typeof globalThis.__wsurfPasswords,
                            save: typeof globalThis.__wsurfAutofillSave, send: typeof globalThis.__wsurfSend};
                    """
                let answer = try await harness.page.callAsyncJavaScript(script, in: frame, contentWorld: world)
                return try #require(answer as? [String: Any])
            }
            let inServices = try await probe(in: services)
            #expect(inServices["media"] as? Bool == true, "the media script runs in the frame's services world")
            #expect(inServices["passwords"] as? String == "undefined" && inServices["save"] as? String == "undefined",
                    "none of autofill's globals are in the services world")
            let inAutofill = try await probe(in: PasswordAutofill.world)
            #expect(inAutofill["media"] as? Bool == false, "the media script is not in the autofill world")
            #expect(inAutofill["passwords"] as? String == "object")
            // The page's own world: nothing of ours, or no access at all.
            if let inPage = try? await probe(in: .page) {
                #expect(inPage["media"] as? Bool == false && inPage["send"] as? String == "undefined" && inPage["passwords"] as? String == "undefined",
                        "the page world of the frame has nothing of ours")
            }

            // From the services world: an autofill handler and another service's handler, then the media handler's own word.
            let marker = UUID().uuidString
            _ = try await harness.page.callAsyncJavaScript("""
                globalThis.__wsurfSend('wsurfPasswords', {action: 'context', marker, token: 'forged', field: 'text', url: location.href});
                globalThis.__wsurfSend('wsurfAutofillSave', {action: 'stage', marker});
                globalThis.__wsurfSend('wsurfSiteGuard', {marker});
                globalThis.__wsurfSend('wsurfpip', 'settled:' + marker);
                """, arguments: ["marker": marker], in: frame, contentWorld: services)
            try #require(await waitUntil { harness.servicesPosts.contains { ($0.body as? String) == "settled:" + marker } })
            let word = try #require(harness.servicesPosts.first { ($0.body as? String) == "settled:" + marker })
            #expect(word.name == MediaCenter.frameScriptHandlerName)
            #expect(!word.frame.isMainFrame && word.frame.securityOrigin.host == "localhost" && word.frame.chromiumParentID != nil,
                    "the media handler hears the frame itself, which Chromium reported")
            #expect(harness.servicesPosts.allSatisfy { $0.name == MediaCenter.frameScriptHandlerName }, "another service's handler heard nothing")
            #expect(harness.posts.allSatisfy { ($0.body["marker"] as? String) != marker }, "no autofill handler heard the services world")
        }
    }

    /// Chromium only: in WebKit a programmatic focus in the cross-origin frame posted no request here (not investigated), and
    /// WebKit's cross-origin frames are not what this change is about.
    @Test func aFieldInACrossSiteFrameAsksForThatFramesOrigin() async throws {
        try await withPage(.chromium, "/") { harness in
            let main = try #require(harness.main)
            let frame = try await harness.ready("localhost")
            for target in [main, frame] {
                try await harness.run("globalThis.__wsurfPasswords.setEnabled(true);", in: target)
            }
            let focus = "document.getElementById(id).focus(); globalThis.__wsurfPasswords.refresh();"
            try await harness.run(focus, ["id": "fu"], in: frame)
            try #require(await waitUntil { !harness.posted("select").isEmpty }, "the frame's field asked for suggestions")
            let inFrame = try #require(harness.posted("select").last)
            #expect(!inFrame.frame.isMainFrame && inFrame.frame.securityOrigin.host == "localhost")
            #expect(inFrame.frame.documentID == frame.documentID)
            #expect(inFrame.body["url"] as? String == "http://localhost:\(harness.port)/frame")
            #expect((inFrame.body["rect"] as? [String: Any])?["embedded"] as? NSNumber == 1, "its field is measured in its own viewport")

            try await harness.run(focus, ["id": "tu"], in: main)
            try #require(await waitUntil { harness.posted("select").count > 1 })
            let onPage = try #require(harness.posted("select").last)
            #expect(onPage.frame.isMainFrame && onPage.frame.securityOrigin.host == "127.0.0.1")
            #expect(onPage.body["url"] as? String == "http://127.0.0.1:\(harness.port)/")
        }
    }

    /// The page's main world and the frame's main world each try to post as the other site. Neither reaches the autofill
    /// handlers, and what a main world can reach names its own frame.
    @Test(arguments: BrowserEngine.allCases)
    func neitherThePageNorTheFrameCanSpeakForTheOtherSite(engine: BrowserEngine) async throws {
        try await withPage(engine, "/forging") { harness in
            let main = try #require(harness.main)
            let frame = try await harness.ready("localhost")
            try await harness.settle(main)
            try await harness.settle(frame)
            #expect(harness.posted("context").isEmpty, "no forged right-click reached the autofill world")
            for forged in harness.posts where forged.name == "page:wsurfPasswords" {
                let claimed = forged.body["marker"] as? String
                #expect(forged.frame.securityOrigin.host == claimed, "a main world's message names its own frame")
                #expect(forged.frame.isMainFrame == (claimed == "127.0.0.1"))
            }
            let relay = try await harness.run("return document.documentElement.dataset.relay;", in: frame) as? String
            if engine == .chromium {
                #expect(relay == "undefined", "a cross-site frame's main world gets no relay at all")
            }
        }
    }

    // MARK: Pick Credential…

    /// Chromium only: WebKit has no out-of-process frames to attach to (and its app.localhost frame never reported ready here).
    @Test func nestedCrossSiteFramesTwoLevelsDeepSpeakForThemselves() async throws {
        try await withPage(.chromium, "/nested") { harness in
            let main = try #require(harness.main)
            let middle = try await harness.ready("localhost")
            let inner = try await harness.ready("app.localhost")
            #expect(inner.securityOrigin == BrowserSecurityOrigin(protocol: "http", host: "app.localhost", port: harness.port))
            #expect(!inner.isMainFrame && inner.hasTrustedSecurityOrigin)
            if let chromium = harness.page.chromium {
                #expect(inner.chromiumParentID == middle.chromiumID && middle.chromiumParentID == main.chromiumID)
                let sessions = chromium.devTools.sessions.values
                #expect(sessions.count == 2)
                let innerSession = sessions.first { $0.targetID == inner.chromiumID }
                #expect(innerSession?.parent?.targetID == middle.chromiumID, "the inner frame's session hangs off the middle one's")
            }
            for target in [main, middle, inner] {
                try await harness.run("globalThis.__wsurfPasswords.setEnabled(true);", in: target)
            }

            let click = try await harness.rightClick("iu", path: [middle, inner])
            #expect(click.frame.documentID == inner.documentID && click.frame.securityOrigin.host == "app.localhost")
            #expect(try await harness.pickFill(click, in: middle, ["username": "ada", "password": "dummy-secret"]) == 0,
                    "the frame around it does not know the right-click")
            #expect(try await harness.pickFill(click, in: main, ["username": "ada", "password": "dummy-secret"]) == 0)
            #expect(try await harness.pickFill(click, in: inner, ["username": "ada", "password": "dummy-secret"]) == 2)
            #expect(try await harness.value("iu", in: inner) == "ada")
            #expect(try await harness.value("ip", in: inner) == "dummy-secret")
            for (id, frame) in [("fu", middle), ("fp", middle), ("tu", main), ("tp", main)] {
                #expect(try await harness.value(id, in: frame) == "", "\(id) took nothing")
            }
        }
    }

    // MARK: A frame that took over its first document's window

    /// A frame of the page's own origin that took over its first, empty document's window (Apple's sign-in widget): a right-click in
    /// it reaches Pick Credential…, and the fill reaches that frame's fields. In Chromium the frame got WSurf's start scripts only in
    /// the empty document, so nothing in the frame's own document answered.
    @Test(arguments: BrowserEngine.allCases)
    func aFrameThatTookOverItsFirstWindowGetsPickCredential(engine: BrowserEngine) async throws {
        try await withPage(engine, "/takeover") { harness in
            let main = try #require(harness.main)
            let frame = try await harness.takenOver()
            #expect(frame.securityOrigin == main.securityOrigin && frame.hasTrustedSecurityOrigin)
            try await harness.run("globalThis.__wsurfPasswords.setEnabled(true);", in: frame)
            let click = try await harness.rightClick("fu", path: [frame])
            #expect(click.frame.documentID == frame.documentID, "the frame's own document answered the right-click")
            #expect(try await harness.pickFill(click, in: frame, ["username": "ada", "password": "dummy-secret"]) == 2)
            #expect(try await harness.value("fu", in: frame) == "ada")
            #expect(try await harness.value("fp", in: frame) == "dummy-secret")
            #expect(try await harness.value("tu", in: main) == "", "the page's own field took nothing")
            try await harness.settle(frame)
            #expect(harness.posted("context").filter { $0.frame.documentID == frame.documentID }.count == 1, "one right-click, one answer")

            // One instance listens to the window: a pageshow in the frame is answered once, not by the empty document's too.
            let ready = harness.posted("ready").filter { $0.frame.documentID == frame.documentID }.count
            _ = try await harness.page.callAsyncJavaScript(
                "dispatchEvent(new PageTransitionEvent('pageshow')); return true;", in: frame, contentWorld: .page
            )
            try await harness.settle(frame)
            #expect(harness.posted("ready").filter { $0.frame.documentID == frame.documentID }.count == ready + 1)
        }
    }

    /// The same frame: a login typed into it and sent with its button is staged for the frame, so WSurf offers to save it.
    @Test(arguments: BrowserEngine.allCases)
    func aLoginTypedInAFrameThatTookOverItsFirstWindowIsStaged(engine: BrowserEngine) async throws {
        try await withPage(engine, "/takeover") { harness in
            let frame = try await harness.takenOver()
            try #require(await waitUntil { harness.posted("ready", by: "wsurfAutofillSave").contains { $0.frame.documentID == frame.documentID } },
                         "the frame's own document runs the save script")
            try await harness.run("globalThis.__wsurfAutofillSave.setPolicy({password: true, card: false, contact: false});", in: frame)
            try await harness.type("ada@example.test", into: "fu", in: frame)
            try await harness.type("dummy-secret-123", into: "fp", in: frame)
            try await harness.click("fgo", path: [frame])
            try #require(await waitUntil { !harness.posted("stage", by: "wsurfAutofillSave").isEmpty }, "the login was staged")
            let staged = try #require(harness.posted("stage", by: "wsurfAutofillSave").last)
            #expect(staged.frame.documentID == frame.documentID && !staged.frame.isMainFrame)
            #expect(staged.body["url"] as? String == "http://127.0.0.1:\(harness.port)/frame")
            #expect(staged.body["password"] as? [String: String] == ["username": "ada@example.test", "password": "dummy-secret-123"])
            try await harness.settle(frame)
            #expect(harness.posted("stage", by: "wsurfAutofillSave").count == 1, "one login, one offer")
        }
    }

    // MARK: Save offers

    @Test(arguments: BrowserEngine.allCases)
    func aLoginTypedInACrossSiteFrameIsStagedForThatFrame(engine: BrowserEngine) async throws {
        try await withPage(engine, "/") { harness in
            let frame = try await harness.ready("localhost")
            try #require(await waitUntil { harness.posted("ready", by: "wsurfAutofillSave").contains { $0.frame.documentID == frame.documentID } })
            try await harness.run("globalThis.__wsurfAutofillSave.setPolicy({password: true, card: false, contact: false});", in: frame)
            for (id, value) in [("fu", "ada@example.test"), ("fp", "dummy-secret-123")] {
                try await harness.run(
                    "const e = document.getElementById(id); e.value = value; globalThis.__wsurfAutofillSave.__test.edit(e);",
                    ["id": id, "value": value], in: frame
                )
            }
            try await harness.run("globalThis.__wsurfAutofillSave.__test.click(document.getElementById('fgo'));", in: frame)
            try #require(await waitUntil { !harness.posted("stage", by: "wsurfAutofillSave").isEmpty })
            let staged = try #require(harness.posted("stage", by: "wsurfAutofillSave").last)
            #expect(staged.frame.documentID == frame.documentID && !staged.frame.isMainFrame)
            #expect(staged.frame.securityOrigin.host == "localhost")
            #expect(staged.body["url"] as? String == "http://localhost:\(harness.port)/frame")
            #expect(staged.body["password"] as? [String: String] == ["username": "ada@example.test", "password": "dummy-secret-123"])
        }
    }

    /// What the coordinator makes of a login staged in an https sign-in frame of another site: the offer is for the frame's origin,
    /// and the frame cannot have it filed under the page's.
    @Test func aSaveFromACrossSiteFrameIsOfferedForTheFramesOrigin() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, _ in
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration),
                                   context: BrowserProfileContext(profile: profile))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            defer { window.contentView = nil; window.close() }
            let session = AutofillSaveSession()
            session.liveness = { _, _, _ in true }
            let coordinator = AutofillSaveCoordinator.shared
            coordinator.install(in: page, session: session)
            page.url = URL(string: "https://shop.example/checkout")
            page.hasOnlySecureContent = true
            let documentID = UUID().uuidString
            let frame = BrowserFrame(
                id: "IDP", documentID: "loader-1", url: URL(string: "https://login.idp.example/embed")!, isMainFrame: false,
                securityOrigin: BrowserSecurityOrigin(protocol: "https", host: "login.idp.example", port: 0), parentID: "MAIN"
            )
            @MainActor func post(_ body: [String: Any]) {
                coordinator.receive(BrowserScriptMessage(page: page, body: body, frameInfo: frame, name: "wsurfAutofillSave"))
            }
            post(["action": "ready", "documentID": documentID, "url": "https://login.idp.example/embed"])
            @MainActor func stage(from url: String) -> UUID {
                let attempt = UUID()
                post([
                    "action": "stage", "documentID": documentID, "url": url, "attemptID": attempt.uuidString, "formID": "1",
                    "source": "submit", "password": ["username": "ada@example.test", "password": "dummy-secret-123"],
                ])
                return attempt
            }

            let forged = stage(from: "https://shop.example/checkout")
            #expect(session.submissions.lifetime(of: forged) == nil, "a frame cannot file its login under the page's origin")

            let attempt = stage(from: "https://login.idp.example/embed")
            #expect(session.submissions.lifetime(of: attempt) != nil)
            session.submissions.complete(id: attempt, documentID: documentID, formID: "1")
            #expect(await waitUntil { session.current != nil })
            let offer = try #require(session.current)
            #expect(offer.origin == "https://login.idp.example", "the offer is for the frame's origin, never the page's")
            #expect(offer.loginURL?.host() == "login.idp.example")
            await page.close()
        }
    }

    // MARK: Fail closed

    /// The frame's origin is the one suggestions, Pick Credential… and save offers use, exactly as for a page of that origin; a frame
    /// whose origin the engine does not vouch for, or that reports another origin's address, gets nothing.
    @Test func autofillUsesTheEnginesOriginForTheFrame() throws {
        let idp = BrowserSecurityOrigin(protocol: "https", host: "login.idp.example", port: 0)
        func frame(_ origin: BrowserSecurityOrigin = idp, trusted: Bool = true) -> BrowserFrame {
            BrowserFrame(id: "IDP", documentID: "loader", url: URL(string: "https://login.idp.example/embed")!, isMainFrame: false,
                         securityOrigin: origin, parentID: "MAIN", hasTrustedSecurityOrigin: trusted)
        }
        let embed = try #require(URL(string: "https://login.idp.example/embed?step=1"))
        #expect(frame().autofillOrigin(reportedURL: embed) == "https://login.idp.example")
        #expect(frame().autofillOrigin(reportedURL: try #require(URL(string: "https://shop.example/checkout"))) == nil,
                "a frame cannot claim the page's origin")
        #expect(frame().autofillOrigin(reportedURL: try #require(URL(string: "https://login.idp.example:8443/"))) == nil)
        #expect(frame().autofillOrigin(reportedURL: try #require(URL(string: "about:srcdoc"))) == nil)
        #expect(frame(trusted: false).autofillOrigin(reportedURL: embed) == nil, "an opaque or unverified origin gets nothing")
        #expect(frame(BrowserSecurityOrigin(protocol: "http", host: "login.idp.example", port: 0)).autofillOrigin(
            reportedURL: try #require(URL(string: "http://login.idp.example/embed"))) == nil)

        let accounts = [
            VaultFixtures.account(username: "shopper", origin: "https://shop.example"),
            VaultFixtures.account(username: "ada", origin: "https://login.idp.example"),
        ]
        let origin = try #require(frame().autofillOrigin(reportedURL: embed))
        let rows = CredentialAccountSelection.suggestions(
            accounts, origin: origin, pageURL: URL(string: "https://shop.example/checkout"), entered: nil, field: .password
        )
        #expect(rows.map(\.id) == [accounts[1].id], "the frame is offered its own origin's login, as a page of that origin is")
    }

    /// A cross-site frame session's frames, as Chromium reports them: never the page's main frame, trusted only for a document whose
    /// own address is of its origin, and only within its own target.
    @Test func aCrossSiteFrameSessionTrustsOnlyItsOwnFrames() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let root = ChromiumDevTools(page: native)
        let child = ChromiumDevTools(root: root, parent: root, sessionID: "S", targetID: "T")
        func frame(_ id: String, _ url: String, origin: String, parent: String? = "P") -> [String: Any] {
            var frame: [String: Any] = ["id": id, "url": url, "securityOrigin": origin, "loaderId": "L-" + id]
            if let parent {
                frame["parentId"] = parent
            }
            return frame
        }
        let own = try #require(child.parseFrame(frame("T", "https://login.idp.example/embed", origin: "https://login.idp.example"), parentID: "P"))
        #expect(!own.isMainFrame && own.hasTrustedSecurityOrigin && own.parentID == "P")
        #expect(child.parseFrame(frame("T", "https://login.idp.example/", origin: "https://login.idp.example"), parentID: nil) == nil,
                "a cross-site frame is never the page's main frame")
        let srcdoc = try #require(child.parseFrame(frame("C", "about:srcdoc", origin: "https://login.idp.example"), parentID: "T"))
        #expect(!srcdoc.hasTrustedSecurityOrigin, "an inheriting srcdoc is not trusted")
        let blank = try #require(child.parseFrame(frame("B", "about:blank", origin: "https://login.idp.example"), parentID: "T"))
        #expect(!blank.hasTrustedSecurityOrigin)
        let sandboxed = try #require(child.parseFrame(frame("O", "https://login.idp.example/x", origin: "null"), parentID: "T"))
        #expect(!sandboxed.hasTrustedSecurityOrigin, "an opaque origin is not trusted")
        // Chromium reports a sandboxed document's precursor as its origin; once its own origin was read as another, it stays
        // untrusted whenever its frame is reported again, in either kind of session.
        for session in [child, root] {
            session.documentOrigins["L-Q"] = false
            let precursor = try #require(session.parseFrame(frame("Q", "https://login.idp.example/q", origin: "https://login.idp.example"), parentID: "T"))
            #expect(!precursor.hasTrustedSecurityOrigin && precursor.serializedOrigin == "https://login.idp.example")
        }

        var parsed: [String: ChromiumDevTools.FrameState] = [:]
        let tree: [String: Any] = [
            "frame": frame("T", "https://login.idp.example/", origin: "https://login.idp.example"),
            "childFrames": [["frame": frame("K", "https://login.idp.example/k", origin: "https://login.idp.example", parent: nil)]],
        ]
        child.parseFrameTree(tree, parentID: nil, into: &parsed)
        #expect(Set(parsed.keys) == ["T", "K"] && parsed["K"]?.parentID == "T" && parsed["T"]?.parentID == "P")
        parsed = [:]
        child.parseFrameTree(["frame": frame("X", "https://evil.example/", origin: "https://evil.example")], parentID: nil, into: &parsed)
        #expect(parsed.isEmpty, "a tree rooted anywhere but at the session's own frame is refused")

        // The page's own session still has its main frame.
        let main = try #require(root.parseFrame(frame("M", "https://shop.example/", origin: "https://shop.example", parent: nil), parentID: nil))
        #expect(main.isMainFrame && main.hasTrustedSecurityOrigin)
        withExtendedLifetime(native) {}
        await context.endPrivateSession()
    }

    /// What a cross-site frame said about its sound must not outlive it: a frame session that ends as a whole (its process is gone,
    /// or it went back into its parent's) sends no `Page.frameDetached`, and a renderer that crashes drops its frames silently.
    /// Both tell the page's owner which frames are gone, which is what the media center reads.
    @Test func aCrossSiteFrameThatEndsOrCrashesRetiresItsFramesForTheMediaCenter() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        var retired: [Set<String>] = []
        page.onFramesRetired = { retired.append($0) }
        let root = ChromiumDevTools(page: native)
        func session(_ id: String, target: String, frames: [String]) throws -> ChromiumDevTools {
            let child = ChromiumDevTools(root: root, parent: root, sessionID: id, targetID: target)
            root.sessions[id] = child
            for (index, name) in frames.enumerated() {
                var frame: [String: Any] = [
                    "id": name, "url": "https://player.example/\(name)", "securityOrigin": "https://player.example", "loaderId": "L-" + name,
                ]
                if index == 0 {
                    frame["parentId"] = "P"
                }
                child.framesByID[name] = try #require(child.parseFrame(frame, parentID: index == 0 ? "P" : frames[0]))
            }
            return child
        }
        let ended = try session("S1", target: "T1", frames: ["T1", "T1a"])
        ended.endCrossSiteFrameSession()
        #expect(retired == [["T1", "T1a"]], "the session that ended says all its frames are gone")
        #expect(ended.framesByID.isEmpty && root.sessions["S1"] == nil)

        retired = []
        let crashed = try session("S2", target: "T2", frames: ["T2"])
        root.targetCrashed(["targetId": "T2"])
        #expect(retired == [["T2"]], "a crashed frame renderer says its frames are gone")
        #expect(crashed.framesByID.isEmpty && root.sessions["S2"] != nil, "its session stays for the reloaded frame")

        retired = []
        let quiet = try session("S3", target: "T3", frames: [])
        quiet.endCrossSiteFrameSession()
        #expect(retired.isEmpty, "a session with no frame has nothing to retire")
        await page.close()
        await context.endPrivateSession()
    }

    @Test func onlyTheListedScriptsAndHandlersReachCrossSiteFrames() {
        typealias Script = ChromiumDevTools.Script
        let autofill = PasswordAutofill.world.name ?? ""
        #expect(ChromiumDevTools.runsInCrossSiteFrames(Script(source: "x", worldName: autofill, injectionTime: .atDocumentStart, mainFrameOnly: false)))
        #expect(!ChromiumDevTools.runsInCrossSiteFrames(Script(source: "x", worldName: autofill, injectionTime: .atDocumentStart, mainFrameOnly: true)))
        #expect(!ChromiumDevTools.runsInCrossSiteFrames(Script(source: "x", worldName: "", injectionTime: .atDocumentStart, mainFrameOnly: false)),
                "never the page world")
        // The services world is shared with other features: only the media script and its handler reach a cross-site frame.
        let services = BrowserPage.servicesWorld.name ?? ""
        #expect(ChromiumDevTools.runsInCrossSiteFrames(Script(
            source: MediaScript.source, worldName: services, injectionTime: .atDocumentStart, mainFrameOnly: false
        )))
        #expect(!ChromiumDevTools.runsInCrossSiteFrames(Script(
            source: MediaScript.source, worldName: services, injectionTime: .atDocumentStart, mainFrameOnly: true
        )))
        #expect(!ChromiumDevTools.runsInCrossSiteFrames(Script(
            source: MediaScript.source, worldName: "", injectionTime: .atDocumentStart, mainFrameOnly: false
        )), "the media script never runs in the page world")
        #expect(!ChromiumDevTools.runsInCrossSiteFrames(Script(
            source: "another service's script", worldName: services, injectionTime: .atDocumentStart, mainFrameOnly: false
        )), "no other script of the services world")
        #expect(ChromiumDevTools.hearsCrossSiteFrames(.init(name: "wsurfPasswords", worldName: autofill)))
        #expect(!ChromiumDevTools.hearsCrossSiteFrames(.init(name: "wsurfPasswords", worldName: "")))
        #expect(ChromiumDevTools.hearsCrossSiteFrames(.init(name: MediaCenter.frameScriptHandlerName, worldName: services)))
        #expect(!ChromiumDevTools.hearsCrossSiteFrames(.init(name: MediaCenter.frameScriptHandlerName, worldName: "")),
                "never the page world's")
        #expect(!ChromiumDevTools.hearsCrossSiteFrames(.init(name: "wsurfPasswords", worldName: services)),
                "an autofill handler is never heard from the services world")
        for other in ["wsurfSiteGuard", "wsurfPageActivity", "wsurfScrollPosition"] {
            #expect(!ChromiumDevTools.hearsCrossSiteFrames(.init(name: other, worldName: services)), "no other handler of the services world")
        }
    }

    /// The page's session takes a cross-site frame session's messages itself, whole, and leaves its own to CEF, also when one of
    /// them mentions a session inside its parameters.
    @Test func sessionMessagesAreTakenAndThePagesOwnAreLeft() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let root = ChromiumDevTools(page: native)
        func taken(_ json: String) -> Bool {
            let data = Data(json.utf8)
            return data.withUnsafeBytes { root.receiveSessionMessage($0.baseAddress!, size: data.count) }
        }
        #expect(taken(#"{"method":"Page.frameNavigated","params":{"frame":{"id":"T"}},"sessionId":"S"}"#))
        #expect(taken(#"{"id":7,"result":{},"sessionId":"S"}"#))
        #expect(!taken(#"{"method":"Target.attachedToTarget","params":{"sessionId":"S","targetInfo":{"targetId":"T","type":"iframe"}}}"#))
        #expect(!taken(#"{"method":"Page.frameNavigated","params":{"frame":{"id":"M","url":"https://a.example/?\"sessionId\""}}}"#))
        #expect(!taken(#"{"id":8,"result":{"sessionId":"S"}}"#))
        // One that does not parse is still a session's when it ends as Chromium ends them, and never handed to the page's session.
        #expect(taken(#"{"method":"Page.frameNavigated","params":{"frame":{"id":tru}},"sessionId":"S"}"#))
        #expect(!taken(#"{"method":"Page.frameNavigated","params":{"sessionId":"S","frame":{"id":tru}}}"#))
        #expect(root.framesByID.isEmpty, "nothing reached the page's own frames")
        withExtendedLifetime(native) {}
        await context.endPrivateSession()
    }

    /// The frame goes away while a call into it is under way: the call ends at once, its session and documents end, and nothing is
    /// prepared for it afterwards.
    @Test func aFrameThatGoesAwayMidFillTakesNothingAndLeavesNothing() async throws {
        try await withPage(.chromium, "/") { harness in
            let chromium = try #require(harness.page.chromium)
            let frame = try await harness.ready("localhost")
            #expect(chromium.devTools.sessions.count == 1)
            let pending = Task { _ = try await harness.run("await new Promise(done => setTimeout(done, 6000)); return 'late';", in: frame) }
            try await Task.sleep(for: .milliseconds(300))
            try await harness.run("document.querySelector('iframe').remove();", in: nil)
            let removed = ContinuousClock.now
            await #expect(throws: (any Error).self) { try await pending.value }
            #expect(ContinuousClock.now - removed < .seconds(5), "the call ended with its frame")
            #expect(await waitUntil { chromium.devTools.sessions.isEmpty }, "the frame's session ended")
            #expect(await waitUntil { harness.invalidated.contains(frame.documentID) }, "its document ended its credential contexts")
            #expect(try await chromium.isLive(frame: frame) == false)

            let prepared = PreparedCount()
            await #expect(throws: (any Error).self) {
                _ = try await harness.page.callAsyncJavaScript(
                    "return fields;", in: frame, contentWorld: PasswordAutofill.world,
                    prepareArguments: { prepared.value += 1; return ["fields": ["password": "dummy-secret"]] }
                )
            }
            #expect(prepared.value == 0, "no fill is prepared for a frame that is gone")
            #expect(try await harness.value("tp", in: nil) == "", "the page took nothing")
        }
    }

    /// Auto-attaching to cross-site frames must not hold anything else: Chromium pauses new dedicated workers while it is on, so a
    /// worker of the page and one of a cross-site frame must still start and answer.
    @Test func workersOfThePageAndOfACrossSiteFrameStillRun() async throws {
        try await withPage(.chromium, "/workers") { harness in
            let frame = try await harness.ready("localhost")
            for document in [nil, frame] {
                #expect(await waitUntil(timeout: .seconds(10)) {
                    (try? await harness.run("return document.documentElement.dataset.worker ?? null;", in: document)) is String
                }, "the worker of \(document == nil ? "the page" : "the frame") answered")
            }
            let chromium = try #require(harness.page.chromium)
            #expect(await waitUntil { chromium.devTools.sessions.values.allSatisfy { $0.targetID == frame.chromiumID } }, "workers keep no session")
        }
    }

    /// A fill already under way when an agent takes the tab is refused at the engine's dispatch, where every fill's arguments are made
    /// (`AutofillSuggestions.requireAuthority` asks the same predicate there), in the page's frame and in a cross-site frame; once the
    /// agent lets go, the same fill lands.
    @Test(arguments: BrowserEngine.allCases)
    func aFillUnderWayIsRefusedWhenAnAgentTakesTheTab(engine: BrowserEngine) async throws {
        try await withPage(engine, "/") { harness in
            let page = harness.page
            let tab = BrowserTab(opensBlank: false, context: page.context)
            AutofillSaveCoordinator.shared.install(in: page, session: tab.autofillSave)
            let frame = try await harness.ready("localhost")
            for (target, id) in [(nil, "tp"), (frame, "fp")] as [(BrowserFrame?, String)] {
                let underWay = Task { try await fill(id, with: "dummy-secret", in: target, of: page) }
                tab.setAgentWorking(true)
                await #expect(throws: (any Error).self, "\(id): refused once the agent took the tab") { try await underWay.value }
                #expect(try await harness.value(id, in: target) == "")

                tab.setAgentWorking(false)
                try await fill(id, with: "dummy-secret", in: target, of: page)
                #expect(try await harness.value(id, in: target) == "dummy-secret")
            }
        }
    }

    /// A fill through the dispatch boundary, whose arguments exist only if no agent controls the tab when it is sent.
    private func fill(_ id: String, with value: String, in frame: BrowserFrame?, of page: BrowserPage) async throws {
        _ = try await page.callAsyncJavaScript(
            "document.getElementById(id).value = value; return 1;", in: frame, contentWorld: PasswordAutofill.world,
            prepareArguments: {
                guard !AutofillSuggestions.isAgentControlled(page) else { throw ContactAutofillError.changedPage }
                return ["id": id, "value": value]
            }
        )
    }

    @MainActor
    private final class PreparedCount {
        var value = 0
    }

    /// A sandboxed frame of another site has an opaque origin, and a srcdoc frame inside a cross-site frame only inherits one:
    /// whatever their scripts report, nothing is trusted there.
    @Test(arguments: BrowserEngine.allCases)
    func aSandboxedOrInheritingFrameGetsNothing(engine: BrowserEngine) async throws {
        try await withPage(engine, "/sandboxed") { harness in
            let heard = await waitUntil(timeout: .seconds(6)) { harness.posted("ready").contains { !$0.frame.isMainFrame } }
            if engine == .chromium {
                #expect(heard, "the sandboxed frame's script runs and is heard, so the check below is not empty")
            }
            for ready in harness.posted("ready") where !ready.frame.isMainFrame {
                #expect(!ready.frame.hasTrustedSecurityOrigin, "\(ready.frame.request.url?.absoluteString ?? "?") is not trusted")
            }
        }
        guard engine == .chromium else { return }
        try await withPage(engine, "/plain") { harness in
            let frame = try await harness.ready("localhost")
            #expect(frame.hasTrustedSecurityOrigin)
            #expect(await waitUntil { harness.posted("ready").contains { $0.frame.request.url?.absoluteString == "about:srcdoc" } },
                    "the srcdoc frame's script runs")
            for ready in harness.posted("ready") where ready.frame.request.url?.absoluteString == "about:srcdoc" {
                #expect(!ready.frame.hasTrustedSecurityOrigin && ready.frame.chromiumParentID == frame.chromiumID)
            }
        }
    }
}
