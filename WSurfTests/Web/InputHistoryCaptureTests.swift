// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
import LocalAuthentication
import Synchronization
import Testing
import WebKit

@testable import WSurf

/// A key storage whose presence check waits until the test lets it go, so a test can see that recording is stuck somewhere other than
/// on the main actor.
nonisolated final class InputHistoryStalledStorage: AutofillSecureStorage {
    let memory = MemoryAutofillStorage()
    private let gate = DispatchSemaphore(value: 0)
    private let waiting = Mutex(false)

    var isStalled: Bool {
        waiting.withLock { $0 }
    }

    func release() {
        gate.signal()
    }

    func read(service: String, context: LAContext) throws -> Data? {
        try memory.read(service: service, context: context)
    }

    func write(_ data: Data, service: String, context: LAContext) throws {
        try memory.write(data, service: service, context: context)
    }

    func erase(service: String) throws {
        try memory.erase(service: service)
    }

    func exists(service: String) throws -> Bool {
        waiting.withLock { $0 = true }
        gate.wait()
        waiting.withLock { $0 = false }
        return try memory.exists(service: service)
    }
}

/// A page of a real (non-private) profile whose messages the test sends by hand, over a history that keeps its keys in memory.
/// Every value is synthetic.
@MainActor
final class InputHistoryCaptureRig {
    static let secret = "dummy-secret-123"
    static let user = "ada@example.test"

    let harness: InputHistoryHarness
    let profile: Profile
    let context: BrowserProfileContext
    let page: BrowserPage
    let capture: InputHistoryCapture
    let documentID: String
    let main: BrowserFrame

    /// `formModel` installs the form model before the capture, as the tab does, so a real document can run the script.
    init(
        recording: Bool = true, ownsSession: Bool = true, historyOwnsSession: Bool = true, privately: Bool = false,
        formModel: Bool = false, capture shared: InputHistoryCapture? = nil, privateKeys: (any AutofillSecureStorage)? = nil,
        control: @escaping @MainActor () -> Bool = { false }
    ) {
        let harness = InputHistoryHarness(ownsSession: historyOwnsSession, privateKeys: privateKeys)
        let profile: Profile = privately ? .privateBrowsing() : harness.makeProfile()
        let context = BrowserProfileContext(profile: profile)
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(webKit: WKWebView(frame: .zero, configuration: configuration), context: context)
        page.url = URL(string: "https://example.test/login?next=%2Fhome#top")
        page.title = "Sign in"
        let capture = shared ?? InputHistoryCapture(ownsSession: ownsSession, history: { harness.history })
        let documentID = UUID().uuidString.lowercased()
        context.settings.recordsInputHistory = recording
        if formModel {
            page.installScript(AutofillFormScript.source, in: AutofillPage.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }
        capture.install(in: page, isUnderAssistantControl: control)
        self.harness = harness
        self.profile = profile
        self.context = context
        self.page = page
        self.capture = capture
        self.documentID = documentID
        main = Self.frame(documentID: documentID, host: "example.test")
    }

    static func frame(
        documentID: String, host: String, scheme: String = "https", port: Int = 0, isMain: Bool = true, trusted: Bool = true
    ) -> BrowserFrame {
        let address = port == 0 ? "\(scheme)://\(host)/" : "\(scheme)://\(host):\(port)/"
        return BrowserFrame(
            id: isMain ? "main" : "frame-\(documentID)", documentID: documentID, url: URL(string: address)!, isMainFrame: isMain,
            securityOrigin: BrowserSecurityOrigin(protocol: scheme, host: host, port: port), hasTrustedSecurityOrigin: trusted
        )
    }

    func send(_ body: [String: Any], from frame: BrowserFrame? = nil) {
        capture.receive(BrowserScriptMessage(page: page, body: body, frameInfo: frame ?? main, name: InputHistoryCapture.handlerName))
    }

    /// The page script's first message in a document. The capture then knows the document and its frame.
    func ready(documentID: String? = nil, url: String = "https://example.test/login", from frame: BrowserFrame? = nil) {
        send(["action": "ready", "documentID": documentID ?? self.documentID, "url": url], from: frame)
    }

    func commit(
        _ value: String = InputHistoryCaptureRig.secret,
        kind: String = "password",
        field: String = "1",
        username: String = InputHistoryCaptureRig.user,
        label: String = "Password",
        url: String = "https://example.test/login",
        title: String = "Sign in",
        cleared: Bool = false,
        documentID: String? = nil,
        from frame: BrowserFrame? = nil
    ) {
        send([
            "action": "commit", "documentID": documentID ?? self.documentID, "url": url, "title": title, "field": field, "kind": kind,
            "label": label, "value": value, "username": username, "cleared": cleared,
        ], from: frame)
    }

    /// What the store holds once the queued work is done, newest first. Opening needs no prompt: the keys are in memory.
    func entries() async throws -> [InputHistoryEntry] {
        await harness.history.drain(profileID: profile.id)
        guard harness.history.store(for: profile) != nil, FileManager.default.fileExists(atPath: InputHistory.directory(for: profile).path) else {
            return []
        }
        try await harness.history.unlock(profile)
        return harness.history.unlocked[profile.id] ?? []
    }

    func tearDown() async {
        await page.close()
        await harness.history.drain(profileID: profile.id)
        harness.cleanUp()
        if !profile.isPrivate {
            ProfileSettingsStore.forget(profile.id)
            try? await WKWebsiteDataStore.remove(forIdentifier: profile.id)
        }
    }
}

@MainActor
struct InputHistoryCaptureTests {
    private func withRig(
        recording: Bool = true, ownsSession: Bool = true, privately: Bool = false, _ body: (InputHistoryCaptureRig) async throws -> Void
    ) async throws {
        let rig = InputHistoryCaptureRig(recording: recording, ownsSession: ownsSession, privately: privately)
        do {
            try await body(rig)
        } catch {
            await rig.tearDown()
            throw error
        }
        await rig.tearDown()
    }

    // MARK: - What is kept

    @Test func aCommittedFieldIsKeptWithItsPageLabelAndUsername() async throws {
        try await withRig { rig in
            rig.ready()
            rig.commit()
            let entries = try await rig.entries()
            let entry = try #require(entries.first)
            #expect(entries.count == 1)
            #expect(entry.payload.value == InputHistoryCaptureRig.secret)
            #expect(entry.payload.username == InputHistoryCaptureRig.user)
            #expect(entry.payload.kind == .password)
            #expect(entry.payload.label == "Password")
            #expect(entry.payload.title == "Sign in")
            #expect(entry.payload.url == "https://example.test/login")
            #expect(entry.payload.frameOrigin == nil)
        }
    }

    @Test func queryAndFragmentAreNotRecorded() async throws {
        try await withRig { rig in
            rig.ready(url: "https://example.test/reset?token=abc#frag")
            rig.commit(kind: "text", label: "Code", url: "https://example.test/reset/password?token=dummy-token#frag")
            let entry = try #require(try await rig.entries().first)
            #expect(entry.payload.url == "https://example.test/reset/password")
            #expect(!entry.payload.url.contains("token"))
            #expect(!entry.payload.url.contains("frag"))
        }
    }

    @Test func httpPagesAreRecordedAndDefaultPortsAreDropped() async throws {
        try await withRig { rig in
            let frame = InputHistoryCaptureRig.frame(documentID: rig.documentID, host: "router.example.test", scheme: "http", port: 80)
            rig.ready(url: "http://router.example.test:80/login", from: frame)
            rig.commit(url: "http://router.example.test:80/login", from: frame)
            let entry = try #require(try await rig.entries().first)
            #expect(entry.payload.url == "http://router.example.test/login")
        }
    }

    @Test func aSubframeIsKeptUnderTheTabAddressWithItsOwnOrigin() async throws {
        try await withRig { rig in
            let inner = UUID().uuidString.lowercased()
            let frame = InputHistoryCaptureRig.frame(documentID: inner, host: "pay.example.test", isMain: false)
            rig.ready(documentID: inner, url: "https://pay.example.test/form", from: frame)
            rig.commit(url: "https://pay.example.test/form", title: "Frame title", documentID: inner, from: frame)
            let entry = try #require(try await rig.entries().first)
            #expect(entry.payload.url == "https://example.test/login")
            #expect(entry.payload.frameOrigin == "https://pay.example.test")
            // The tab's own title is the page's. A frame's script has no say in it.
            #expect(entry.payload.title == "Sign in")
        }
    }

    @Test func theNextCommitOfAFieldReplacesItAndClearingRemovesIt() async throws {
        try await withRig { rig in
            rig.ready()
            rig.commit("first-value")
            rig.commit("second-value")
            let found1 = try await rig.entries()
            #expect(found1.map(\.payload.value) == ["second-value"])
            rig.commit("", cleared: true)
            let found2 = try await rig.entries()
            #expect(found2.isEmpty)
        }
    }

    @Test func retentionFollowsTheSetting() async throws {
        try await withRig { rig in
            rig.context.settings.inputHistoryRetention = .twoHours
            rig.ready()
            rig.commit()
            let entry = try #require(try await rig.entries().first)
            let lifetime = try #require(entry.expiresAt).timeIntervalSince(entry.createdAt)
            #expect(lifetime == 2 * 60 * 60)
        }
    }

    // MARK: - What is never kept

    @Test func cardNumbersSecurityCodesAndOneTimeCodesAreDropped() async throws {
        try await withRig { rig in
            rig.ready()
            rig.commit("4111 1111 1111 1111", kind: "text", field: "1", label: "Card number")
            rig.commit("123", kind: "cc-csc", field: "2", label: "CVV")
            rig.commit("123456", kind: "one-time-code", field: "3", label: "Verification code")
            rig.commit("4111 1111 1111 1111", kind: "password", field: "4", username: "")
            let found3 = try await rig.entries()
            #expect(found3.isEmpty)
        }
    }

    @Test func luhnValidNumberInAPlainFieldIsDropped() async throws {
        try await withRig { rig in
            rig.ready()
            for (index, number) in ["4111111111111111", "4111-1111-1111-1111", "378282246310005", "5555 5555 5555 4444"].enumerated() {
                for kind in ["text", "search", "multiline", "email"] {
                    rig.commit(number, kind: kind, field: String(index * 10 + kind.count))
                }
            }
            let found4 = try await rig.entries()
            #expect(found4.isEmpty)
            // A long number that fails the check is an ordinary value.
            rig.commit("1234567890123456", kind: "text", field: "99", label: "Account")
            let found5 = try await rig.entries()
            #expect(found5.map(\.payload.value) == ["1234567890123456"])
        }
    }

    @Test func aUsernameThatLooksLikeACardIsLeftOut() async throws {
        try await withRig { rig in
            rig.ready()
            rig.commit(username: "4111 1111 1111 1111")
            let entry = try #require(try await rig.entries().first)
            #expect(entry.payload.value == InputHistoryCaptureRig.secret)
            #expect(entry.payload.username == nil)
        }
    }

    @Test func excludedSiteAndItsSubdomainsAreDropped() async throws {
        try await withRig { rig in
            rig.context.settings.inputHistoryExcludedSites = ["example.test", "https://bank.example.org/login", "*.shop.example.net"]
            let pages = [
                ("example.test", false), ("www.example.test", false), ("deep.www.example.test", false), ("badexample.test", true),
                ("bank.example.org", false), ("www.bank.example.org", false), ("example.org", true),
                ("shop.example.net", false), ("cart.shop.example.net", false), ("example.net", true),
            ]
            for (index, page) in pages.enumerated() {
                let id = UUID().uuidString.lowercased()
                let frame = InputHistoryCaptureRig.frame(documentID: id, host: page.0)
                rig.ready(documentID: id, url: "https://\(page.0)/login", from: frame)
                rig.commit(field: String(index + 1), url: "https://\(page.0)/login", documentID: id, from: frame)
            }
            let kept = try await rig.entries().map(\.payload.url).sorted()
            #expect(kept == ["https://badexample.test/login", "https://example.net/login", "https://example.org/login"])
        }
    }

    @Test func aFrameOrPageOnTheExclusionListExcludesTheOther() async throws {
        try await withRig { rig in
            rig.context.settings.inputHistoryExcludedSites = ["pay.example.test"]
            let inner = UUID().uuidString.lowercased()
            let frame = InputHistoryCaptureRig.frame(documentID: inner, host: "pay.example.test", isMain: false)
            rig.ready(documentID: inner, url: "https://pay.example.test/form", from: frame)
            rig.commit(url: "https://pay.example.test/form", documentID: inner, from: frame)
            let found6 = try await rig.entries()
            #expect(found6.isEmpty)

            // The page above a frame counts too: its frames are not recorded either.
            rig.context.settings.inputHistoryExcludedSites = ["example.test"]
            let other = UUID().uuidString.lowercased()
            let widget = InputHistoryCaptureRig.frame(documentID: other, host: "widgets.example.org", isMain: false)
            rig.ready(documentID: other, url: "https://widgets.example.org/", from: widget)
            rig.commit(field: "2", url: "https://widgets.example.org/", documentID: other, from: widget)
            let found7 = try await rig.entries()
            #expect(found7.isEmpty)
        }
    }

    @Test func privateContextIsDropped() async throws {
        try await withRig(privately: true) { rig in
            rig.context.settings.recordsInputHistory = true
            // No script and no handler: a private page never reports in, and a forged message is refused all the same.
            let scripts = try #require(rig.page.webKit?.configuration.userContentController.userScripts)
            #expect(!scripts.contains { $0.source.contains("wsurfInputHistory") })
            rig.ready()
            rig.commit()
            #expect(rig.capture.documentCount(in: rig.page) == 0)
            let found8 = try await rig.entries()
            #expect(found8.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: InputHistory.directory(for: rig.profile).path))
        }
    }

    @Test func aNormalPageGetsTheScriptAndTheHandler() async throws {
        try await withRig { rig in
            let scripts = try #require(rig.page.webKit?.configuration.userContentController.userScripts)
            #expect(scripts.filter { $0.source.contains("wsurfInputHistory") }.count == 1)
        }
    }

    @Test func nonHTTPSchemesAreDropped() async throws {
        try await withRig { rig in
            let file = InputHistoryCaptureRig.frame(documentID: rig.documentID, host: "example.test", scheme: "file")
            rig.ready(url: "file:///tmp/form.html", from: file)
            rig.commit(url: "file:///tmp/form.html", from: file)
            #expect(rig.capture.documentCount(in: rig.page) == 0)

            let ftp = InputHistoryCaptureRig.frame(documentID: rig.documentID, host: "example.test", scheme: "ftp")
            rig.ready(url: "ftp://example.test/form", from: ftp)
            rig.commit(url: "ftp://example.test/form", from: ftp)

            // A frame the engine does not vouch for is not trusted, and a page that reports another scheme than its frame is refused.
            let untrusted = InputHistoryCaptureRig.frame(documentID: rig.documentID, host: "example.test", trusted: false)
            rig.ready(from: untrusted)
            rig.ready(url: "javascript:alert(1)")
            rig.ready(url: "http://example.test/login")
            #expect(rig.capture.documentCount(in: rig.page) == 0)
            let found9 = try await rig.entries()
            #expect(found9.isEmpty)
        }
    }

    @Test func oversizedOrUnknownKindMessagesAreDropped() async throws {
        try await withRig { rig in
            rig.ready()
            rig.commit(String(repeating: "a", count: 10_001), kind: "text", field: "1")
            rig.commit(String(repeating: "a", count: 4_097), kind: "password", field: "2")
            rig.commit("hello", kind: "contenteditable", field: "3")
            rig.commit("hello", kind: "richtext", field: "4")
            rig.commit("hello", kind: "", field: "5")
            rig.commit("hello", field: "abc")
            rig.commit("hello", field: "0")
            rig.commit("hello", field: "1234567890")
            rig.commit("hello", field: "")
            rig.commit("hello", documentID: "not-a-document")
            rig.commit("hello", label: String(repeating: "l", count: 2_000))
            rig.commit("hello", url: "https://example.test/" + String(repeating: "p", count: 5_000))
            rig.commit("hello", title: String(repeating: "t", count: 5_000))
            rig.commit("", cleared: false)
            rig.commit("hello", cleared: true)
            rig.send(["action": "commit", "documentID": rig.documentID])
            rig.send(["action": "commit", "documentID": rig.documentID, "url": 5, "field": 1, "kind": 2, "value": 3, "cleared": 4])
            rig.send(["action": "unknown"])
            rig.send(["documentID": rig.documentID])
            let found10 = try await rig.entries()
            #expect(found10.isEmpty)
        }
    }

    @Test func limitsAreInclusive() async throws {
        try await withRig { rig in
            rig.ready()
            rig.commit(String(repeating: "a", count: 10_000), kind: "multiline", field: "1")
            rig.commit(String(repeating: "b", count: 4_096), kind: "password", field: "2")
            let entries = try await rig.entries()
            #expect(entries.count == 2)
            #expect(Set(entries.map(\.payload.value.count)) == [10_000, 4_096])
        }
    }

    @Test func featureOffDropsEverything() async throws {
        try await withRig(recording: false) { rig in
            rig.ready()
            rig.commit()
            rig.commit("", cleared: true)
            let found11 = try await rig.entries()
            #expect(found11.isEmpty)
            // Switching it on later records from then on, and switching it off again stops it.
            rig.context.settings.recordsInputHistory = true
            rig.commit(field: "2")
            let found12 = try await rig.entries()
            #expect(found12.count == 1)
            rig.context.settings.recordsInputHistory = false
            rig.commit(field: "3")
            let found13 = try await rig.entries()
            #expect(found13.count == 1)
        }
    }

    @Test func aSecondCopyOfTheAppRecordsNothing() async throws {
        try await withRig(ownsSession: false) { rig in
            rig.ready()
            rig.commit()
            let found14 = try await rig.entries()
            #expect(found14.isEmpty)
        }
        let rig = InputHistoryCaptureRig(historyOwnsSession: false)
        rig.ready()
        rig.commit()
        let found15 = try await rig.entries()
        #expect(found15.isEmpty)
        await rig.tearDown()
    }

    // MARK: - Who may speak

    @Test func aDocumentThatNeverReportedInIsDropped() async throws {
        try await withRig { rig in
            rig.commit()
            let found16 = try await rig.entries()
            #expect(found16.isEmpty)
        }
    }

    @Test func aFrameCannotSpeakForAnotherOriginOrDocument() async throws {
        try await withRig { rig in
            rig.ready()
            // The same document id from a frame of another origin.
            let stranger = InputHistoryCaptureRig.frame(documentID: rig.documentID, host: "evil.example.test", isMain: false)
            rig.commit(url: "https://evil.example.test/login", from: stranger)
            // A frame whose script reports an address on another host than the frame has.
            rig.commit(url: "https://evil.example.test/login")
            // A subframe reporting as the main frame's document.
            let inner = InputHistoryCaptureRig.frame(documentID: rig.documentID, host: "example.test", isMain: false)
            rig.commit(from: inner)
            // And an attempt to erase the main document's entry from a stranger.
            rig.commit("kept")
            rig.commit("", url: "https://evil.example.test/login", cleared: true, from: stranger)
            let found17 = try await rig.entries()
            #expect(found17.map(\.payload.value) == ["kept"])
        }
    }

    @Test func aFloodOfCommitsIsLimited() async throws {
        try await withRig { rig in
            rig.ready()
            for index in 1...(InputHistoryRules.commitBudget + 40) {
                rig.commit("value-\(index)", kind: "text", field: String(index))
            }
            let entries = try await rig.entries()
            #expect(entries.count == InputHistoryRules.commitBudget)
        }
    }

    @Test func aPageCannotGrowTheListOfDocumentsWithoutBound() async throws {
        try await withRig { rig in
            rig.ready()
            for index in 0..<150 {
                let id = UUID().uuidString.lowercased()
                rig.ready(documentID: id, url: "https://pay\(index).example.test/", from: InputHistoryCaptureRig.frame(
                    documentID: id, host: "pay\(index).example.test", isMain: false
                ))
            }
            #expect(rig.capture.documentCount(in: rig.page) == 100)
            // The main document is the one being typed into, and it stays.
            rig.commit()
            let found18 = try await rig.entries()
            #expect(found18.count == 1)
        }
    }

    // MARK: - Assistant control

    /// A tab that is only a source of the control state. The page the rig sends from has no tab of its own.
    private func withTab(_ body: @MainActor (BrowserTab) async throws -> Void) async throws {
        let tab = BrowserTab(opensBlank: false, context: BrowserProfileContext(profile: .privateBrowsing()))
        try await body(tab)
    }

    private func control(_ on: Bool, by controller: String, _ tab: BrowserTab) {
        if controller == "assistant" {
            tab.setAgentWorking(on)
        } else {
            tab.setExternalAutomationWorking(on)
        }
    }

    @Test(arguments: ["assistant", "connected app"])
    func typingInATabTheAssistantControlsIsNotRecorded(controller: String) async throws {
        try await withTab { tab in
            let rig = InputHistoryCaptureRig(control: { tab.isUnderAssistantControl })
            rig.ready()
            control(true, by: controller, tab)
            #expect(tab.isUnderAssistantControl)
            rig.commit("agent-typed-secret", field: "1")
            rig.commit("", field: "2", cleared: true)
            let during = try await rig.entries()
            #expect(during.isEmpty)

            // When the control ends the person's typing counts again.
            control(false, by: controller, tab)
            #expect(!tab.isUnderAssistantControl)
            rig.commit(field: "3")
            let after = try await rig.entries()
            #expect(after.map(\.payload.value) == [InputHistoryCaptureRig.secret])
            await rig.tearDown()
        }
    }

    @Test func aTabWithNoControlIsNotUnderAssistantControl() async throws {
        try await withTab { tab in
            #expect(!tab.isUnderAssistantControl)
            tab.setAgentWorking(true)
            tab.setExternalAutomationWorking(true)
            #expect(tab.isUnderAssistantControl)
            tab.setAgentWorking(false)
            #expect(tab.isUnderAssistantControl, "a call of a connected app still works on the tab")
            tab.setExternalAutomationWorking(false)
            #expect(!tab.isUnderAssistantControl)
        }
    }

    // MARK: - Reading and threads

    @Test func capturingNeverReadsTheSecretKey() async throws {
        try await withRig { rig in
            rig.ready()
            rig.commit()
            rig.commit("", field: "2", cleared: true)
            rig.commit(field: "3")
            await rig.harness.history.drain(profileID: rig.profile.id)
            let keys = try #require(rig.harness.privateKeys as? MemoryAutofillStorage)
            #expect(keys.readCount == 0)
            #expect(keys.itemCount == 1)
            // Nothing asked for a prompt either: sealing needs only the public key.
            let publicKeys = rig.harness.publicKeys
            #expect(publicKeys.itemCount == 1)
        }
    }

    @Test func recordingRunsOffTheMainActor() async throws {
        let stalled = InputHistoryStalledStorage()
        let rig = InputHistoryCaptureRig(privateKeys: stalled)
        rig.ready()
        rig.commit()
        // The store is stuck in its Keychain call, and this test, which runs on the main actor, is free to wait for that.
        #expect(await waitUntil { stalled.isStalled })
        #expect(rig.harness.history.count(for: rig.profile.id) == 0)
        stalled.release()
        let found = try await waitUntil { try await rig.entries().count == 1 }
        #expect(found)
        await rig.tearDown()
    }

    // MARK: - Rules

    @Test func descriptionsNeverShowAValue() {
        let body: [String: Any] = [
            "documentID": UUID().uuidString.lowercased(), "url": "https://example.test/", "field": "1", "kind": "password",
            "value": InputHistoryCaptureRig.secret, "cleared": false,
        ]
        let commit = InputHistoryRules.commit(from: body)
        #expect(commit != nil)
        #expect(!String(describing: commit).contains(InputHistoryCaptureRig.secret))
        #expect(!String(reflecting: commit).contains(InputHistoryCaptureRig.secret))
    }

    @Test func excludedHostsAcceptWhatPeopleType() {
        let hosts = InputHistoryRules.excludedHosts([
            " Example.TEST ", "https://user:pw@bank.example.org:8443/login?x=1#y", "*.shop.example.net", ".dotted.example",
            "trailing.example.", "[::1]:8080", "", "   ", "https://",
        ])
        #expect(hosts == ["example.test", "bank.example.org", "shop.example.net", "dotted.example", "trailing.example", "::1"])
        #expect(InputHistoryRules.isExcluded("www.example.test", by: hosts))
        #expect(!InputHistoryRules.isExcluded("badexample.test", by: hosts))
        #expect(!InputHistoryRules.isExcluded("example.test.evil.example", by: hosts))
    }

    @Test func addressesDropCredentialsQueryAndFragment() throws {
        let address = try #require(InputHistoryRules.address(URL(string: "https://user:pw@Example.TEST:8443/a/b?x=1#y")))
        #expect(address.location == "https://example.test:8443/a/b")
        #expect(address.host == "example.test")
        #expect(InputHistoryRules.address(URL(string: "https://example.test"))?.location == "https://example.test/")
        #expect(InputHistoryRules.address(URL(string: "http://example.test:80/x"))?.location == "http://example.test/x")
        #expect(InputHistoryRules.address(URL(string: "file:///tmp/x")) == nil)
        #expect(InputHistoryRules.address(URL(string: "about:blank")) == nil)
        #expect(InputHistoryRules.address(nil) == nil)
    }

    // MARK: - Speed

    /// The main actor does a small, bounded amount per message: a few comparisons and one hand-off to the background queue. The
    /// budget is two milliseconds a message: it catches work that does not belong there, such as sealing an entry, not a baseline.
    @Test func handlingAMessageStaysCheap() async throws {
        try await withRig { rig in
            rig.ready()
            // Over the commit budget, so every message after the first 60 stops at the budget check: the validation cost alone.
            let clock = ContinuousClock()
            let count = 2_000
            let elapsed = clock.measure {
                for index in 1...count {
                    rig.commit("value-\(index)", kind: "text", field: String(index % 900 + 1))
                }
            }
            #expect(elapsed < .milliseconds(count * 2), "\(elapsed) for \(count) messages")
        }
    }
}
