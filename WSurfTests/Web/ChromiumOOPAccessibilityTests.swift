// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Darwin
import Foundation
import ObjectiveC
import Testing

@testable import CefKit
@testable import WSurf

/// D4-41: the VoiceOver mirror of a page that runs in the Chromium service, through the `NSAccessibility` API of its content view
/// (`ChromiumRemoteContentView`), in process: no VoiceOver runs and no accessibility setting is touched. The "VoiceOver" of a test is
/// `voiceOverChanged`, a call, and its `voiceOverSource` says false.
///
/// Three groups. The first needs no service (a page whose browser sends nowhere, and trees built by hand) and runs in both lanes. The
/// second is the default lane's proof that a page in process answers as it did. The third drives real pages through the service
/// (gated per test on `ChromiumServiceBundle.isPresent`; the OOP lane: `Tools/run-chromium-oop-tests.sh ChromiumOOPAccessibilityTests`).
/// Fixtures on 127.0.0.1 only.
@MainActor
@Suite(.serialized)
struct ChromiumOOPAccessibilityTests {
    init() {
        #if DEBUG
        // As `ChromiumOOPPageTests`: before any Chromium start of this host. Without the service the override changes nothing.
        ChromiumOOP.testOverride = true
        #endif
    }

    // MARK: Trees built by hand

    private static func node(
        _ id: Int, _ role: String, name: String = "", children: [Int] = [], level: Int? = nil, url: String? = nil, value: String? = nil,
        frame: CGRect = .zero
    ) -> [String: Any] {
        var attributes: [String: Any] = ["name": name]
        if let level {
            attributes["hierarchicalLevel"] = level
        }
        if let url {
            attributes["url"] = url
        }
        if let value {
            attributes["value"] = value
        }
        return [
            "id": id, "role": role, "child_ids": children,
            // JSON numbers, as the service sends them (a CGFloat in an `Any` is not a Double to the mirror's decoding).
            "location": ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)] as [String: Any],
            "attributes": attributes,
        ]
    }

    private static func tree(_ nodes: [[String: Any]], root: Int = 1, id: String = "tree-1", title: String = "Fixture") -> [String: Any] {
        let data: [String: Any] = ["title": title, "url": "http://127.0.0.1/ax"]
        let update: [String: Any] = ["root_id": root, "has_tree_data": true, "tree_data": data, "nodes": nodes]
        return ["ax_tree_id": id, "updates": [update]]
    }

    /// The page the fixture describes (`ax.html`), as Chromium at scale 2 would report it: physical pixels, the root as wide as the
    /// viewport was (1600 of them: an 800-point view).
    private static let page: [String: Any] = tree([
        node(1, "rootWebArea", children: [2], frame: CGRect(x: 0, y: 0, width: 1600, height: 1200)),
        node(2, "genericContainer", children: [3, 4, 5, 6]),
        node(3, "heading", name: "Heading", children: [7], level: 1, frame: CGRect(x: 200, y: 100, width: 400, height: 60)),
        node(7, "staticText", name: "Heading", frame: CGRect(x: 200, y: 100, width: 400, height: 60)),
        node(4, "paragraph", children: [8]),
        node(8, "staticText", name: "Some text", frame: CGRect(x: 200, y: 200, width: 300, height: 40)),
        node(5, "button", name: "Press", frame: CGRect(x: 200, y: 300, width: 200, height: 50)),
        node(6, "link", name: "Link", url: "http://127.0.0.1/ax2", frame: CGRect(x: 200, y: 400, width: 100, height: 30)),
    ])

    // MARK: A page with a recorded browser (no service)

    private struct Rig {
        let context: BrowserProfileContext
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow
        let connection: ChromiumRemote
        let remote: ChromiumRemoteBrowser

        var view: ChromiumRemoteContentView {
            guard let view = remote.contentView else { preconditionFailure("the rig's browser has no content view") }
            return view
        }

        var mirror: ChromiumAccessibilityMirror {
            guard let mirror = connection.browserAccessibility(remote.id)?.mirror else { preconditionFailure("the rig's browser is not registered") }
            return mirror
        }

        func end() async {
            window.contentView = nil
            window.close()
            connection.disconnect()
            await page.close()
            await context.endPrivateSession()
        }
    }

    /// A page in a 1000 x 600 window, whose browser was told scale 2 and sends nowhere: no service, no CEF.
    private func makeRig() async -> Rig {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-axview-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
        connection.accessibility.voiceOverSource = { false }
        let remote = ChromiumRemoteBrowser(page: native, connection: connection)
        remote.outgoing = { _ in true }
        native.remote = remote
        native.preparation = Task<Void, Error> {}
        native.hasAppliedInitialSettings = true
        remote.markCreated()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        native.attachRemoteFrameLayer(to: remote)
        // The page's own geometry update (queued when it joined the window) runs first and says the window's real scale, whatever the
        // display is; the rig then says 2, which nothing changes again (no resize follows).
        _ = await waitUntil(timeout: .seconds(5)) { !remote.geometryUpdatePending }
        remote.sentScale = 2
        return Rig(context: context, native: native, page: page, window: window, connection: connection, remote: remote)
    }

    private static let heading = NSAccessibility.Role(rawValue: "AXHeading")

    private static func children(of element: Any?) -> [ChromiumAccessibilityElement] {
        (((element as? NSAccessibilityElement)?.accessibilityChildren() ?? (element as? NSView)?.accessibilityChildren()) ?? [])
            .compactMap { $0 as? ChromiumAccessibilityElement }
    }

    /// Every element under `view`, in tree order.
    private static func walk(_ view: NSView) -> [ChromiumAccessibilityElement] {
        func descend(_ element: ChromiumAccessibilityElement) -> [ChromiumAccessibilityElement] {
            [element] + children(of: element).flatMap(descend)
        }
        return children(of: view).flatMap(descend)
    }

    private static func find(_ view: NSView, role: NSAccessibility.Role, title: String? = nil) -> ChromiumAccessibilityElement? {
        walk(view).first { $0.accessibilityRole() == role && (title == nil || $0.accessibilityTitle() == title) }
    }

    /// An element's frame in the view's points (the view is flipped: its origin is the top-left).
    private static func frameInView(_ element: ChromiumAccessibilityElement, of rig: Rig) -> CGRect {
        rig.view.convert(rig.window.convertFromScreen(element.accessibilityFrame()), from: nil)
    }

    private static func isNear(_ a: CGRect, _ b: CGRect, by tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    @Test func theViewShowsAnAXWebAreaWhoseChildrenAreTheHeadingTextButtonAndLinkWithTheirNamesAndValues() async {
        let rig = await makeRig()
        #expect(rig.view.accessibilityChildren()?.isEmpty == true, "no tree has arrived: nothing to show")
        rig.mirror.apply(.tree, json: Self.page)
        let root = rig.view.accessibilityChildren()?.first as? ChromiumAccessibilityElement
        #expect(root?.accessibilityRole() == NSAccessibility.Role(rawValue: "AXWebArea"), "the root's role (Q12b): \(String(describing: root?.accessibilityRole()))")
        #expect(root?.accessibilityTitle() == "Fixture")
        #expect(root?.accessibilityURL()?.absoluteString == "http://127.0.0.1/ax")
        let children = Self.children(of: root)
        #expect(children.map { $0.accessibilityRole() } == [Self.heading, .staticText, .button, .link], "the container and the paragraph give way")
        #expect(children.first?.accessibilityTitle() == "Heading")
        #expect(children.first?.accessibilityValue() as? Int == 1, "the heading level")
        #expect(children.first?.accessibilityRoleDescription() == "heading")
        #expect(Self.children(of: children.first).isEmpty, "a heading speaks its own name: its text is not repeated")
        #expect(children[1].accessibilityValue() as? String == "Some text")
        #expect(children[2].accessibilityTitle() == "Press")
        #expect(children[3].accessibilityTitle() == "Link")
        #expect(children[3].accessibilityURL()?.absoluteString == "http://127.0.0.1/ax2")
        await rig.end()
    }

    /// The plan's mutation: the spike calibrated the unit from the root's width. The root here is 1600 units wide in a 1000-point view
    /// (a resize that has not reached the tree yet), which a calibration reads as a scale of 1.6; the scale the service was told is 2.
    @Test func framesAreInViewPointsFromTheScaleTheServiceWasToldWhateverWidthTheTreeHas() async {
        let rig = await makeRig()
        rig.mirror.apply(.tree, json: Self.page)
        #expect(rig.mirror.rootBounds?.width == 1600)
        #expect(rig.view.bounds.width == 1000)
        let headingElement = Self.find(rig.view, role: Self.heading)
        #expect(headingElement != nil)
        let frame = headingElement.map { Self.frameInView($0, of: rig) } ?? .zero
        #expect(Self.isNear(frame, CGRect(x: 100, y: 50, width: 200, height: 30)), "the heading at 200,100 400x60 units at scale 2: \(frame)")
        if let button = Self.find(rig.view, role: .button) {
            #expect(Self.isNear(Self.frameInView(button, of: rig), CGRect(x: 100, y: 150, width: 100, height: 25)))
        }
        await rig.end()
    }

    @Test func aPointOnTheScreenFindsTheElementUnderIt() async throws {
        let rig = await makeRig()
        rig.mirror.apply(.tree, json: Self.page)
        let button = try #require(Self.find(rig.view, role: .button))
        let screen = button.accessibilityFrame()
        let hit = rig.view.accessibilityHitTest(NSPoint(x: screen.midX, y: screen.midY)) as? ChromiumAccessibilityElement
        #expect(hit === button, "the hit is \(String(describing: hit?.accessibilityTitle()))")
        let onRoot = rig.view.accessibilityHitTest(NSPoint(x: screen.midX, y: screen.maxY + 300)) as? ChromiumAccessibilityElement
        #expect(onRoot?.accessibilityRole() == NSAccessibility.Role(rawValue: "AXWebArea"), "a point over nothing is the page's")
        await rig.end()
    }

    /// The plan's second mutation: after an update the parents are made again. A node a DOM change adds has none until then, and a
    /// client asks an element for its parent to walk up.
    @Test func aNodeTheNextUpdateAddsKnowsItsParentSoTheTreeFollowsADomChange() async throws {
        let rig = await makeRig()
        rig.mirror.apply(.tree, json: Self.page)
        let root = try #require(rig.view.accessibilityChildren()?.first as? ChromiumAccessibilityElement)
        #expect(Self.find(rig.view, role: .button, title: "New") == nil)
        rig.mirror.apply(.tree, json: Self.tree([
            Self.node(2, "genericContainer", children: [3, 4, 5, 6, 9]),
            Self.node(9, "button", name: "New", frame: CGRect(x: 200, y: 500, width: 100, height: 40)),
        ]))
        let added = try #require(Self.find(rig.view, role: .button, title: "New"))
        #expect(added.accessibilityParent() as? ChromiumAccessibilityElement === root, "its parent is the web area, past the container that gives way")
        #expect(Self.children(of: root).count == 5)
        // A node a later update drops from its parent's children is gone, with its element.
        rig.mirror.apply(.tree, json: Self.tree([Self.node(2, "genericContainer", children: [3, 4, 5, 6])]))
        #expect(Self.find(rig.view, role: .button, title: "New") == nil)
        #expect(added.isAccessibilityElement() == false, "a client that still holds it is told it does not exist")
        await rig.end()
    }

    @Test func aLocationUpdateMovesAnElementAndAReplacedTreeLeavesNoOldNodes() async throws {
        let rig = await makeRig()
        rig.mirror.apply(.tree, json: Self.page)
        let before = rig.mirror.nodeCount
        let button = try #require(Self.find(rig.view, role: .button))
        rig.mirror.apply(.location, json: [
            ["ax_tree_id": "tree-1", "id": 5, "new_location": ["bounds": ["x": 200.0, "y": 600.0, "width": 200.0, "height": 50.0]] as [String: Any]],
        ] as [[String: Any]])
        #expect(Self.isNear(Self.frameInView(button, of: rig), CGRect(x: 100, y: 300, width: 100, height: 25)))
        // The page navigates: a new tree, a new root.
        rig.mirror.apply(.tree, json: Self.tree([Self.node(1, "rootWebArea", children: [2]), Self.node(2, "button", name: "Next")], id: "tree-2"))
        #expect(rig.mirror.nodeCount == 2 && before > 2, "the old tree is gone, not kept beside the new one")
        #expect(Self.walk(rig.view).dropFirst().map { $0.accessibilityTitle() } == ["Next"], "the web area and the one button")
        await rig.end()
    }

    @Test func theFirstQueryWantsTheTreeAndNothingBeforeItDoes() async {
        let rig = await makeRig()
        #expect(!rig.connection.accessibility.wantsTree && !rig.connection.accessibilityIsOn, "VoiceOver is off and nobody asked")
        _ = rig.view.accessibilityChildren()
        #expect(rig.connection.accessibility.wantsTree, "the first query by any client turns the tree on (Q12)")
        await rig.end()
    }

    @Test func theMirrorEmptiesWhenTheServiceEndsAndALateUpdateOfTheOldConnectionIsDropped() async throws {
        let rig = await makeRig()
        rig.mirror.apply(.tree, json: Self.page)
        let mirror = rig.mirror
        #expect(!(rig.view.accessibilityChildren() ?? []).isEmpty)
        let message = CefRemoteMessage(CefRemote.Event.accessibilityTree, browser: rig.remote.id)
        message.set(CefRemote.Key.data, data: try JSONSerialization.data(withJSONObject: Self.page))
        let update = try #require(ChromiumAccessibilityUpdate.parse(message, data: message.data(CefRemote.Key.data))?.update)
        let epoch = rig.connection.accessibility.epoch
        // The service ended: the connection's instance goes (`takeEverythingDown`), and with it what it held.
        rig.connection.closeAccessibility()
        rig.connection.accessibility.decoder.queue.sync {}
        #expect(mirror.isEmpty, "the mirror was emptied behind the updates it already had")
        #expect(rig.view.accessibilityChildren()?.isEmpty == true)
        #expect(rig.connection.browserAccessibility(rig.remote.id) == nil)
        let droppedBefore = rig.connection.accessibility.droppedUpdates
        rig.connection.receiveAccessibility(update, epoch: epoch)
        #expect(rig.connection.accessibility.droppedUpdates == droppedBefore + 1, "an update the dropped connection delivered late is ignored")
        #expect(mirror.isEmpty)
        await rig.end()
    }

    // MARK: The decoder and the cap

    @Test func anUpdateOverTheCapIsNotParsedAndTheBrowsersTreeIsTurnedOffAndEmptied() async throws {
        let rig = await makeRig()
        rig.mirror.apply(.tree, json: Self.page)
        let decoder = rig.connection.accessibility.decoder
        let message = CefRemoteMessage(CefRemote.Event.accessibilityTree, browser: rig.remote.id)
        message.set(CefRemote.Key.data, data: Data(count: ChromiumAccessibilityDecoder.maxUpdateBytes + 1))
        let told = CallCounts()
        decoder.queue.sync {
            decoder.decode(.message(message), deliver: { _ in told.deliver() }, oversize: { _ in told.oversize() })
        }
        #expect(told.oversizeCount == 1 && told.deliverCount == 0)
        #expect(decoder.statistics.oversized == 1 && decoder.statistics.undecodable == 0)
        rig.connection.suspendAccessibility(browser: rig.remote.id, epoch: rig.connection.accessibility.epoch)
        decoder.queue.sync {}
        #expect(rig.connection.browserAccessibility(rig.remote.id)?.isSuspended == true)
        #expect(rig.mirror.isEmpty)
        await rig.end()
    }

    // MARK: A page in process

    /// The default lane's proof of the plan's C1: a page in process answers the accessibility queries it did before, because it has no
    /// override of them. A page's own methods are NSView's; the OOP content view's are not.
    @Test(.enabled(if: !ChromiumServiceBundle.isPresent))
    func aPageInProcessAnswersAccessibilityAsItDidAndOnlyTheContentViewAnswersFromTheMirror() {
        let selectors = [
            #selector(NSView.accessibilityChildren), #selector(NSView.accessibilityHitTest(_:)),
            #selector(NSView.accessibilityFocusedUIElement), #selector(NSView.isAccessibilityElement),
            #selector(NSView.accessibilityRole), #selector(NSView.accessibilityParent),
        ]
        func implementation(_ type: AnyClass, _ selector: Selector) -> UnsafeRawPointer? {
            class_getMethodImplementation(type, selector).map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
        }
        for selector in selectors {
            let plain = implementation(NSView.self, selector)
            #expect(implementation(ChromiumPage.self, selector) == plain, "ChromiumPage overrides \(selector)")
            #expect(implementation(BrowserPage.self, selector) == plain, "BrowserPage overrides \(selector)")
        }
        let own = implementation(ChromiumRemoteContentView.self, #selector(NSView.accessibilityChildren))
        #expect(own != implementation(NSView.self, #selector(NSView.accessibilityChildren)), "the OOP view answers from the mirror")
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        #expect(native.remote == nil)
        #expect(!(native.accessibilityChildren() ?? []).contains { $0 is ChromiumAccessibilityElement })
        #expect(native.subviews.allSatisfy { !($0 is ChromiumRemoteContentView) })
    }

    // MARK: Real pages through the service

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/ax": .html("""
            <!doctype html><title>AX</title><body style="margin:0;font:16px sans-serif">
            <h1 style="margin:20px 0 0 40px">Heading</h1>
            <p style="margin:8px 40px">Some text</p>
            <button id="b" style="margin-left:40px" onclick="document.title='pressed'">Press</button>
            <input id="f" aria-label="Name" style="display:block;margin:12px 40px">
            <a id="l" href="/ax2" style="margin-left:40px">Link</a>
            </body>
            """),
        "/ax2": .html("<!doctype html><title>Second</title><body><p>second</p></body>"),
    ]

    /// A connection of its own (the test's VoiceOver is a call), a window with a page on it, and the tab's reaction to a lost browser.
    private final class Live {
        let server: HTTPFixtureServer
        let connection: ChromiumRemote
        let context: BrowserProfileContext
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow
        let pid: pid_t

        init(server: HTTPFixtureServer, connection: ChromiumRemote, pid: pid_t) {
            self.server = server
            self.connection = connection
            self.pid = pid
            context = BrowserProfileContext(profile: .privateBrowsing())
            native = ChromiumPage(context: context)
            native.remoteConnection = connection
            page = BrowserPage(chromium: native)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            window.orderBack(nil)
            page.onContentProcessTerminated = { [weak page] in
                guard let page, let url = page.url else { return }
                page.load(URLRequest(url: url))
            }
        }

        var view: ChromiumRemoteContentView? {
            native.remote?.contentView
        }

        var mirror: ChromiumAccessibilityMirror? {
            native.remote.flatMap { connection.browserAccessibility($0.id)?.mirror }
        }

        func load(_ path: String) async throws {
            let url = try server.url(path)
            page.load(URLRequest(url: url))
            try #require(await waitUntil(timeout: .seconds(45)) { page.url == url && !page.isLoading }, "\(url) did not load")
        }

        /// The web area, once the tree is in (asking is what turns it on).
        func root() async -> ChromiumAccessibilityElement? {
            let arrived = await waitUntil(timeout: .seconds(30)) { view?.accessibilityChildren()?.isEmpty == false }
            return arrived ? view?.accessibilityChildren()?.first as? ChromiumAccessibilityElement : nil
        }

        func finish() async {
            page.onContentProcessTerminated = nil
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
            connection.disconnect()
            let gone = await waitUntil(timeout: .seconds(10)) { kill(pid, 0) == -1 && errno == ESRCH }
            #expect(gone, "the service \(pid) did not leave after its connection closed")
        }
    }

    private func live(_ path: String = "/ax") async throws -> Live {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-axpage-\(UUID().uuidString)", directoryHint: .isDirectory)
        let canonical = try ChromiumRemote.prepareRoot(root)
        let connection = ChromiumRemote(
            sink: ChromiumFrameSink(), root: { canonical }, helloTimeout: 30,
            clock: { ProcessInfo.processInfo.systemUptime }, latch: ChromiumOOP.Latch(), isEnabled: { true })
        connection.accessibility.voiceOverSource = { false }
        _ = connection.connect()
        guard await waitUntil(timeout: .seconds(45), { connection.isRunning }), case let .running(pid) = connection.state else {
            connection.disconnect()
            throw CancellationError()
        }
        let live = Live(server: server, connection: connection, pid: pid)
        do {
            try await live.load(path)
        } catch {
            await live.finish()
            throw error
        }
        return live
    }

    private func withLive(_ path: String = "/ax", _ body: (Live) async throws -> Void) async throws {
        let live = try await live(path)
        do {
            try await body(live)
        } catch {
            await live.finish()
            throw error
        }
        await live.finish()
    }

    private func domRects(_ live: Live) async throws -> [CGRect] {
        let json = try await live.page.evaluateJavaScript(
            "JSON.stringify(['h1', '#b', '#f', '#l'].map(s => { const r = document.querySelector(s).getBoundingClientRect(); return [r.x, r.y, r.width, r.height] }))")
        let rows = try #require((json as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[Double]])
        return rows.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func theFixtureShowsAHeadingTextAButtonAFieldAndALinkWithTheirNamesAndFramesInsideTheViewAndTheTreeIsBuiltOnlyOnceAsked() async throws {
        try await withLive { live in
            let view = try #require(live.view)
            #expect(!live.connection.accessibilityIsOn && !live.connection.hasAccessibilityConnection, "nobody asked: no tree, no connection")
            let root = try #require(await live.root(), "no tree arrived: wants \(live.connection.accessibility.wantsTree), on \(live.connection.accessibilityIsOn)")
            #expect(live.connection.accessibilityIsOn)
            #expect(root.accessibilityRole() == NSAccessibility.Role(rawValue: "AXWebArea"))
            #expect(root.accessibilityTitle() == "AX")
            let all = Self.walk(view)
            let heading = try #require(all.first { $0.accessibilityRole() == Self.heading })
            #expect(heading.accessibilityTitle() == "Heading" && heading.accessibilityValue() as? Int == 1, "a heading of level 1")
            #expect(all.contains { $0.accessibilityRole() == .staticText && $0.accessibilityValue() as? String == "Some text" })
            let button = try #require(all.first { $0.accessibilityRole() == .button })
            #expect(button.accessibilityTitle() == "Press")
            let field = try #require(all.first { $0.accessibilityRole() == .textField })
            #expect(field.accessibilityTitle() == "Name")
            let link = try #require(all.first { $0.accessibilityRole() == .link })
            #expect(link.accessibilityTitle() == "Link")
            #expect(link.accessibilityURL()?.path == "/ax2")
            // Their frames are where the page has them, in the view's points (the scale is the window's: 1 or 2).
            let rects = try await domRects(live)
            let scale = live.native.remote?.sentScale ?? 1
            for (element, expected) in zip([heading, button, field, link], rects) {
                let frame = view.convert(live.window.convertFromScreen(element.accessibilityFrame()), from: nil)
                #expect(view.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) && frame.width > 0, "inside the view: \(frame)")
                let name = element.accessibilityTitle() ?? "?"
                #expect(Self.isNear(frame, expected, by: 3), "\(name) at scale \(scale): the element says \(frame), the page \(expected)")
            }
            let observed = "tree of \(live.mirror?.nodeCount ?? 0) nodes in \(live.mirror?.treeUpdates ?? 0) updates, root \(String(describing: live.mirror?.rootBounds))"
            print("ChromiumOOPAccessibilityTests observed: scale \(scale), \(observed)")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func pressingTheButtonThroughAccessibilitySetsTheTitleToPressedAndPressingTheLinkNavigates() async throws {
        try await withLive { live in
            let view = try #require(live.view)
            _ = try #require(await live.root())
            let button = try #require(Self.walk(view).first { $0.accessibilityRole() == .button })
            #expect(button.accessibilityPerformPress())
            #expect(await waitUntil(timeout: .seconds(10)) { live.page.title == "pressed" }, "the title is '\(live.page.title ?? "")'")
            let link = try #require(Self.walk(view).first { $0.accessibilityRole() == .link })
            #expect(link.accessibilityPerformPress())
            let second = try live.server.url("/ax2")
            #expect(await waitUntil(timeout: .seconds(10)) { live.page.url == second }, "the page is at \(String(describing: live.page.url))")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aDomChangeShowsInTheTreeWithinASecondAndTheNewNodeKnowsItsParent() async throws {
        try await withLive { live in
            let view = try #require(live.view)
            let root = try #require(await live.root())
            // The first tree may still be arriving in pieces: wait until it is quiet, so that the change is the only news.
            _ = await waitUntil(timeout: .seconds(10)) { Self.walk(view).contains { $0.accessibilityRole() == .link } }
            _ = try await live.page.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<button id=\"n\">New</button>')")
            let started = ContinuousClock.now
            let arrived = await waitUntil(timeout: .seconds(1), tick: .milliseconds(10)) {
                Self.walk(view).contains { $0.accessibilityRole() == .button && $0.accessibilityTitle() == "New" }
            }
            let took = started.duration(to: .now)
            print("ChromiumOOPAccessibilityTests observed: a DOM change showed in the tree after \(took)")
            #expect(arrived, "the new button is not in the tree 1 s after the change")
            let added = Self.walk(view).first { $0.accessibilityRole() == .button && $0.accessibilityTitle() == "New" }
            #expect(added?.accessibilityParent() as? ChromiumAccessibilityElement === root, "its parent is the web area")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aHiddenPageKeepsNoTreeAndItComesBackWhenThePageIsShown() async throws {
        try await withLive { live in
            _ = try #require(await live.root())
            let remote = try #require(live.native.remote)
            let state = try #require(live.connection.browserAccessibility(remote.id))
            #expect(state.sentOn)
            live.page.isHidden = true
            #expect(await waitUntil { !state.sentOn }, "a tab nobody sees builds no tree")
            #expect(await waitUntil { state.mirror.isEmpty }, "and holds none")
            live.page.isHidden = false
            #expect(await waitUntil { state.sentOn })
            let rebuilt = await waitUntil(timeout: .seconds(30)) { !state.mirror.isEmpty }
            let accessibility = live.connection.accessibility
            let counts = "delivered \(accessibility.delivered), dropped \(accessibility.droppedUpdates), sentOn \(state.sentOn), enables \(state.enableMessagesSent)"
            #expect(rebuilt, "shown again, the tree is rebuilt: \(state.mirror.summary), \(counts)")
        }
    }

    /// The carry of D4-40's review: the tree is on while VoiceOver runs, with no query, and goes when it stops.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func whileVoiceOverRunsTheTreeIsOnWithNoQueryAndAfterItStopsAndTheGraceIsOverTheMirrorEmpties() async throws {
        try await withLive { live in
            live.connection.accessibility.policy = CefRemoteAccessibilityPolicy(graceSeconds: 1)
            let remote = try #require(live.native.remote)
            let state = try #require(live.connection.browserAccessibility(remote.id))
            live.connection.voiceOverChanged(true)
            #expect(await waitUntil(timeout: .seconds(30)) { !state.mirror.isEmpty }, "VoiceOver runs: the tree is built without a query")
            live.connection.voiceOverChanged(false)
            #expect(await waitUntil { !state.sentOn && state.mirror.isEmpty }, "VoiceOver stopped and nothing asked: the tree is off and the mirror empty")
        }
    }

    /// The plan's test: after the service dies the mirror empties, and the reloaded page fills a new one.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func afterTheServiceDiesTheMirrorEmptiesAndTheReloadedPageFillsANewOne() async throws {
        let live = try await live()
        do {
            let view = try #require(live.view)
            let mirror = try #require(live.mirror)
            _ = try #require(await live.root())
            #expect(!mirror.isEmpty)
            let old = try #require(live.native.remote)
            live.connection.abortService()
            #expect(await waitUntil(timeout: .seconds(20)) { live.native.remote !== old }, "the old browser is gone")
            #expect(await waitUntil { mirror.isEmpty }, "the old mirror was emptied")
            #expect(view.superview == nil && view.accessibilityChildren()?.isEmpty != false, "the old view shows nothing")
            // The tab loads the page again (the replacement service takes up to about 10 s: launchd's throttle).
            let next = try #require(await waitUntil(timeout: .seconds(60)) { live.view != nil && live.view !== view && live.mirror != nil } ? live.view : nil)
            let root = try #require(await live.root(), "no tree after the reload")
            #expect(root.accessibilityTitle() == "AX")
            #expect(next.accessibilityChildren()?.isEmpty == false)
            #expect(live.mirror !== mirror)
        } catch {
            await live.finish()
            throw error
        }
        await live.finish()
    }
}

/// Counts what a decode call told its two closures.
private nonisolated final class CallCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = 0
    private var oversized = 0

    func deliver() {
        lock.withLock { delivered += 1 }
    }

    func oversize() {
        lock.withLock { oversized += 1 }
    }

    var deliverCount: Int {
        lock.withLock { delivered }
    }

    var oversizeCount: Int {
        lock.withLock { oversized }
    }
}
