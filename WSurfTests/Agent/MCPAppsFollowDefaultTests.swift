// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing

@testable import WSurf

/// A paired app that follows the Website access default opens a new website without the Open and Share sheet, and everything
/// that should still ask, still asks. Two loopback servers are two websites; the trust store is in memory.
@MainActor
@Suite(.serialized)
struct MCPAppsFollowDefaultTests {
    private final class Sheets {
        var opened: [URL] = []
        var sensitive: [URL] = []
        var allowOpen = false
        var allowSensitive = false
    }

    private struct Rig {
        let home: HTTPFixtureServer
        let away: HTTPFixtureServer
        let homeURL: URL
        let awayURL: URL
        let browser: BrowserModel
        let tab: BrowserTab
        let permissions: SitePermissions
        let trust: MCPTrustStore
        let client: PairedClient
        let session: MCPBrowserSession
        let sheets: Sheets

        var awayOrigin: String {
            SitePermissions.origin(for: awayURL)
        }

        var tabGrant: MCPBrowserSession.Grant? {
            session.grants[tab.id]
        }
    }

    private static let plain = """
        <!doctype html><title>Away</title><p>Away page</p>
        <button onclick="document.body.dataset.clicked='yes'">Away button</button>
        <button onclick="document.body.dataset.signedIn='yes'">Continue with Google</button>
        <a href="/second">Second page</a>
        """

    private static let signIn = """
        <!doctype html><title>Sign in</title><p>Sign in</p>
        <input aria-label="Password" type="password">
        <button onclick="document.body.dataset.clicked='yes'">Away button</button>
        """

    private static let second = "<!doctype html><title>Second</title><p>Second page</p>"

    private func makeRig(
        follows: Bool = true, level: AssistantAccessPolicy = .control, file: AssistantAccessPolicy = .control,
        permissions given: SitePermissions? = nil, paired: Bool = true, unreadable: Bool = false,
        away html: String = MCPAppsFollowDefaultTests.plain, access: MCPAccessConsent.Access = .control
    ) async throws -> Rig {
        let away = try await HTTPFixtureServer.start(routes: ["/": .html(html), "/second": .html(Self.second), "/unlinked": .html(Self.second)])
        let awayURL = try away.url()
        let home = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Home</title><p>Home page</p><a href=\"\(awayURL.absoluteString)\">Away</a>")
        ])
        let homeURL = try home.url()

        let permissions = given ?? SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDefault-\(UUID().uuidString).json"))
        if given == nil {
            permissions.setAssistantDefault(file)
        }
        let storage = MemoryTrustStorage()
        var trust = MCPTrustStore(storage: storage)
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setAppsFollowDefault(follows, level: level)
        if unreadable {
            trust = MCPTrustStore(storage: MemoryTrustStorage(data: storage.stored, refusesReads: true))
            trust.loadIfNeeded()
        }

        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let tab = browser.newTab(url: homeURL)
        try #require(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: homeURL)

        let sheets = Sheets()
        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true }, consent: { _, _, _ in access },
            openConsent: { _, url in
                sheets.opened.append(url)
                return sheets.allowOpen
            },
            sensitiveConsent: { _, url in
                sheets.sensitive.append(url)
                return sheets.allowSensitive
            })
        if paired {
            session.pairedClient = client
        }
        return Rig(
            home: home, away: away, homeURL: homeURL, awayURL: awayURL, browser: browser, tab: tab, permissions: permissions,
            trust: trust, client: client, session: session, sheets: sheets)
    }

    private func call(_ rig: Rig, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await rig.session.call(name: name, arguments: arguments)
    }

    private func text(_ result: CallTool.Result) -> String {
        MCPFeedbackRig.text(result)
    }

    /// Shares the home page and reads it, so its link to the other website is one the app may follow.
    private func share(_ rig: Rig) async throws {
        #expect(try await call(rig, "requestAccess").isError == false)
        let read = try await call(rig, "readPage", rig.tab)
        #expect(read.isError == false, "\(text(read))")
    }

    /// Shares the home page, moves the tab to the other website with `navigate`, and waits until it has loaded.
    private func moveAway(_ rig: Rig) async throws -> CallTool.Result {
        try await share(rig)
        let moved = try await call(rig, "navigate", rig.tab, ["url": .string(rig.awayURL.absoluteString)])
        if moved.isError != true {
            #expect(await settled(rig.tab, at: rig.awayURL))
        }
        return moved
    }

    private func ref(of label: String, _ rig: Rig) async throws -> Int {
        let read = try await call(rig, "readPage", rig.tab)
        #expect(read.isError == false, "\(text(read))")
        return try MCPFeedbackRig.ref(of: label, in: read)
    }

    private func clicked(_ rig: Rig) async throws -> String {
        try await rig.tab.page.evaluateJavaScript("document.body.dataset.clicked || ''") as? String ?? ""
    }

    // MARK: Opening new websites

    @Test(.boundedWebViews) func allowControlDefaultOpensNewWebsitesWithoutTheSheet() async throws {
        let rig = try await makeRig()
        let moved = try await moveAway(rig)

        #expect(moved.isError == false, "\(text(moved))")
        #expect(rig.sheets.opened.isEmpty, "no Open and Share sheet")
        let grant = try #require(rig.tabGrant)
        #expect(grant.origin == rig.awayOrigin)
        #expect(grant.access == .control)
        #expect(grant.source == .appDefault)
        let read = try await call(rig, "readPage", rig.tab)
        #expect(read.isError == false, "\(text(read))")
        #expect(text(read).contains("Away page"))
    }

    @Test(.boundedWebViews) func theObservedLinkRuleStillApplies() async throws {
        let rig = try await makeRig()
        try await share(rig)

        let unlinked = try rig.away.url("/unlinked")
        let refused = try await call(rig, "navigate", rig.tab, ["url": .string(unlinked.absoluteString)])
        #expect(refused.isError == true, "\(text(refused))")
        #expect(rig.sheets.opened.isEmpty, "refused before any sheet would have been shown")
        #expect(rig.tab.page.url == rig.homeURL)
        #expect(rig.tabGrant?.source == .sheet)

        let opened = try await call(rig, "newTab", nil, ["url": .string(unlinked.absoluteString)])
        #expect(opened.isError == true, "\(text(opened))")
        #expect(rig.browser.tabs.count == 1)
    }

    @Test(.boundedWebViews) func aNewWebsiteGetsAtMostControl() async throws {
        let rig = try await makeRig(access: .development)
        #expect(try await call(rig, "requestAccess", nil, ["development": true]).isError == false)
        #expect(rig.tabGrant?.access == .development)
        #expect(try await call(rig, "readPage", rig.tab).isError == false)

        let moved = try await call(rig, "navigate", rig.tab, ["url": .string(rig.awayURL.absoluteString)])
        #expect(moved.isError == false, "\(text(moved))")
        #expect(await settled(rig.tab, at: rig.awayURL))
        #expect(rig.sheets.opened.isEmpty)
        #expect(rig.tabGrant?.access == .control, "Development does not come along")
        #expect(rig.session.permits(rig.tab, capability: .control))
        #expect(!rig.session.permits(rig.tab, capability: .development))
        #expect(!rig.session.permits(rig.tab, capability: .developer))
    }

    @Test(.boundedWebViews) func aNewTabFollowsTheDefaultButStillNeedsControlOfASharedTab() async throws {
        let rig = try await makeRig()
        let early = try await call(rig, "newTab", nil, ["url": .string(rig.awayURL.absoluteString)])
        #expect(early.isError == true, "no grant yet: \(text(early))")
        #expect(rig.browser.tabs.count == 1)
        #expect(rig.sheets.opened.isEmpty)

        try await share(rig)
        let opened = try await call(rig, "newTab", nil, ["url": .string(rig.awayURL.absoluteString)])
        #expect(opened.isError == false, "\(text(opened))")
        #expect(rig.sheets.opened.isEmpty, "no Open and Share sheet")
        #expect(rig.browser.tabs.count == 2)
        let created = try #require(rig.browser.tabs.first { $0 !== rig.tab })
        let grant = try #require(rig.session.grants[created.id])
        #expect(grant.source == .appDefault && grant.access == .control && grant.origin == rig.awayOrigin)
        #expect(await settled(created, at: rig.awayURL))
        #expect(try await call(rig, "readPage", created).isError == false)
    }

    @Test(.boundedWebViews) func moreNavigationOnTheSameWebsiteKeepsTheGrantAsADefaultGrant() async throws {
        let rig = try await makeRig()
        #expect(try await moveAway(rig).isError == false)
        #expect(try await call(rig, "readPage", rig.tab).isError == false)

        let second = try rig.away.url("/second")
        let moved = try await call(rig, "navigate", rig.tab, ["url": .string(second.absoluteString)])
        #expect(moved.isError == false, "\(text(moved))")
        #expect(await settled(rig.tab, at: second))
        #expect(rig.sheets.opened.isEmpty)
        #expect(rig.tabGrant?.source == .appDefault, "the grant did not turn into one from a sheet")
        #expect(rig.tabGrant?.access == .control)
    }

    // MARK: Who still gets the sheet

    @Test(.boundedWebViews) func anUnpairedConnectionStillGetsTheSheet() async throws {
        let rig = try await makeRig(paired: false)
        let declined = try await moveAway(rig)
        #expect(declined.isError == true, "\(text(declined))")
        #expect(rig.sheets.opened == [rig.awayURL])
        #expect(rig.tab.page.url == rig.homeURL)

        rig.sheets.allowOpen = true
        let approved = try await call(rig, "navigate", rig.tab, ["url": .string(rig.awayURL.absoluteString)])
        #expect(approved.isError == false, "\(text(approved))")
        #expect(rig.sheets.opened.count == 2)
        #expect(rig.tabGrant?.source == .sheet, "an approved sheet is an ordinary grant")
    }

    @Test(.boundedWebViews) func editingTheProfileFileAloneCannotRaiseTheAccess() async throws {
        // What a process with a shell could write: Allow Control as the default.
        let file = AppDatabase.supportDirectory.appendingPathComponent("MCPDefaultEdited-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["assistantDefault": "control"]).write(to: file)
        let edited = SitePermissions(storageURL: file)
        #expect(edited.assistantDefault == .control, "the edit did load")

        // Nothing in the keychain: never turned on.
        let never = try await makeRig(follows: false, level: .ask, permissions: edited)
        let first = try await moveAway(never)
        #expect(first.isError == true, "\(text(first))")
        #expect(never.sheets.opened == [never.awayURL], "the sheet still asks")

        // The keychain approved less than the file says: the lower level wins.
        let lower = try await makeRig(follows: true, level: .readOnly, permissions: edited)
        _ = try await moveAway(lower)
        #expect(lower.sheets.opened == [lower.awayURL])
    }

    @Test(.boundedWebViews) func aKeychainThatIsOffOrUnreadableMeansNoEffect() async throws {
        let off = try await makeRig(follows: false)
        _ = try await moveAway(off)
        #expect(off.sheets.opened == [off.awayURL], "turned off")
        #expect(off.permissions.assistantDefault == .control)

        let locked = try await makeRig(unreadable: true)
        #expect(!locked.trust.isAvailable)
        _ = try await moveAway(locked)
        #expect(locked.sheets.opened == [locked.awayURL], "keychain unreadable")
        #expect(locked.tabGrant?.source != .appDefault)
    }

    @Test(.boundedWebViews) func theLowerOfTheTwoLevelsDecidesAndAskAndReadOnlyDefaultsKeepTheSheet() async throws {
        let combinations: [(AssistantAccessPolicy, AssistantAccessPolicy)] = [(.control, .readOnly), (.control, .ask), (.readOnly, .control), (.ask, .ask)]
        for (level, file) in combinations {
            let rig = try await makeRig(level: level, file: file)
            _ = try await moveAway(rig)
            #expect(rig.sheets.opened == [rig.awayURL], "keychain \(level), file \(file)")
        }
    }

    @Test(.boundedWebViews) func aWebsitesOwnRecordWinsOverTheDefault() async throws {
        for record in [AssistantAccessPolicy.ask, .readOnly] {
            let rig = try await makeRig()
            rig.permissions.setAssistantAccess(record, for: rig.awayOrigin)
            _ = try await moveAway(rig)
            #expect(rig.sheets.opened == [rig.awayURL], "a \(record) record asks")
        }

        let allowed = try await makeRig()
        allowed.permissions.setAssistantAccess(.control, for: allowed.awayOrigin)
        #expect(try await moveAway(allowed).isError == false)
        #expect(allowed.sheets.opened.isEmpty, "an Allow Control record agrees with the default")

        let denied = try await makeRig()
        denied.permissions.setAssistantAccess(.deny, for: denied.awayOrigin)
        denied.sheets.allowOpen = true
        let refused = try await moveAway(denied)
        #expect(refused.isError == true && text(refused).contains("off for this website"), "\(text(refused))")
        #expect(denied.tab.page.url == denied.homeURL)

        // A record that appears once the app is on the website ends the default grant too.
        let late = try await makeRig()
        #expect(try await moveAway(late).isError == false)
        #expect(late.session.permits(late.tab, capability: .control))
        late.permissions.setAssistantAccess(.readOnly, for: late.awayOrigin)
        #expect(!late.session.permits(late.tab, capability: .control))
    }

    // MARK: Ending it

    @Test(.boundedWebViews) func turningItOffPausingOrLoweringTheDefaultEndsTheAccess() async throws {
        let off = try await makeRig()
        #expect(try await moveAway(off).isError == false)
        #expect(off.session.permits(off.tab, capability: .control))
        try off.trust.setAppsFollowDefault(false, level: .control)
        #expect(!off.session.permits(off.tab, capability: .control))
        #expect(off.session.grants[off.tab.id] == nil, "the grant is dropped, not just ignored")
        #expect(try await call(off, "readPage", off.tab).isError == true)

        let paused = try await makeRig()
        #expect(try await moveAway(paused).isError == false)
        try paused.trust.setPaused(true, for: paused.client.id)
        paused.session.refreshStanding()
        #expect(paused.session.grants[paused.tab.id] == nil)
        try paused.trust.setPaused(false, for: paused.client.id)
        #expect(paused.session.grants[paused.tab.id] == nil, "resuming does not bring a dropped grant back")

        let lowered = try await makeRig()
        #expect(try await moveAway(lowered).isError == false)
        lowered.permissions.setAssistantDefault(.ask)
        #expect(!lowered.session.permits(lowered.tab, capability: .control))
        #expect(try await call(lowered, "readPage", lowered.tab).isError == true)
    }

    @Test(.boundedWebViews) func aPausedAppGetsTheSheetUntilItIsResumed() async throws {
        let rig = try await makeRig()
        try rig.trust.setPaused(true, for: rig.client.id)
        let declined = try await moveAway(rig)
        #expect(declined.isError == true, "\(text(declined))")
        #expect(rig.sheets.opened == [rig.awayURL])

        try rig.trust.setPaused(false, for: rig.client.id)
        let moved = try await call(rig, "navigate", rig.tab, ["url": .string(rig.awayURL.absoluteString)])
        #expect(moved.isError == false, "\(text(moved))")
        #expect(rig.sheets.opened.count == 1, "no second sheet")
        #expect(rig.tabGrant?.source == .appDefault)
    }

    // MARK: Pages that ask

    @Test(.boundedWebViews) func aPageWithAPasswordFieldAsksBeforeTheAppControlsIt() async throws {
        let rig = try await makeRig(away: Self.signIn)
        #expect(try await moveAway(rig).isError == false)
        let button = try await ref(of: "Away button", rig)
        #expect(rig.sheets.sensitive.isEmpty, "reading asks nothing")

        let declined = try await call(rig, "clickOnPage", rig.tab, ["ref": .int(button)])
        #expect(declined.isError == true, "\(text(declined))")
        #expect(rig.sheets.sensitive == [rig.awayURL])
        #expect(try await clicked(rig) == "", "nothing was clicked")
        #expect(rig.tabGrant?.source == .appDefault)

        rig.sheets.allowSensitive = true
        let allowed = try await call(rig, "clickOnPage", rig.tab, ["ref": .int(button)])
        #expect(allowed.isError == false, "\(text(allowed))")
        #expect(rig.sheets.sensitive.count == 2)
        #expect(try await clicked(rig) == "yes")
        #expect(rig.tabGrant?.source == .sheet, "the answer stands for this website and connection")

        #expect(try await call(rig, "clickOnPage", rig.tab, ["ref": .int(button)]).isError == false)
        #expect(rig.sheets.sensitive.count == 2, "asked once")
    }

    @Test(.boundedWebViews) func aPageWithoutSensitiveFieldsNeverAsks() async throws {
        let rig = try await makeRig()
        #expect(try await moveAway(rig).isError == false)
        let button = try await ref(of: "Away button", rig)
        let result = try await call(rig, "clickOnPage", rig.tab, ["ref": .int(button)])
        #expect(result.isError == false, "\(text(result))")
        #expect(try await clicked(rig) == "yes")
        #expect(rig.sheets.sensitive.isEmpty)
        #expect(rig.tabGrant?.source == .appDefault)
    }

    @Test(.boundedWebViews) func theProbeDecidesWhetherAPageAsks() async throws {
        let rig = try await makeRig()
        #expect(try await moveAway(rig).isError == false)
        rig.session.sensitivePageProbe = { _ in true }
        let button = try await ref(of: "Away button", rig)
        let result = try await call(rig, "clickOnPage", rig.tab, ["ref": .int(button)])
        #expect(result.isError == true)
        #expect(rig.sheets.sensitive == [rig.awayURL])
    }

    @Test(.boundedWebViews) func signingInStillAsksUnderTheDefault() async throws {
        let rig = try await makeRig()
        #expect(try await moveAway(rig).isError == false)
        let button = try await ref(of: "Continue with Google", rig)

        var asked: [SensitiveAction.Category] = []
        let declined = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, category, _, _ in
            asked.append(category)
            return .decline
        }) {
            try await call(rig, "clickOnPage", rig.tab, ["ref": .int(button)])
        }
        #expect(asked == [.accountAccess])
        #expect(declined.isError == true)
        #expect(try await rig.tab.page.evaluateJavaScript("document.body.dataset.signedIn || ''") as? String == "")
        #expect(rig.session.developerApprovals.isEmpty, "nothing was let through unasked")

        let allowed = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, _ in .allowOnce }) {
            try await call(rig, "clickOnPage", rig.tab, ["ref": .int(button)])
        }
        #expect(allowed.isError == false, "\(text(allowed))")
        #expect(try await rig.tab.page.evaluateJavaScript("document.body.dataset.signedIn") as? String == "yes")
    }
}
