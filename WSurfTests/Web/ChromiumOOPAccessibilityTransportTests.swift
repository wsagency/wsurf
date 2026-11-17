// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import os
import Testing
import XPC

@testable import CefKit
@testable import WSurf

/// D4-40: the accessibility transport. The first group needs no service and runs in the default lane: when the tree is wanted
/// (`CefRemoteAccessibilityPolicy`), the decoder, and the hook that registers a browser. The rest is gated per test on
/// `ChromiumServiceBundle.isPresent` (the OOP lane: `Tools/run-chromium-oop-tests.sh ChromiumOOPAccessibilityTransportTests`): the
/// service's `ax.enable` and the fourth connection through raw XPC (`ChromiumServiceClient`), and WSurf's own side (`ChromiumRemote`)
/// against a 2,000-node page. Fixtures on 127.0.0.1 only; nothing here turns on VoiceOver or touches an accessibility setting: the
/// "VoiceOver" of a test is `voiceOverChanged`, a call.
@MainActor
@Suite(.serialized)
struct ChromiumOOPAccessibilityTransportTests {
    init() {
        #if DEBUG
        // As `ChromiumOOPPageTests`: before any Chromium start of this host, so that no test that happens to run first can latch it
        // in process. Without the service the override changes nothing.
        ChromiumOOP.testOverride = true
        #endif
    }

    // MARK: When the tree is wanted (Q12)

    @Test func theTreeIsWantedWhileVoiceOverRunsWhateverTheQueries() {
        var policy = CefRemoteAccessibilityPolicy()
        #expect(!policy.wantsTree(at: 0), "nothing asked for it")
        policy.setVoiceOver(true)
        #expect(policy.wantsTree(at: 0))
        #expect(policy.wantsTree(at: 100_000), "VoiceOver keeps it on for as long as it runs")
        policy.setVoiceOver(false)
        #expect(!policy.wantsTree(at: 100_000), "and it is off the moment VoiceOver stops, with no query behind it")
    }

    @Test func aQueryTurnsTheTreeOnForSixtySecondsAndAnotherQueryStartsThemAgain() {
        var policy = CefRemoteAccessibilityPolicy()
        #expect(policy.graceSeconds == 60)
        policy.noteQuery(at: 10)
        #expect(policy.wantsTree(at: 10))
        #expect(policy.wantsTree(at: 69.9))
        #expect(!policy.wantsTree(at: 70), "60 s after the last query")
        policy.noteQuery(at: 65)
        #expect(policy.wantsTree(at: 124.9), "the second query starts the 60 s again")
        #expect(!policy.wantsTree(at: 125))
        #expect(policy.secondsUntilQueryGraceEnds(at: 100) == 25)
        #expect(policy.secondsUntilQueryGraceEnds(at: 125) == nil, "nothing to look at again once it is over")
    }

    @Test func aQueryWhileVoiceOverRunsLeavesTheTreeOnAfterVoiceOverStopsOnlyForItsGrace() {
        var policy = CefRemoteAccessibilityPolicy()
        policy.setVoiceOver(true)
        policy.noteQuery(at: 5)
        policy.setVoiceOver(false)
        #expect(policy.wantsTree(at: 30), "the query's grace still holds")
        #expect(!policy.wantsTree(at: 65))
    }

    @Test func noQueryMeansNoGraceToLookAtAgain() {
        var policy = CefRemoteAccessibilityPolicy()
        #expect(policy.secondsUntilQueryGraceEnds(at: 0) == nil)
        policy.setVoiceOver(true)
        #expect(policy.secondsUntilQueryGraceEnds(at: 0) == nil)
    }

    // MARK: The decoder

    private static let treeJSON = """
        {"ax_tree_id":"tree-1","updates":[{"root_id":1,"nodes":[{"id":1,"role":"rootWebArea","child_ids":[2,3]},
        {"id":2,"role":"button","attributes":{"name":"Press"}},{"id":3,"role":"heading"}]}]}
        """

    private static func message(_ op: String, _ json: String, browser: Int64 = 7) -> CefRemoteMessage {
        let message = CefRemoteMessage(op, browser: browser)
        message.set(CefRemote.Key.data, data: Data(json.utf8))
        return message
    }

    /// Runs the decoder on its own queue, as the accessibility connection does, and returns what it delivered.
    private func decodeOnItsQueue(_ decoder: ChromiumAccessibilityDecoder, _ messages: [CefRemoteMessage]) -> [ChromiumAccessibilityUpdate] {
        let delivered = OSAllocatedUnfairLock(initialState: [ChromiumAccessibilityUpdate]())
        for message in messages {
            decoder.queue.async {
                decoder.decode(.message(message)) { update in delivered.withLock { $0.append(update) } }
            }
        }
        decoder.queue.sync {}
        return delivered.withLock { $0 }
    }

    @Test func aTreeUpdateIsParsedOnTheDecodeQueueAndNamesItsTreeNodesAndRoot() {
        let decoder = ChromiumAccessibilityDecoder()
        let updates = decodeOnItsQueue(decoder, [Self.message(CefRemote.Event.accessibilityTree, Self.treeJSON)])
        #expect(updates.count == 1)
        let update = updates.first
        #expect(update?.kind == .tree)
        #expect(update?.browser == 7)
        #expect(update?.treeID == "tree-1")
        #expect(update?.nodeCount == 3)
        #expect(update?.rootID == 1)
        #if DEBUG
        #expect(decoder.statistics.decodedOffMain == 1 && decoder.statistics.decodedOnMain == 0, "decoded on the queue, not on the main thread")
        #endif
    }

    @Test func theDecodersProbeSeesADecodeThatRunsOnTheMainThread() {
        // The probe the transport's off-main test relies on must itself tell the two apart: a decode made here, on the main thread,
        // is counted as one.
        let decoder = ChromiumAccessibilityDecoder()
        decoder.decode(.message(Self.message(CefRemote.Event.accessibilityTree, Self.treeJSON))) { _ in }
        #if DEBUG
        #expect(decoder.statistics.decodedOnMain == 1)
        #expect(decoder.statistics.decodedOffMain == 0)
        #endif
    }

    @Test func aLocationUpdateIsAListAndAMessageThatIsNeitherIsCountedAndNotDelivered() {
        let decoder = ChromiumAccessibilityDecoder()
        let updates = decodeOnItsQueue(decoder, [
            Self.message(CefRemote.Event.accessibilityLocation, #"[{"ax_tree_id":"tree-1","id":2,"new_location":{"bounds":{}}}]"#),
            Self.message(CefRemote.Event.accessibilityTree, "not json"),
            Self.message(CefRemote.Event.accessibilityTree, #"{"updates":[]}"#),
            Self.message(CefRemote.Event.accessibilityLocation, #"{"a":1}"#),
            Self.message(CefRemote.Event.address, #"{"ax_tree_id":"x","updates":[]}"#),
        ])
        #expect(updates.map(\.kind) == [.location])
        #expect(decoder.statistics.decoded == 1)
        #expect(decoder.statistics.undecodable == 4)
    }

    // MARK: The hook of a browser

    /// A page whose browser is a recorder's (no service), as `ChromiumOOPPageTests` makes one.
    @Test func aBrowserIsRegisteredWithTheTransportWhenItIsCreatedAndLeavesItWhenItCloses() async {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-ax-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
        connection.accessibility.voiceOverSource = { false }
        let remote = ChromiumRemoteBrowser(page: native, connection: connection)
        remote.outgoing = { _ in true }
        native.remote = remote
        #expect(connection.browserAccessibility(remote.id) == nil, "not in the service yet")
        remote.markCreated()
        #expect(connection.browserAccessibility(remote.id) != nil)
        #expect(connection.accessibilityIsOn == false && !connection.hasAccessibilityConnection, "nothing wants the tree, so no connection is made")
        remote.remoteEvent(CefRemoteMessage(CefRemote.Event.browserClosed, browser: remote.id))
        #expect(connection.browserAccessibility(remote.id) == nil)
        connection.disconnect()
        await page.close()
        await context.endPrivateSession()
    }

    // MARK: The service, through raw XPC

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/ax": .html("""
            <!doctype html><title>AX</title><body>
            <h1>Heading</h1><button id="b" onclick="document.title='pressed'">Press</button><p>Some text</p><a href="/ax">Link</a>
            </body>
            """),
        // 2,000 links: several thousand nodes, a first update of several MB.
        "/big": .html("<!doctype html><title>Big</title><body><ul>"
            + (0..<2000).map { "<li><a href=\"#n\($0)\">Link number \($0)</a></li>" }.joined() + "</ul></body>"),
    ]

    /// A started service with a request context, a fixture server, and a second connection that stands in for WSurf's accessibility
    /// connection (not attached until `attachAccessibility`).
    private struct Rig {
        let client: ChromiumServiceClient
        let ax: ChromiumServiceClient
        let server: HTTPFixtureServer

        func url(_ path: String) throws -> String {
            try server.url(path).absoluteString
        }

        /// The accessibility hello, answered by the service: true when it attached this connection.
        @discardableResult
        func attachAccessibility() throws -> Bool {
            try ax.call(CefRemoteMessage(CefRemote.Op.axHello)).bool(CefRemote.Key.success)
        }

        func finish() {
            ax.close()
            client.finish()
        }
    }

    private static func rig() async throws -> Rig {
        let server = try await HTTPFixtureServer.start(routes: routes, waitsForBody: true)
        let client = try ChromiumServiceClient()
        client.hostAnswersQuestions = true
        let reply = try client.hello()
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        try client.context("profile")
        return Rig(client: client, ax: try ChromiumServiceClient(root: client.root), server: server)
    }

    private static func open(_ rig: Rig, _ id: Int64, _ path: String) throws {
        let reply = try rig.client.createBrowser(id, url: rig.url(path), context: "profile")
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        #expect(rig.client.waitEvent(CefRemote.Event.browserReady) { $0.browser == id } != nil, "browser.ready")
        #expect(rig.client.waitEvent(CefRemote.Event.loadEnd) { $0.browser == id } != nil, "load.end")
    }

    private static func enable(_ rig: Rig, _ id: Int64, _ flag: Bool) throws -> CefRemoteMessage {
        try rig.client.command(CefRemote.Op.accessibility, browser: id) { $0.set(CefRemote.Key.flag, flag) }
    }

    private static func treeUpdates(_ rig: Rig) -> [CefRemoteMessage] {
        rig.ax.events(CefRemote.Event.accessibilityTree)
    }

    /// The nodes of every update in `updates`, in order.
    private static func nodes(_ updates: [CefRemoteMessage]) -> [[String: Any]] {
        updates.flatMap { update -> [[String: Any]] in
            let object = (try? JSONSerialization.jsonObject(with: update.data(CefRemote.Key.data))) as? [String: Any]
            return ((object?["updates"] as? [[String: Any]]) ?? []).flatMap { ($0["nodes"] as? [[String: Any]]) ?? [] }
        }
    }

    private static func name(of node: [String: Any]) -> String? {
        (node["attributes"] as? [String: Any])?["name"] as? String
    }

    /// Waits until no more tree updates arrive for `quiet` seconds (at most `limit`): the count then.
    private static func settledCount(_ rig: Rig, quiet: TimeInterval = 0.7, limit: TimeInterval = 8) -> Int {
        let deadline = Date().addingTimeInterval(limit)
        var count = treeUpdates(rig).count
        var stableSince = Date()
        while Date() < deadline, Date().timeIntervalSince(stableSince) < quiet {
            usleep(50_000)
            let now = treeUpdates(rig).count
            if now != count {
                count = now
                stableSince = Date()
            }
        }
        return count
    }

    /// A change the page's accessibility tree must show: the button's text, through CDP (a service command, not page input).
    private static func changeTheButton(_ rig: Rig, to text: String, command: Int64) {
        let reply = rig.client.devTools(
            "Runtime.evaluate", params: #"{"expression":"document.getElementById('b').textContent = '\#(text)'"}"#, id: command, browser: 1)
        #expect(reply != nil, "the DOM change was answered")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func enablingTheTreeGivesATreeUpdateWithARootOnTheAccessibilityConnectionAndNotOnTheControlConnection() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        // WSurf's order: the browser exists, then the connection attaches (which switches off what is on: nothing yet), then the
        // tree is turned on.
        try Self.open(rig, 1, "/ax")
        #expect(try rig.attachAccessibility())
        let reply = try Self.enable(rig, 1, true)
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        let first = try #require(rig.ax.waitEvent(CefRemote.Event.accessibilityTree) { $0.browser == 1 }, "a tree update on the accessibility connection")
        let object = try #require((try? JSONSerialization.jsonObject(with: first.data(CefRemote.Key.data))) as? [String: Any])
        #expect(object["ax_tree_id"] is String)
        let updates = try #require(object["updates"] as? [[String: Any]])
        #expect(!updates.isEmpty)
        let root = try #require(updates.compactMap { $0["root_id"] as? Int }.first, "an update that names the root")
        // Once the page's tree is in (the root and the rest may come in more than one update), the fixture's own nodes are there.
        let deadline = Date().addingTimeInterval(10)
        var all = Self.nodes(Self.treeUpdates(rig))
        while !all.contains(where: { Self.name(of: $0) == "Press" }), Date() < deadline {
            usleep(50_000)
            all = Self.nodes(Self.treeUpdates(rig))
        }
        #expect(all.contains { ($0["id"] as? Int) == root }, "the root is one of the nodes sent")
        #expect(all.contains { $0["role"] as? String == "heading" }, "the heading, with the roles as strings: \(all.compactMap { $0["role"] as? String })")
        #expect(all.contains { $0["role"] as? String == "button" && Self.name(of: $0) == "Press" }, "the button and its name")
        #expect(rig.client.events(CefRemote.Event.accessibilityTree).isEmpty, "the tree never travels on the control connection")
        #expect(rig.client.events(CefRemote.Event.accessibilityLocation).isEmpty)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func enablingTheTreeIsRefusedWhileNoAccessibilityConnectionIsAttachedAndDisablingAndUnknownBrowsersAreAnswered() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try Self.open(rig, 1, "/ax")
        let refused = try Self.enable(rig, 1, true)
        #expect(!refused.bool(CefRemote.Key.success))
        #expect(refused.string(CefRemote.Key.error) == "no accessibility connection", "the first update would have gone nowhere")
        #expect(try Self.enable(rig, 1, false).bool(CefRemote.Key.success), "turning it off needs no connection")
        let unknown = try Self.enable(rig, 99, false)
        #expect(!unknown.bool(CefRemote.Key.success) && unknown.string(CefRemote.Key.error) == "no such browser")
        try rig.attachAccessibility()
        usleep(1_000_000)
        #expect(Self.treeUpdates(rig).isEmpty, "nothing was turned on, so nothing is sent")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func disablingTheTreeStopsTheUpdatesAndEnablingAgainBringsThemBack() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachAccessibility()
        try Self.open(rig, 1, "/ax")
        #expect(try Self.enable(rig, 1, true).bool(CefRemote.Key.success))
        #expect(rig.ax.waitEvent(CefRemote.Event.accessibilityTree) != nil)
        _ = Self.settledCount(rig)
        #expect(try Self.enable(rig, 1, false).bool(CefRemote.Key.success))
        // An update that was already on its way when the tree was turned off may still arrive.
        let quiet = Self.settledCount(rig, quiet: 1)
        Self.changeTheButton(rig, to: "Changed while off", command: 1001)
        usleep(1_500_000)
        #expect(Self.treeUpdates(rig).count == quiet, "a DOM change after `ax.enable(false)` sent \(Self.treeUpdates(rig).count - quiet) update(s)")
        // And it comes back. (The behaviour this PR depends on: CEF's tree-only mode can be turned off and on again.)
        #expect(try Self.enable(rig, 1, true).bool(CefRemote.Key.success))
        Self.changeTheButton(rig, to: "Changed after on", command: 1002)
        let deadline = Date().addingTimeInterval(15)
        while !Self.nodes(Array(Self.treeUpdates(rig).dropFirst(quiet))).contains(where: { Self.name(of: $0) == "Changed after on" }), Date() < deadline {
            usleep(50_000)
        }
        let after = Self.nodes(Array(Self.treeUpdates(rig).dropFirst(quiet)))
        #expect(after.contains { Self.name(of: $0) == "Changed after on" }, "updates after turning it on again: \(after.count) nodes")
    }

    /// What D4-41's mirror depends on: a tree that is turned off and on again starts from nothing, so Chromium must send the whole tree
    /// again with no change in the page to prompt it (a mirror that was emptied while the tree was off cannot use incremental updates).
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func turningTheTreeOffAndOnAgainSendsTheWholeTreeAgainWithNoChangeInThePage() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachAccessibility()
        try Self.open(rig, 1, "/ax")
        #expect(try Self.enable(rig, 1, true).bool(CefRemote.Key.success))
        #expect(rig.ax.waitEvent(CefRemote.Event.accessibilityTree) != nil)
        let first = Self.settledCount(rig)
        let firstNodes = Self.nodes(Self.treeUpdates(rig)).count
        #expect(try Self.enable(rig, 1, false).bool(CefRemote.Key.success))
        let off = Self.settledCount(rig, quiet: 1)
        #expect(try Self.enable(rig, 1, true).bool(CefRemote.Key.success))
        let deadline = Date().addingTimeInterval(15)
        while Self.treeUpdates(rig).count == off, Date() < deadline {
            usleep(50_000)
        }
        _ = Self.settledCount(rig)
        let again = Self.nodes(Array(Self.treeUpdates(rig).dropFirst(off)))
        let updates = Array(Self.treeUpdates(rig).dropFirst(off))
        let named = again.compactMap { Self.name(of: $0) }
        let roots = updates.compactMap { update in
            ((try? JSONSerialization.jsonObject(with: update.data(CefRemote.Key.data))) as? [String: Any])
                .flatMap { ($0["updates"] as? [[String: Any]])?.compactMap { $0["root_id"] as? Int }.first }
        }
        print("ChromiumOOPAccessibilityTransportTests observed: the first tree \(first) updates / \(firstNodes) nodes; after off and on, \(updates.count) updates / \(again.count) nodes, roots \(roots), names \(named)")
        #expect(!updates.isEmpty, "no update at all after turning it on again")
        #expect(again.count >= firstNodes, "the whole tree again: \(again.count) nodes, \(firstNodes) the first time")
        #expect(named.contains("Press") && again.contains { $0["role"] as? String == "heading" }, "the page's own nodes: \(named)")
        #expect(!roots.isEmpty, "an update that names the root")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anAccessibilityHelloBeforeTheControlHelloIsRefusedAndSoIsOneFromTheControlConnection() async throws {
        // A hello that failed (a root that is not canonical) leaves a control connection behind: it must not be a host either.
        let alias = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-ax-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: alias) }
        let early = try ChromiumServiceClient(root: alias)
        defer { early.close() }
        let before = try early.call(CefRemoteMessage(CefRemote.Op.axHello))
        #expect(!before.bool(CefRemote.Key.success), "no hello yet")
        #expect(before.string(CefRemote.Key.error) == "no host has said hello")
        let client = try ChromiumServiceClient(root: alias)
        defer { client.finish(expectExit: false) }
        #expect(!(try client.hello().bool(CefRemote.Key.success)), "the alias root is refused")
        let side = try ChromiumServiceClient(root: alias)
        defer { side.close() }
        #expect(!(try side.call(CefRemoteMessage(CefRemote.Op.axHello)).bool(CefRemote.Key.success)), "attached to a host whose CEF never started")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anAccessibilityHelloFromTheControlConnectionIsRefusedAndOneFromTheHostsOtherConnectionIsAttached() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        let fromControl = try rig.client.call(CefRemoteMessage(CefRemote.Op.axHello))
        #expect(!fromControl.bool(CefRemote.Key.success))
        #expect(fromControl.string(CefRemote.Key.error).contains("control connection"))
        #expect(try rig.attachAccessibility(), "the host's own process may attach one")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aSecondAccessibilityConnectionReplacesTheFirstAndStartsFromNoTree() async throws {
        let rig = try await Self.rig()
        defer { rig.finish() }
        try rig.attachAccessibility()
        try Self.open(rig, 1, "/ax")
        #expect(try Self.enable(rig, 1, true).bool(CefRemote.Key.success))
        #expect(rig.ax.waitEvent(CefRemote.Event.accessibilityTree) != nil)
        _ = Self.settledCount(rig)
        let second = try ChromiumServiceClient(root: rig.client.root)
        defer { second.close() }
        #expect(try second.call(CefRemoteMessage(CefRemote.Op.axHello)).bool(CefRemote.Key.success))
        let firstCount = Self.treeUpdates(rig).count
        Self.changeTheButton(rig, to: "Replaced", command: 1001)
        usleep(1_500_000)
        #expect(second.events(CefRemote.Event.accessibilityTree).isEmpty, "the new connection starts from no tree: nothing is on until it asks")
        #expect(Self.treeUpdates(rig).count == firstCount, "and the replaced connection gets nothing more")
        let enabled = try Self.enable(rig, 1, true)
        #expect(enabled.bool(CefRemote.Key.success))
        Self.changeTheButton(rig, to: "Replaced again", command: 1002)
        #expect(second.waitEvent(CefRemote.Event.accessibilityTree) != nil, "once it asks, the new connection gets the tree")
    }

    // MARK: WSurf's own side, against the service

    private static let helloTimeout: TimeInterval = 30

    private func makeRemote(grace: TimeInterval? = nil) throws -> (remote: ChromiumRemote, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-axremote-\(UUID().uuidString)", directoryHint: .isDirectory)
        let canonical = try ChromiumRemote.prepareRoot(root)
        let remote = ChromiumRemote(
            sink: ChromiumFrameSink(), root: { canonical }, helloTimeout: Self.helloTimeout,
            clock: { ProcessInfo.processInfo.systemUptime }, latch: ChromiumOOP.Latch(), isEnabled: { true })
        // What the person's VoiceOver does must not decide a test (`NSWorkspace.isVoiceOverEnabled` is the real one's source).
        remote.accessibility.voiceOverSource = { false }
        if let grace {
            remote.accessibility.policy = CefRemoteAccessibilityPolicy(graceSeconds: grace)
        }
        return (remote, canonical)
    }

    /// Ends the test so that no service instance outlives it (the next test needs a fresh one).
    private func finish(_ remote: ChromiumRemote) async {
        let pid = remote.servicePID
        remote.disconnect()
        guard pid > 0 else { return }
        // Not a blocking poll: the control connection's teardown runs on the main queue, which must be free to do it.
        let gone = await waitUntil(timeout: .seconds(8)) { kill(pid, 0) == -1 && errno == ESRCH }
        if !gone {
            Issue.record("the service \(pid) did not leave after its connection closed")
        }
    }

    /// A browser at `path` in a running service, registered with the transport as `ChromiumRemoteBrowser.markCreated` does, after
    /// its page has loaded.
    private func browser(_ remote: ChromiumRemote, handle: ChromiumRemoteClientTests.Handle, url: URL) async throws -> Int64 {
        _ = remote.connect()
        try #require(await waitUntil(timeout: .seconds(45)) { remote.isRunning }, "no hello: \(remote.state): \(remote.lastRefusalText)")
        let profile = UUID()
        try #require(await remote.ensureContext(id: profile, cacheDirectory: nil))
        let id = remote.makeBrowser(handle)
        let message = CefRemoteMessage(CefRemote.Op.createBrowser, browser: id)
        message.set(CefRemote.Key.context, profile.uuidString)
        message.set(CefRemote.Key.url, url.absoluteString)
        message.set(CefRemote.Key.width, 800.0)
        message.set(CefRemote.Key.height, 600.0)
        message.set(CefRemote.Key.scale, 1.0)
        guard case let .value(reply) = await remote.request(message), reply.bool(CefRemote.Key.success) else {
            Issue.record("browser.create failed")
            throw CancellationError()
        }
        remote.accessibilityBrowserCreated(id)
        try #require(await waitUntil(timeout: .seconds(30)) { handle.events.contains(CefRemote.Event.loadEnd) }, "the page loaded")
        return id
    }

    /// Records how long the main thread went without running a task that asked to run every 2 ms.
    private final class MainGapProbe {
        private var task: Task<Void, Never>?
        private(set) var longestMs = 0.0

        func start() {
            task = Task { @MainActor in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(2))
                    let now = ContinuousClock.now
                    let gap = last.duration(to: now)
                    longestMs = max(longestMs, Double(gap.components.seconds) * 1000 + Double(gap.components.attoseconds) / 1e15)
                    last = now
                }
            }
        }

        func stop() {
            task?.cancel()
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theFirstUpdateOfA2000NodePageIsDecodedOffTheMainThreadAndHandedToTheBrowser() async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let (remote, _) = try makeRemote()
        let handle = ChromiumRemoteClientTests.Handle()
        let id: Int64
        do {
            id = try await browser(remote, handle: handle, url: server.url("/big"))
        } catch {
            await finish(remote)
            throw error
        }
        #expect(remote.accessibilityIsOn == false && !remote.hasAccessibilityConnection, "nothing asked yet: no tree, no connection")
        let probe = MainGapProbe()
        probe.start()
        remote.noteAccessibilityQuery()
        let arrived = await waitUntil(timeout: .seconds(30)) { (remote.browserAccessibility(id)?.treeUpdates ?? 0) >= 1 }
        // Everything the page sent while the first one was decoded is in.
        try? await Task.sleep(for: .seconds(1))
        probe.stop()
        #expect(arrived, "no update: wanted \(remote.accessibility.wantsTree), attached \(remote.accessibility.isAttached)")
        let state = try #require(remote.browserAccessibility(id))
        #expect(state.nodesReceived >= 2000, "the first updates carry the page: \(state.nodesReceived) nodes in \(state.treeUpdates) updates")
        #expect(state.mirror.nodeCount >= 2000, "the updates were applied to the browser's mirror: \(state.mirror.nodeCount) nodes")
        #expect(state.largestTreeBytes > 100_000, "a big first update: \(state.largestTreeBytes) bytes")
        let statistics = remote.accessibility.decoder.statistics
        #expect(statistics.decoded >= 1)
        #expect(statistics.undecodable == 0)
        #if DEBUG
        #expect(statistics.decodedOnMain == 0, "\(statistics.decodedOnMain) of \(statistics.decoded) updates were decoded on the main thread")
        #expect(statistics.decodedOffMain == statistics.decoded)
        #endif
        #expect(remote.accessibility.delivered >= 1 && remote.accessibility.droppedUpdates == 0)
        #expect(remote.sideRefusals == 0)
        // Reported, not asserted: a timing line would flake under load, and budgets are never raised.
        print("ChromiumOOPAccessibilityTransportTests observed: \(state.treeUpdates) updates, \(state.nodesReceived) nodes, largest \(state.largestTreeBytes) bytes, "
            + "decode \(String(format: "%.1f", statistics.longestMs)) ms off main, longest main-thread gap \(String(format: "%.1f", probe.longestMs)) ms")
        await finish(remote)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func voiceOverAndTheQueryGraceTurnTheTreeOnAndOffInTheService() async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let (remote, _) = try makeRemote(grace: 2)
        let handle = ChromiumRemoteClientTests.Handle()
        let id: Int64
        do {
            id = try await browser(remote, handle: handle, url: server.url("/ax"))
        } catch {
            await finish(remote)
            throw error
        }
        let state = try #require(remote.browserAccessibility(id))
        // VoiceOver: on while it runs, off when it stops (no query behind it).
        remote.voiceOverChanged(true)
        #expect(await waitUntil(timeout: .seconds(30)) { state.treeUpdates >= 1 }, "VoiceOver running: the tree is built")
        #expect(remote.accessibilityIsOn && state.sentOn)
        remote.voiceOverChanged(false)
        #expect(!remote.accessibilityIsOn && !state.sentOn, "VoiceOver stopped, no query: off at once")
        #expect(state.enableMessagesSent == 2)
        // A query: on, and off again when its grace (2 s here, 60 s in production) is over.
        remote.noteAccessibilityQuery()
        #expect(remote.accessibilityIsOn && state.sentOn)
        #expect(state.enableMessagesSent == 3)
        #expect(await waitUntil(timeout: .seconds(10)) { !remote.accessibilityIsOn }, "off after the grace")
        #expect(!state.sentOn && state.enableMessagesSent == 4)
        // A query during the grace starts it again: one more `ax.enable(false)` only, at the end of the second grace.
        remote.noteAccessibilityQuery()
        try await Task.sleep(for: .seconds(1))
        remote.noteAccessibilityQuery()
        try await Task.sleep(for: .milliseconds(1500))
        #expect(remote.accessibilityIsOn, "1.5 s after the second query, still inside its grace")
        #expect(await waitUntil(timeout: .seconds(10)) { !remote.accessibilityIsOn })
        #expect(state.enableMessagesSent == 6)
        await finish(remote)
    }
}
