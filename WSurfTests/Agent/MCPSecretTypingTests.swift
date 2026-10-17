// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// Test credentials in the Developer tier: where they can be typed, what is refused everywhere else, and that nothing the
/// connection is told afterwards repeats one. Sessions use an in-memory trust store and a real page served on 127.0.0.1.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPSecretTypingTests {
    private static let password = "Zx9-test-Pa$$word!"
    /// Longer than 30 characters, so a control row that cuts its value still shows a prefix of it.
    private static let token = "tok_test_0123456789abcdefghijklmnopqrstuv"
    private static let code = "482916"
    private static let hidden = MCPSecretScrubber.replacement

    /// A login form whose password handler echoes the value everywhere a page can: its text, console, title, address and a
    /// request. The token field is not one WSurf treats as sensitive; typing a secret into it is still allowed.
    private static let loginPage = """
        <!doctype html><title>Login</title>
        <style>
          input { display: block; width: 240px; height: 32px; border: 0; padding: 0; margin: 0 0 8px 0; }
          #pw { background: #f00; color: #fff; }
          #tok { background: #0f0; }
          #plain { width: 240px; height: 32px; background: #00f; }
        </style>
        <input id=user aria-label="Username">
        <input id=pw type=password aria-label="Password">
        <input id=tok aria-label="API token">
        <input id=otp autocomplete="one-time-code" aria-label="Verification code">
        <div id=plain></div>
        <button id=go>Sign in</button>
        <p id=echo></p>
        <script>
          const pw = document.getElementById('pw');
          pw.addEventListener('input', () => {
            document.getElementById('echo').textContent = 'You typed ' + pw.value;
            console.log('login attempt with', pw.value);
            document.title = 'Signed in with ' + pw.value;
            history.replaceState(null, '', '/login?password=' + encodeURIComponent(pw.value));
            fetch('/ping?pw=' + encodeURIComponent(pw.value)).catch(() => {});
          });
        </script>
        """

    private struct Rig {
        let server: HTTPFixtureServer
        let browser: BrowserModel
        let trust: MCPTrustStore
        let session: MCPBrowserSession
        let tab: BrowserTab
        var window: NSWindow?
    }

    /// One shared tab on the login page. `standing` is the paired client's level; `profile` the chosen Developer profile
    /// (the window is in the everyday profile, so `Profile.originalID` is the explicit choice of this window's profile).
    private func makeRig(
        standing: PairedClient.Standing = .developer, profile: UUID? = Profile.originalID,
        paired: Bool = true, thisMac: Bool = true, answer: MCPAccessConsent.Access? = .control,
        html: String = MCPSecretTypingTests.loginPage
    ) async throws -> Rig {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html(html), "/login": .html(html), "/ping": .bytes(Data("ok".utf8), contentType: "text/plain"),
        ])
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(standing, for: client.id)
        try trust.setDeveloperProfile(profile)
        if !thisMac {
            try trust.setIncludesThisMac(false)
        }
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPSecret-\(UUID().uuidString).json")))
        let url = try server.url()
        let tab = browser.newTab(url: url)
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading })
        try #require(await waitUntil { tab.page.mainDocumentID != nil }, "the page registered its main document")
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)
        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true }, consent: { _, _, _ in answer }, openConsent: { _, _ in false })
        if paired {
            session.pairedClient = trust.client(id: client.id)
        }
        var rig = Rig(server: server, browser: browser, trust: trust, session: session, tab: tab)
        rig.window = await show(tab)
        return rig
    }

    private func show(_ tab: BrowserTab) async -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = WebViewContainer(page: tab.page)
        window.contentView = container
        window.orderBack(nil)
        let width = Int(container.bounds.width)
        #expect(
            await waitUntil {
                guard tab.page.superview === container else { return false }
                return (try? await tab.page.evaluateJavaScript("window.innerWidth")) as? Int == width
            }, "the page is laid out at the container's width \(width)")
        return window
    }

    private func close(_ rig: Rig) {
        rig.session.revoke()
        rig.window?.contentView = nil
        rig.window?.close()
        withExtendedLifetime(rig.server) {}
    }

    private func call(_ rig: Rig, _ name: String, _ arguments: [String: Value] = [:], tab: Bool = true) async throws -> CallTool.Result {
        var arguments = arguments
        if tab { arguments["tabID"] = .string(rig.tab.id.uuidString) }
        return try await rig.session.call(name: name, arguments: arguments)
    }

    /// Everything a client could read in `result`: every text block and the structured copy.
    private func everything(_ result: CallTool.Result) -> String {
        let blocks = result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }
        let structured = result.structuredContent.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? ""
        return (blocks + [structured]).joined(separator: "\n")
    }

    private func observation(_ result: CallTool.Result) -> String? {
        result.structuredContent?.objectValue?["observationID"]?.stringValue
    }

    /// The `[ref]` of the field named `label` in a result's page content.
    private func ref(_ label: String, in result: CallTool.Result) throws -> Int {
        let content = try #require(result.structuredContent?.objectValue?["content"]?.stringValue)
        let line = try #require(content.split(separator: "\n").first { $0.contains("field \"\(label)\"") }, "no field \(label) in \(content)")
        return try #require(Int(line.dropFirst().prefix { $0.isNumber }))
    }

    private func value(of id: String, in rig: Rig) async throws -> String {
        try await rig.tab.page.evaluateJavaScript("document.getElementById('\(id)').value") as? String ?? "<none>"
    }

    /// Every way an output could carry `secret`: as typed, in the cases a page may show it, percent-encoded, JSON-escaped,
    /// HTML-escaped, and the 30-character cut a control row shows.
    private func forms(of secret: String) throws -> [String] {
        let json = String(decoding: try JSONEncoder().encode(secret).dropFirst().dropLast(), as: UTF8.self)
        let html = secret.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        var forms = [
            secret, secret.lowercased(), secret.uppercased(), json, html,
            secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? secret,
            secret.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? secret,
        ]
        if secret.count > 30 {
            forms.append(String(secret.prefix(30)))
        }
        return forms
    }

    private func expectNoSecret(in result: CallTool.Result, _ name: String, secrets: [String]) throws {
        let text = everything(result)
        for secret in secrets {
            for form in try forms(of: secret) where form.count >= 6 {
                #expect(!text.contains(form), "\(name) shows a secret as “\(form)”: \(text.prefix(600))")
            }
        }
    }

    // MARK: Where a secret may be typed

    @Test func secretTypingWorksInTheDeveloperTierOnADeveloperSite() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        #expect(try await call(rig, "requestAccess", [:], tab: false).isError == false)
        #expect(rig.session.permits(rig.tab, capability: .developer))
        let read = try await call(rig, "readPage")
        let password = try ref("Password", in: read)

        let typed = try await call(rig, "typeOnPage", ["observationID": .string(try #require(observation(read))), "ref": .int(password), "text": .string(Self.password), "secret": true])

        #expect(typed.isError == false, "\(everything(typed))")
        #expect(try await value(of: "pw", in: rig) == Self.password, "the page holds what was typed")
        #expect(everything(typed).contains("Typed a secret into"))
        #expect(rig.session.secrets.count == 1)
        // A password field the agent filled reads as filled and hidden, like one the user filled.
        #expect(everything(typed).contains("(filled, hidden)"))
        try expectNoSecret(in: typed, "the typing result", secrets: [Self.password])
    }

    enum Refusal: String, CaseIterable, Sendable {
        case controlOnly, notADeveloperSite, unpaired, wrongProfile, readOnlySite
    }

    @Test(arguments: Refusal.allCases)
    func secretTypingIsRefusedOutsideTheDeveloperTier(scenario refusal: Refusal) async throws {
        // Everyone but the control-only client asks for Developer in the sheet; none of them may get it where it does not apply.
        let rig = try await makeRig(
            standing: refusal == .controlOnly ? .off : .developer,
            profile: refusal == .wrongProfile ? UUID() : Profile.originalID,
            paired: refusal != .unpaired, thisMac: refusal != .notADeveloperSite, answer: refusal == .controlOnly ? .control : .developer)
        defer { close(rig) }
        if refusal == .readOnlySite {
            rig.browser.sitePermissions.setAssistantAccess(.readOnly, for: SitePermissions.origin(for: try rig.server.url()))
        }
        _ = try await call(rig, "requestAccess", ["development": true, "developer": true], tab: false)
        #expect(!rig.session.permits(rig.tab, capability: .developer), "\(refusal)")
        // Reading may be blocked too (a Read Only site is not controllable); the typing calls are what must never reach the page.
        let read = try await call(rig, "readPage")
        let observationID = observation(read) ?? "none"
        let password = (try? ref("Password", in: read)) ?? 2

        let typed = try await call(rig, "typeOnPage", ["observationID": .string(observationID), "ref": .int(password), "text": .string(Self.password), "secret": true])
        let filled = try await call(rig, "fillFields", [
            "observationID": .string(observationID),
            "fields": .array([.object(["ref": .int(password), "value": .string(Self.password), "select": false, "secret": true])]),
        ])

        for result in [typed, filled] {
            #expect(result.isError == true, "\(refusal): \(everything(result))")
            #expect(try await value(of: "pw", in: rig) == "", "\(refusal): nothing may reach the field")
        }
        #expect(rig.session.secrets.isEmpty, "\(refusal): a refused secret is not even remembered")
        if refusal != .readOnlySite {
            #expect(everything(typed).contains("Developer access"), "\(refusal): \(everything(typed))")
        }
        try expectNoSecret(in: typed, "the refusal", secrets: [Self.password])
        try expectNoSecret(in: filled, "the batch refusal", secrets: [Self.password])
    }

    @Test func withoutSecretSensitiveFieldsStayRefusedEvenInTheDeveloperTier() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        let first = try await call(rig, "readPage")
        let password = try ref("Password", in: first), code = try ref("Verification code", in: first), username = try ref("Username", in: first)

        for flag in [nil, false] {
            // A refusal returns no observation, so each attempt reads the page first.
            let read = try await call(rig, "readPage")
            var arguments: [String: Value] = [
                "observationID": .string(try #require(observation(read))), "ref": .int(password), "text": .string(Self.password),
            ]
            if let flag {
                arguments["secret"] = .bool(flag)
            }
            let typed = try await call(rig, "typeOnPage", arguments)
            #expect(typed.isError == true, "\(everything(typed))")
            #expect(everything(typed).contains("The user has to fill it themselves"), "today's refusal, unchanged: \(everything(typed))")
        }
        let latest = try await call(rig, "readPage")
        let filled = try await call(rig, "fillFields", [
            "observationID": .string(try #require(observation(latest))),
            "fields": .array([
                .object(["ref": .int(username), "value": "alice", "select": false]),
                .object(["ref": .int(password), "value": .string(Self.password), "select": false]),
                .object(["ref": .int(code), "value": .string(Self.code), "select": false, "secret": false]),
            ]),
        ])
        #expect(everything(filled).contains("Filled 1 of 3"), "\(everything(filled))")
        #expect(everything(filled).contains("sensitive field"))
        #expect(try await value(of: "user", in: rig) == "alice")
        #expect(try await value(of: "pw", in: rig) == "")
        #expect(try await value(of: "otp", in: rig) == "")
        #expect(rig.session.secrets.isEmpty)
    }

    @Test func aSecretMustBeLongEnoughToBeHiddenAndIsRefusedBeforeAnythingIsTyped() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        let read = try await call(rig, "readPage")
        let typed = try await call(rig, "typeOnPage", [
            "observationID": .string(try #require(observation(read))), "ref": .int(try ref("Password", in: read)), "text": "123", "secret": true,
        ])
        #expect(typed.isError == true)
        #expect(everything(typed).contains("at least 4 characters"))
        #expect(try await value(of: "pw", in: rig) == "")
        #expect(rig.session.secrets.isEmpty)
    }

    @Test func aSecretIsTypedOnlyIntoThePageItselfNotIntoAFrame() async throws {
        let framed = """
            <!doctype html><title>Framed</title>
            <iframe id=f srcdoc="<input id=inner type=password aria-label='Inner password'>" style="width:300px;height:60px"></iframe>
            """
        let rig = try await makeRig(html: framed)
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        #expect(await waitUntil { (try? await rig.tab.page.evaluateJavaScript("!!document.getElementById('f').contentDocument?.getElementById('inner')")) as? Bool == true })
        let read = try await call(rig, "readPage")
        let typed = try await call(rig, "typeOnPage", [
            "observationID": .string(try #require(observation(read))), "ref": .int(try ref("Inner password", in: read)),
            "text": .string(Self.password), "secret": true,
        ])
        #expect(typed.isError == true, "\(everything(typed))")
        #expect(everything(typed).contains("not into a frame"))
        let inner = try await rig.tab.page.evaluateJavaScript("document.getElementById('f').contentDocument.getElementById('inner').value")
        #expect(inner as? String == "")
    }

    // MARK: Nothing the connection is told repeats a secret

    @Test func typedSecretsNeverAppearInAnyOutput() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        let secrets = [Self.password, Self.token, Self.code]
        var results: [(String, CallTool.Result)] = []
        func record(_ name: String, _ result: CallTool.Result) {
            results.append((name, result))
        }

        record("requestAccess", try await call(rig, "requestAccess", [:], tab: false))
        let started = try await call(rig, "startDiagnostics")
        #expect(started.structuredContent?.objectValue?["status"]?.stringValue == "ok", "\(everything(started))")
        record("startDiagnostics", started)
        let read = try await call(rig, "readPage")
        record("readPage", read)
        let password = try ref("Password", in: read), tokenRef = try ref("API token", in: read)
        let code = try ref("Verification code", in: read), username = try ref("Username", in: read)

        let typed = try await call(rig, "typeOnPage", ["observationID": .string(try #require(observation(read))), "ref": .int(password), "text": .string(Self.password), "secret": true])
        #expect(typed.isError == false, "\(everything(typed))")
        record("typeOnPage", typed)
        let filled = try await call(rig, "fillFields", [
            "observationID": .string(try #require(observation(typed))),
            "fields": .array([
                .object(["ref": .int(username), "value": "alice", "select": false]),
                .object(["ref": .int(tokenRef), "value": .string(Self.token), "select": false, "secret": true]),
                .object(["ref": .int(code), "value": .string(Self.code), "select": false, "secret": true]),
            ]),
        ])
        #expect(filled.isError == false, "\(everything(filled))")
        #expect(everything(filled).contains("Filled 3 of 3"), "\(everything(filled))")
        record("fillFields", filled)

        // The page did echo the secret everywhere it can, so the scrubbing below has something to hide.
        let echoed = try await rig.tab.page.evaluateJavaScript(
            "[document.getElementById('echo').textContent, document.title, location.search].join('|')") as? String ?? ""
        #expect(echoed.contains(Self.password), "the page echoed into its text and title")
        #expect(echoed.contains("password=Zx9-test-Pa%24%24word!"), "and into its address: \(echoed)")
        #expect(try await value(of: "tok", in: rig) == Self.token)
        #expect(try await value(of: "otp", in: rig) == Self.code)

        record("listTabs", try await call(rig, "listTabs", [:], tab: false))
        let again = try await call(rig, "readPage")
        record("readPage again", again)
        let looked = try await call(rig, "readPage", ["lookingFor": "typed"])
        record("readPage looking for it", looked)
        record("inspectControl", try await call(rig, "inspectControl", ["observationID": .string(try #require(observation(looked))), "ref": .int(tokenRef)]))
        record("screenshotPage", try await call(rig, "screenshotPage"))

        let console = try await waitForRecords(rig, tool: "readConsole", containing: "login attempt")
        record("readConsole", console)
        let network = try await waitForRecords(rig, tool: "readNetwork", containing: "/ping")
        record("readNetwork", network)

        for (name, result) in results {
            try expectNoSecret(in: result, name, secrets: secrets)
        }
        // What was echoed is shown as hidden, not dropped: the replacement proves the registry did the work.
        #expect(everything(again).contains(Self.hidden), "the echoed text is hidden: \(everything(again).prefix(800))")
        #expect(everything(console).contains(Self.hidden), "the echoed console line is hidden: \(everything(console).prefix(800))")
        #expect(everything(try await call(rig, "listTabs", [:], tab: false)).contains("password=\(Self.hidden)"))
        // The in-app activity line names a tool, never an argument.
        #expect(rig.session.lastActionTitle?.contains(Self.password) != true)
        // And so does any text a sibling feature hands the scrubber before storing it.
        #expect(rig.session.scrubbed("tab: Signed in with \(Self.password)") == "tab: Signed in with \(Self.hidden)")
    }

    private func waitForRecords(_ rig: Rig, tool: String, containing needle: String) async throws -> CallTool.Result {
        var last = try await call(rig, tool)
        _ = await waitUntil {
            last = (try? await self.call(rig, tool)) ?? last
            return self.everything(last).contains(needle)
        }
        return last
    }

    @Test func aFormOfASecretThePageStoresIsHiddenToo() async throws {
        // A card field that groups its digits: what it holds and echoes is not the value that was typed.
        let formatted = """
            <!doctype html><title>Card</title>
            <input id=card aria-label="Card number" autocomplete="cc-number">
            <p id=echo></p>
            <script>
              const card = document.getElementById('card');
              card.addEventListener('input', () => {
                card.value = card.value.replace(/\\D/g, '').replace(/(.{4})/g, '$1 ').trim();
                document.getElementById('echo').textContent = 'Card ' + card.value;
              });
            </script>
            """
        let rig = try await makeRig(html: formatted)
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        let read = try await call(rig, "readPage")

        let typed = try await call(rig, "typeOnPage", [
            "observationID": .string(try #require(observation(read))), "ref": .int(try ref("Card number", in: read)),
            "text": "4242424242424242", "secret": true,
        ])

        #expect(try await value(of: "card", in: rig) == "4242 4242 4242 4242")
        #expect(!everything(typed).contains("4242 4242 4242 4242"))
        let again = try await call(rig, "readPage")
        #expect(everything(again).contains("Card \(Self.hidden)"), "the grouped digits the page echoed are hidden: \(everything(again).prefix(600))")
        #expect(!everything(again).contains("4242 4242"))
        #expect(rig.session.secrets.count == 2, "the typed value and the form the page stored")
    }

    // MARK: Records of what the agent did

    /// The Developer tier lets a purchase through without asking and notes it; this is that path with a label of the test's choosing.
    private func approve(_ label: String, in rig: Rig) async -> Bool {
        let policy = AgentActionPolicy(storage: MCPActionGrantStorage())
        return await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, _ in .decline }) {
            await AgentActionConsent.$developerApproval.withValue(rig.session.developerApproval(for: rig.tab)) {
                await AgentActionConsent.permit(label: label, category: .purchase, host: "127.0.0.1", policy: policy)
            }
        }
    }

    private func type(_ text: String, into label: String, secret: Bool?, in rig: Rig) async throws -> CallTool.Result {
        let read = try await call(rig, "readPage")
        var arguments: [String: Value] = [
            "observationID": .string(try #require(observation(read))), "ref": .int(try ref(label, in: read)), "text": .string(text),
        ]
        if let secret {
            arguments["secret"] = .bool(secret)
        }
        return try await call(rig, "typeOnPage", arguments)
    }

    private static let phrase = "Pay $500 to X"

    @Test func aPhraseTypedWithoutTheSecretFlagRegistersNothingSoARecordShowsIt() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)

        let typed = try await type(Self.phrase, into: "Username", secret: nil, in: rig)
        #expect(typed.isError == false, "\(everything(typed))")
        #expect(rig.session.secrets.isEmpty, "only a value the agent marks secret is ever registered")

        #expect(await approve(Self.phrase, in: rig))
        let record = try #require(rig.session.developerApprovals.last)
        #expect(record.label == Self.phrase)
        #expect(record.category == .purchase)
        #expect(record.host == "127.0.0.1")
    }

    @Test func aPhraseRegisteredAsASecretInAnOrdinaryFieldCannotBlankARecord() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)

        let typed = try await type(Self.phrase, into: "Username", secret: true, in: rig)
        #expect(typed.isError == false, "\(everything(typed))")
        #expect(rig.session.secrets.count == 1, "it is hidden from what the agent is told")
        #expect(!everything(try await call(rig, "readPage")).contains(Self.phrase))

        // But the agent chose it, and the record of a purchase it skipped the confirmation for still says what was approved.
        #expect(await approve(Self.phrase, in: rig))
        let record = try #require(rig.session.developerApprovals.last)
        #expect(record.label == Self.phrase, "the record must not be blanked by registering its text: \(record.label)")
        #expect(record.category == .purchase)
        #expect(record.host == "127.0.0.1")
        #expect(rig.session.scrubbedForAudit("tab: \(Self.phrase)") == "tab: \(Self.phrase)")
    }

    @Test func aRealSecretIsHiddenFromTheAgentWhileARecordStillNamesTheAction() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)

        let typed = try await type(Self.password, into: "Password", secret: true, in: rig)
        #expect(typed.isError == false, "\(everything(typed))")
        try expectNoSecret(in: try await call(rig, "readPage"), "the page read", secrets: [Self.password])

        #expect(await approve("Pay with \(Self.password)", in: rig))
        let record = try #require(rig.session.developerApprovals.last)
        #expect(record.label == "Pay with \(MCPSecretScrubber.auditReplacement)", "the secret is hidden and the hiding is visible: \(record.label)")
        #expect(record.category == .purchase)
        #expect(record.host == "127.0.0.1")
        #expect(rig.session.scrubbed("Pay with \(Self.password)") == "Pay with \(Self.hidden)", "the agent's own view uses the other marker")
    }

    @Test func aPhraseTypedIntoAPasswordFieldHidesOnlyItselfAndLeavesAMarkedRecord() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)

        // The page decides which fields are password fields, so a phrase typed into one is a secret field's value like any other.
        let typed = try await type(Self.phrase, into: "Password", secret: true, in: rig)
        #expect(typed.isError == false, "\(everything(typed))")

        #expect(await approve(Self.phrase, in: rig))
        let record = try #require(rig.session.developerApprovals.last)
        #expect(record.label == MCPSecretScrubber.auditReplacement, "a visible marker, never an empty or missing label")
        #expect(record.category == .purchase, "the action's identity stays")
        #expect(record.host == "127.0.0.1")
        #expect(rig.session.developerApprovals.count == 1, "the approval is still on record")
    }

    @Test func aShortSecretNeverHidesRecordText() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)

        let typed = try await type("abc1234", into: "Password", secret: true, in: rig)  // 7 bytes: hidden from the agent, not from records
        #expect(typed.isError == false, "\(everything(typed))")
        #expect(rig.session.secrets.count == 1)
        #expect(await approve("Pay abc1234 now", in: rig))
        #expect(rig.session.developerApprovals.last?.label == "Pay abc1234 now")
        #expect(rig.session.scrubbed("Pay abc1234 now") == "Pay \(Self.hidden) now")
    }

    @Test func aValueThePageChangedIsNotConfirmedUnlessItIsAKnownReformatting() async throws {
        // A page that replaces whatever is typed with a value of its own: not retained, and not a reformatting.
        let replacing = """
            <!doctype html><title>Replace</title>
            <input id=pw type=password aria-label="Password">
            <script>pw.addEventListener('input', () => { pw.value = 'zzzzzzzz'; });</script>
            """
        let replaced = try await makeRig(html: replacing)
        defer { close(replaced) }
        _ = try await call(replaced, "requestAccess", [:], tab: false)
        let typed = try await type(Self.password, into: "Password", secret: true, in: replaced)
        #expect(typed.isError == true, "the page did not keep the value")
        let both = "Pay \(Self.password) zzzzzzzz"
        #expect(await approve(both, in: replaced))
        #expect(replaced.session.developerApprovals.last?.label == both, "neither the typed nor the substituted value is confirmed")
        #expect(replaced.session.scrubbed(both) == "Pay \(Self.hidden) \(Self.hidden)", "both are still hidden from the agent")

        // A page that only groups the digits: the grouped form is a known reformatting, so it is hidden in a record.
        let grouping = """
            <!doctype html><title>Card</title>
            <input id=card aria-label="Card number" autocomplete="cc-number">
            <script>
              card.addEventListener('input', () => { card.value = card.value.replace(/\\D/g, '').replace(/(.{4})/g, '$1 ').trim(); });
            </script>
            """
        let grouped = try await makeRig(html: grouping)
        defer { close(grouped) }
        _ = try await call(grouped, "requestAccess", [:], tab: false)
        _ = try await type("4242424242424242", into: "Card number", secret: true, in: grouped)
        #expect(await approve("Card 4242 4242 4242 4242 / 4242424242424242", in: grouped))
        #expect(
            grouped.session.developerApprovals.last?.label == "Card \(MCPSecretScrubber.auditReplacement) / 4242424242424242",
            "only the grouped form that the page stored is confirmed")
    }

    @Test func onlySpacesDashesAndDotsMakeAReformatting() {
        let reformatting = MCPBrowserSession.isReformatting
        #expect(reformatting("4242 4242 4242 4242", "4242424242424242"))
        #expect(reformatting("4242-4242-4242-4242", "4242 4242 4242 4242"))
        #expect(reformatting("123.456.789", "123456789"))
        #expect(!reformatting("4242424242424242", "4242424242424242"), "nothing changed")
        #expect(!reformatting("zzzzzzzz", "Zx9-test-Pa$$word!"))
        #expect(!reformatting("4242 4242 4242 4243", "4242424242424242"), "a different digit")
        #expect(!reformatting("4242 4242 4242 4242 99", "4242424242424242"), "extra characters")
        #expect(!reformatting("Pay 500", "pay 500"), "case is not spacing")
        #expect(!reformatting("--", ".."), "nothing left to compare")
    }

    @Test func aConfirmedSecretInsideALongerWordIsNotHidden() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        _ = try await type(Self.password, into: "Password", secret: true, in: rig)

        let inside = "prefix\(Self.password)"
        #expect(await approve(inside, in: rig))
        #expect(rig.session.developerApprovals.last?.label == inside, "the secret sits inside a longer word")
        #expect(await approve("Pay with \(Self.password) now", in: rig))
        #expect(rig.session.developerApprovals.last?.label == "Pay with \(MCPSecretScrubber.auditReplacement) now")
    }

    @Test func aPaddedLabelStillShowsTheActionItsHostAndItsEnd() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)

        let padded = String(repeating: "Harmless text. ", count: 80) + "Pay $500 to X now"
        #expect(await approve(padded, in: rig))
        let record = try #require(rig.session.developerApprovals.last)
        #expect(record.category == .purchase, "the classification is a field of its own")
        #expect(record.host == "127.0.0.1")
        #expect(record.amount == "$500", "so is the amount the label states, whatever the padding")
        #expect(record.label.count == MCPBrowserSession.approvalLabelLimit)
        #expect(record.label.hasPrefix("Harmless text."), "the start is kept")
        #expect(record.label.hasSuffix("Pay $500 to X now"), "and the end, where the action is: \(record.label.suffix(40))")
        #expect(record.label.contains("…"))
        #expect(record.labelLength == padded.count && record.isLabelCut)

        // A label within the limit is stored as it is.
        #expect(await approve("Complete purchase (49,90 EUR)", in: rig))
        let short = try #require(rig.session.developerApprovals.last)
        #expect(short.label == "Complete purchase (49,90 EUR)" && !short.isLabelCut)
        #expect(short.amount == "49,90 EUR")
    }

    // MARK: Connection end

    @Test func secretsAreForgottenWhenTheConnectionEnds() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        let read = try await call(rig, "readPage")
        _ = try await call(rig, "typeOnPage", [
            "observationID": .string(try #require(observation(read))), "ref": .int(try ref("Password", in: read)), "text": .string(Self.password), "secret": true,
        ])
        #expect(!rig.session.secrets.isEmpty)
        #expect(!rig.session.secretFields.isEmpty)
        let before = "\(rig.session.secrets) \(String(reflecting: rig.session.secrets))"
        #expect(!before.contains(Self.password))

        rig.session.revoke()

        #expect(rig.session.secrets.isEmpty)
        #expect(rig.session.secretFields.isEmpty)
        #expect(rig.session.secrets.scrub(Self.password) == Self.password, "nothing is left to match, so nothing is kept")
        #expect(try await call(rig, "listTabs", [:], tab: false).isError == true)
        // A result still being computed when the connection ended is dropped, not returned unscrubbed.
        let late = CallTool.Result(content: [.text(text: "Signed in with \(Self.password)", annotations: nil, _meta: nil)], isError: false)
        let finished = rig.session.finished(late)
        #expect(finished.isError == true)
        #expect(!everything(finished).contains(Self.password))
    }

    // MARK: Screenshots

    /// Reads the colour of the image at a point given in CSS pixels.
    private func color(in result: CallTool.Result, at point: CGPoint, scale: CGFloat) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let data = try #require(result.content.compactMap { block -> Data? in
            guard case .image(let base64, _, _, _) = block else { return nil }
            return Data(base64Encoded: base64)
        }.first, "the capture returned an image")
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let x = min(bitmap.pixelsWide - 1, Int(point.x * scale)), y = min(bitmap.pixelsHigh - 1, Int(point.y * scale))
        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    private func center(of id: String, in rig: Rig) async throws -> CGPoint {
        let box = try #require(try await rig.tab.page.evaluateJavaScript(
            "(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()") as? [Double])
        return CGPoint(x: box[0], y: box[1])
    }

    @Test func developerScreenshotsCoverFilledSensitiveFieldsAndFieldsATypedSecretWentInto() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        let read = try await call(rig, "readPage")
        let typed = try await call(rig, "typeOnPage", [
            "observationID": .string(try #require(observation(read))), "ref": .int(try ref("Password", in: read)), "text": .string(Self.password), "secret": true,
        ])
        let token = try await call(rig, "typeOnPage", [
            "observationID": .string(try #require(observation(typed))), "ref": .int(try ref("API token", in: typed)), "text": .string(Self.token), "secret": true,
        ])
        #expect(token.isError == false, "\(everything(token))")

        let shot = try await call(rig, "screenshotPage")
        #expect(shot.isError == false, "\(everything(shot))")
        let width = try #require(try await rig.tab.page.evaluateJavaScript("window.innerWidth") as? Int)
        let image = try #require(shot.content.compactMap { block -> Data? in
            guard case .image(let base64, _, _, _) = block else { return nil }
            return Data(base64Encoded: base64)
        }.first)
        let scale = CGFloat(try #require(NSBitmapImageRep(data: image)).pixelsWide) / CGFloat(width)

        let password = try color(in: shot, at: try await center(of: "pw", in: rig), scale: scale)
        let covered = try color(in: shot, at: try await center(of: "tok", in: rig), scale: scale)
        let plain = try color(in: shot, at: try await center(of: "plain", in: rig), scale: scale)
        #expect(password.red < 0.15 && password.green < 0.15 && password.blue < 0.15, "the password field is black, not red: \(password)")
        #expect(covered.red < 0.15 && covered.green < 0.15 && covered.blue < 0.15, "the token field is black, not green: \(covered)")
        #expect(plain.blue > 0.6 && plain.red < 0.3 && plain.green < 0.3, "the rest of the page is untouched: \(plain)")
        try expectNoSecret(in: shot, "the screenshot reply", secrets: [Self.password, Self.token])
    }

    @Test func outsideTheDeveloperTierAFilledSensitiveFieldStillPreventsTheCapture() async throws {
        let rig = try await makeRig(standing: .development)
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        _ = try await rig.tab.page.evaluateJavaScript("document.getElementById('pw').value = 'filled-by-the-user'; 0")
        let shot = try await call(rig, "screenshotPage")
        #expect(shot.isError == true)
        #expect(everything(shot).contains("Screenshot refused"))
        #expect(!shot.content.contains { if case .image = $0 { return true } else { return false } })
    }

    // MARK: The vault

    @Test func theVaultIsNeverOfferedOrSavedForAgentTypedFields() async throws {
        let rig = try await makeRig()
        defer { close(rig) }
        _ = try await call(rig, "requestAccess", [:], tab: false)
        let read = try await call(rig, "readPage")
        let username = try ref("Username", in: read), password = try ref("Password", in: read)
        let origin = SitePermissions.origin(for: try rig.server.url())

        // An ordinary typed value focuses its field, as always; that is what opens autofill suggestions on an https page.
        let plain = try await call(rig, "typeOnPage", ["observationID": .string(try #require(observation(read))), "ref": .int(username), "text": "alice"])
        #expect(plain.isError == false)
        #expect(try await rig.tab.page.evaluateJavaScript("document.activeElement.id") as? String == "user")

        // A staged save step (a username the page just showed) must not survive an agent-typed secret.
        rig.tab.autofillSave.stageUsername("alice", origin: origin, documentID: UUID().uuidString, attemptID: UUID(), in: rig.tab.page)
        #expect(rig.tab.autofillSave.username != nil)
        let secret = try await call(rig, "typeOnPage", [
            "observationID": .string(try #require(observation(plain))), "ref": .int(password), "text": .string(Self.password), "secret": true,
        ])
        #expect(secret.isError == false, "\(everything(secret))")

        #expect(rig.tab.autofillSave.username == nil, "the save session was cleared")
        #expect(rig.tab.autofillSave.current == nil)
        #expect(try await rig.tab.page.evaluateJavaScript("document.activeElement.id") as? String == "user", "typing a secret never focused the field")
        #expect(try await value(of: "pw", in: rig) == Self.password)
    }
}
