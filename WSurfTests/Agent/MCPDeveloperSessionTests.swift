// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// The Developer tier and standing grants on a connection: who gets them, where, and what takes them away. Sessions use an
/// in-memory trust store and pages parked on real addresses, so no keychain, network or sheet is involved.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPDeveloperSessionTests {
    private final class Sheets {
        var shown = 0
        var pages: [[MCPAccessConsent.Page]] = []
        var requests: [Bool] = []
        var opened: [URL] = []
        var answer: MCPAccessConsent.Access? = .control
        var allowOpen = false
    }

    private struct Rig {
        let browser: BrowserModel
        let trust: MCPTrustStore
        let client: PairedClient
        let session: MCPBrowserSession
        let sheets: Sheets
    }

    /// A paired client at `standing`, with `profile` as the Developer profile. The browser is on the everyday profile, so
    /// `Profile.originalID` is the explicit choice of that profile and anything else leaves the window outside it.
    private func makeRig(
        standing: PairedClient.Standing = .development, profile: UUID? = Profile.originalID, paired: Bool = true
    ) throws -> Rig {
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(standing, for: client.id)
        try trust.setDeveloperProfile(profile)
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDeveloper-\(UUID().uuidString).json")))
        let sheets = Sheets()
        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true },
            consent: { _, pages, development in
                sheets.shown += 1
                sheets.pages.append(pages)
                sheets.requests.append(development)
                return sheets.answer
            },
            openConsent: { _, url in
                sheets.opened.append(url)
                return sheets.allowOpen
            })
        if paired {
            session.pairedClient = trust.client(id: client.id)
        }
        return Rig(browser: browser, trust: trust, client: client, session: session, sheets: sheets)
    }

    private func call(_ rig: Rig, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await rig.session.call(name: name, arguments: arguments)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    private func origin(_ address: String) throws -> String {
        SitePermissions.origin(for: try url(address))
    }

    private func listed(_ rig: Rig) async throws -> String {
        text(try await call(rig, "listTabs"))
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

    // MARK: Standing grants

    @Test func standingDevelopmentOnThisMacNeedsNoSheet() async throws {
        let rig = try makeRig(standing: .development)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))

        #expect(try await call(rig, "requestAccess").isError == false)
        #expect(rig.sheets.shown == 0)
        let grant = try #require(rig.session.grants[tab.id])
        #expect(grant.source == .standing)
        #expect(grant.access == .development)
        #expect(rig.session.permits(tab, capability: .development))
        #expect(!rig.session.permits(tab, capability: .developer))
        #expect(try await listed(rig).contains(tab.id.uuidString))
    }

    @Test func standingDeveloperGivesTheDeveloperTier() async throws {
        let rig = try makeRig(standing: .developer)
        let tab = await parkTab(rig.browser, at: try url("http://127.0.0.1:3000/"))

        #expect(try await call(rig, "requestAccess").isError == false)
        #expect(rig.sheets.shown == 0)
        #expect(rig.session.grants[tab.id]?.access == .developer)
        #expect(rig.session.permits(tab, capability: .developer))
        #expect(rig.session.permits(tab, capability: .development))
        #expect(rig.session.permits(tab, capability: .control))
    }

    @Test func nonDeveloperSitesStillNeedOneSheetPerConnection() async throws {
        let rig = try makeRig(standing: .developer)
        rig.sheets.answer = .control
        let remote = await parkTab(rig.browser, at: try url("https://shop.invalid/"))

        #expect(try await call(rig, "requestAccess").isError == false)
        #expect(rig.sheets.shown == 1)
        let granted = try #require(rig.session.grants[remote.id])
        #expect(granted.source == .sheet)
        #expect(granted.access == .control)
        #expect(!rig.session.permits(remote, capability: .development))

        // At most one sheet: a second request for the same page is refused without asking again.
        let again = try await call(rig, "requestAccess")
        #expect(again.isError == true)
        #expect(rig.sheets.shown == 1)

        // A developer tab opened later is covered by the standing grant, with no second sheet; the first tab stays as it was.
        let local = await parkTab(rig.browser, at: try url("http://127.0.0.1:5173/"))
        let third = try await call(rig, "requestAccess")
        #expect(third.isError == false, "\(text(third))")
        #expect(rig.sheets.shown == 1)
        #expect(rig.session.grants[local.id]?.source == .standing)
        #expect(rig.session.grants[remote.id]?.source == .sheet)
        #expect(rig.session.grants[remote.id]?.access == .control)
    }

    @Test func standingGrantsNeverApplyToUnpairedConnections() async throws {
        let rig = try makeRig(standing: .developer, paired: false)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))

        #expect(try await call(rig, "requestAccess").isError == false)
        #expect(rig.sheets.shown == 1)
        #expect(rig.session.grants[tab.id]?.source == .sheet)
        #expect(rig.session.grants[tab.id]?.access == .control)
        #expect(!rig.session.permits(tab, capability: .development))
        // No standing newTab either.
        let opened = try await call(rig, "newTab", nil, ["url": .string("http://localhost:5173/other")])
        #expect(rig.sheets.opened == [try url("http://localhost:5173/other")])
        #expect(opened.isError == true)
    }

    @Test(arguments: [false, true])
    func standingGrantsNeverApplyOutsideTheDeveloperProfile(otherProfileChosen: Bool) async throws {
        // Nothing chosen, or a different profile chosen: this window is the everyday profile either way.
        let rig = try makeRig(standing: .developer, profile: otherProfileChosen ? UUID() : nil)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))

        #expect(try await call(rig, "requestAccess").isError == false)
        #expect(rig.sheets.shown == 1)
        #expect(rig.session.grants[tab.id]?.source == .sheet)
        let opened = try await call(rig, "newTab", nil, ["url": .string("http://localhost:5173/other")])
        #expect(opened.isError == true)
        #expect(rig.browser.tabs.count == 1)
    }

    @Test func aRevokedClientsSnapshotGetsNoStandingGrant() async throws {
        let rig = try makeRig(standing: .developer)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))
        try rig.trust.revoke(rig.client.id)

        #expect(try await call(rig, "requestAccess").isError == false)
        #expect(rig.sheets.shown == 1)
        #expect(rig.session.grants[tab.id]?.source == .sheet)
        #expect(!rig.session.permits(tab, capability: .development))
    }

    @Test func aStandingGrantAtOffGivesNothing() async throws {
        let rig = try makeRig(standing: .off)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))

        _ = try await call(rig, "requestAccess")
        #expect(rig.sheets.shown == 1)
        #expect(rig.session.grants[tab.id]?.source == .sheet)
    }

    // MARK: newTab and navigate

    @Test func newTabToADeveloperSiteNeedsNoPriorGrantOrSheet() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Dev</title><p>Hello</p>")])
        let rig = try makeRig(standing: .development)
        let address = try server.url()

        let result = try await call(rig, "newTab", nil, ["url": .string(address.absoluteString)])
        #expect(result.isError == false, "\(text(result))")
        #expect(rig.sheets.opened.isEmpty)
        #expect(rig.sheets.shown == 0)
        let tab = try #require(rig.browser.tabs.last)
        #expect(rig.browser.tabs.count == 1)
        let grant = try #require(rig.session.grants[tab.id])
        #expect(grant.source == .standing)
        #expect(grant.access == .development)
        #expect(try await listed(rig).contains(tab.id.uuidString))
        withExtendedLifetime(server) {}
    }

    @Test func newTabElsewhereStillNeedsAControlGrantAndTheSheet() async throws {
        let rig = try makeRig(standing: .developer)
        let refused = try await call(rig, "newTab", nil, ["url": .string("https://shop.invalid/")])
        #expect(refused.isError == true)
        #expect(rig.sheets.opened.isEmpty)
        #expect(rig.browser.tabs.isEmpty)

        // With a control grant on a page it is the sheet that decides, and the new site gets control only.
        _ = await parkTab(rig.browser, at: try url("https://first.invalid/"))
        _ = try await call(rig, "requestAccess")
        let declined = try await call(rig, "newTab", nil, ["url": .string("https://shop.invalid/")])
        #expect(declined.isError == true)
        #expect(rig.sheets.opened == [try url("https://shop.invalid/")])
        #expect(rig.browser.tabs.count == 1)
        rig.sheets.allowOpen = true
        let approved = try await call(rig, "newTab", nil, ["url": .string("https://shop.invalid/")])
        #expect(approved.isError == false, "\(text(approved))")
        let opened = try #require(rig.browser.tabs.last)
        #expect(rig.session.grants[opened.id]?.access == .control)
        #expect(rig.session.grants[opened.id]?.source == .sheet)
    }

    @Test func navigatingBetweenDeveloperSitesSkipsTheSheetAndTheObservedLinkRule() async throws {
        let first = try await HTTPFixtureServer.start(routes: ["/": .html("<title>A</title><p>A</p>")])
        let second = try await HTTPFixtureServer.start(routes: ["/": .html("<title>B</title><p>B</p>")])
        let rig = try makeRig(standing: .development)
        let tab = rig.browser.newTab(url: try first.url())
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: try first.url())
        _ = try await call(rig, "requestAccess")
        #expect(rig.session.grants[tab.id]?.source == .standing)
        rig.session.hasReadContent = true  // from now on only an observed link may be followed

        let moved = try await call(rig, "navigate", tab, ["url": .string(try second.url().absoluteString)])
        #expect(moved.isError == false, "\(text(moved))")
        #expect(rig.sheets.opened.isEmpty)
        #expect(await waitUntil { tab.page.url == (try? second.url()) })
        #expect(rig.session.grants[tab.id]?.origin == SitePermissions.origin(for: try second.url()))
        #expect(rig.session.grants[tab.id]?.source == .standing)

        // Leaving the developer sites: an address that was never observed is refused, an observed one asks first.
        let elsewhere = try url("https://elsewhere.invalid/page")
        let unseen = try await call(rig, "navigate", tab, ["url": .string(elsewhere.absoluteString)])
        #expect(unseen.isError == true)
        #expect(rig.sheets.opened.isEmpty)
        rig.session.destinations.insert(rig.session.destinationKey(elsewhere))
        let asked = try await call(rig, "navigate", tab, ["url": .string(elsewhere.absoluteString)])
        #expect(asked.isError == true)
        #expect(rig.sheets.opened == [elsewhere])
        #expect(tab.page.url == (try? second.url()))
        withExtendedLifetime((first, second)) {}
    }

    @Test func aStandingGrantCarriedByAnApprovedMoveElsewhereIsControlOnly() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>A</title><p>A</p>")])
        let rig = try makeRig(standing: .developer)
        let tab = rig.browser.newTab(url: try server.url())
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: try server.url())
        _ = try await call(rig, "requestAccess")
        #expect(rig.session.grants[tab.id]?.access == .developer)
        rig.sheets.allowOpen = true

        let elsewhere = try url("https://elsewhere.invalid/")
        _ = try await call(rig, "navigate", tab, ["url": .string(elsewhere.absoluteString)])
        #expect(rig.sheets.opened == [elsewhere])
        let carried = try #require(rig.session.grants[tab.id])
        #expect(carried.source == .sheet)
        #expect(carried.access == .control)
        #expect(carried.origin == SitePermissions.origin(for: elsewhere))
        withExtendedLifetime(server) {}
    }

    @Test func aPageMovingBetweenDeveloperSitesKeepsTheGrantAndLeavingTheListDropsIt() async throws {
        let first = try await HTTPFixtureServer.start(routes: ["/": .html("<title>A</title><p>A</p>")])
        let second = try await HTTPFixtureServer.start(routes: ["/": .html("<title>B</title><p>B</p>")])
        let rig = try makeRig(standing: .development)
        try rig.trust.setIncludesThisMac(false)
        let firstURL = try first.url(), secondURL = try second.url()
        try rig.trust.addDeveloperSite("127.0.0.1:\(try #require(firstURL.port))")
        let secondSite = try rig.trust.addDeveloperSite("127.0.0.1:\(try #require(secondURL.port))")
        let tab = rig.browser.newTab(url: firstURL)
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: firstURL)
        _ = try await call(rig, "requestAccess")
        #expect(rig.session.grants[tab.id]?.source == .standing)

        // The page moves by itself (the user, a link, a redirect) to the other listed site: the grant follows.
        tab.load(secondURL)
        #expect(await waitUntil { tab.page.url == secondURL })
        #expect(rig.session.sharedTab(tab.id) === tab)
        #expect(rig.session.grants[tab.id]?.origin == SitePermissions.origin(for: secondURL))
        #expect(rig.session.permits(tab, capability: .development))

        // Taking that site off the list ends the grant at once.
        try rig.trust.removeDeveloperSite(secondSite)
        #expect(rig.session.sharedTab(tab.id) == nil)
        #expect(rig.session.grants[tab.id] == nil)
        #expect(!rig.session.permits(tab, capability: .read))
        #expect(try await listed(rig).contains(tab.id.uuidString) == false)
        withExtendedLifetime((first, second)) {}
    }

    @Test func aRedirectFromADeveloperSiteToARemoteSiteDropsAccess() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Dev</title><p>Hello</p>")])
        let rig = try makeRig(standing: .developer)
        let tab = rig.browser.newTab(url: try server.url())
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: try server.url())
        _ = try await call(rig, "requestAccess")
        #expect(rig.session.permits(tab, capability: .developer))

        // The document is now a remote one, as after a redirect or a link, without needing a network.
        let remote = try url("https://remote.invalid/")
        tab.loadHTML("<!doctype html><title>Remote</title><p>Remote</p>", baseURL: remote)
        #expect(await waitUntil { tab.page.url == remote })
        for capability in [MCPBrowserSession.Scope.read, .control, .development, .developer] {
            #expect(!rig.session.permits(tab, capability: capability), "\(capability)")
        }
        #expect(rig.session.grants[tab.id] == nil)
        #expect(try await listed(rig).contains(tab.id.uuidString) == false)
        let read = try await call(rig, "readPage", tab)
        #expect(read.isError == true)
        withExtendedLifetime(server) {}
    }

    @Test func aSheetGrantedDeveloperTabAlsoLosesAccessOnARemoteSite() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Dev</title><p>Hello</p>")])
        let rig = try makeRig(standing: .off)
        rig.sheets.answer = .developer
        let tab = rig.browser.newTab(url: try server.url())
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: try server.url())
        _ = try await call(rig, "requestAccess", nil, ["development": true, "developer": true])
        #expect(rig.session.permits(tab, capability: .developer))

        let remote = try url("https://remote.invalid/")
        tab.loadHTML("<!doctype html><title>Remote</title><p>Remote</p>", baseURL: remote)
        #expect(await waitUntil { tab.page.url == remote })
        #expect(!rig.session.permits(tab, capability: .read))
        withExtendedLifetime(server) {}
    }

    // MARK: What takes the grant away

    @Test func pausingDropsStandingGrantsWithOrWithoutTheServerRefresh() async throws {
        let rig = try makeRig(standing: .developer)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))
        _ = try await call(rig, "requestAccess")
        #expect(rig.session.permits(tab, capability: .developer))

        try rig.trust.setPaused(true, for: rig.client.id)
        // No refresh needed: every use is judged against the store as it is now.
        #expect(!rig.session.permits(tab, capability: .read))
        #expect(try await listed(rig).contains(tab.id.uuidString) == false)
        rig.session.refreshStanding()
        #expect(rig.session.grants.isEmpty)

        // A paused client asking again gets the sheet, not the standing grant.
        let sheet = try await call(rig, "requestAccess")
        #expect(sheet.isError == false)
        #expect(rig.sheets.shown == 1)
        #expect(rig.session.grants[tab.id]?.source == .sheet)
    }

    @Test func resumingRestoresTheStandingGrantOnTheNextRequest() async throws {
        let rig = try makeRig(standing: .development)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))
        try rig.trust.setPaused(true, for: rig.client.id)
        try rig.trust.setPaused(false, for: rig.client.id)

        _ = try await call(rig, "requestAccess")
        #expect(rig.sheets.shown == 0)
        #expect(rig.session.grants[tab.id]?.source == .standing)
    }

    @Test func loweringTheStandingLevelLowersALiveGrant() async throws {
        let rig = try makeRig(standing: .developer)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))
        _ = try await call(rig, "requestAccess")
        #expect(rig.session.permits(tab, capability: .developer))

        try rig.trust.setStanding(.development, for: rig.client.id)
        #expect(!rig.session.permits(tab, capability: .developer))
        #expect(rig.session.permits(tab, capability: .development))
        try rig.trust.setStanding(.off, for: rig.client.id)
        #expect(!rig.session.permits(tab, capability: .read))
    }

    @Test func changingTheDeveloperProfileEndsStandingGrantsInThisWindow() async throws {
        let rig = try makeRig(standing: .development)
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))
        _ = try await call(rig, "requestAccess")
        #expect(rig.session.permits(tab, capability: .development))

        try rig.trust.setDeveloperProfile(UUID())
        #expect(!rig.session.permits(tab, capability: .read))
        rig.session.refreshStanding()
        #expect(rig.session.grants.isEmpty)
    }

    @Test func pausingReleasesTheLeasesAStandingGrantCarried() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Dev</title><p>Hello</p>")])
        let rig = try makeRig(standing: .development)
        let tab = rig.browser.newTab(url: try server.url())
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: try server.url())
        let window = await show(tab)
        defer {
            window.contentView = nil
            window.close()
        }
        _ = try await call(rig, "requestAccess")
        let viewport = try await call(rig, "setViewport", tab, ["width": 400, "height": 700])
        #expect(viewport.isError == false, "\(text(viewport))")
        #expect(tab.developmentOwner != nil)

        try rig.trust.setPaused(true, for: rig.client.id)
        rig.session.refreshStanding()
        #expect(tab.developmentOwner == nil)
        #expect(await waitUntil { tab.page.developmentViewport == nil })
        #expect(rig.session.grants.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test func aSiteRecordStillCapsTheDeveloperTier() async throws {
        let rig = try makeRig(standing: .developer)
        let address = try url("http://localhost:5173/")
        let tab = await parkTab(rig.browser, at: address)
        _ = try await call(rig, "requestAccess")
        let siteOrigin = SitePermissions.origin(for: address)

        rig.browser.sitePermissions.setAssistantAccess(.readOnly, for: siteOrigin)
        #expect(rig.session.permits(tab, capability: .read))
        for capability in [MCPBrowserSession.Scope.control, .development, .developer] {
            #expect(!rig.session.permits(tab, capability: capability), "\(capability)")
        }
        rig.browser.sitePermissions.setAssistantAccess(.deny, for: siteOrigin)
        #expect(try await listed(rig).contains(tab.id.uuidString) == false)
        #expect(!rig.session.permits(tab, capability: .read))
        rig.browser.sitePermissions.setAssistantAccess(.control, for: siteOrigin)
        #expect(rig.session.permits(tab, capability: .developer))
    }

    // MARK: The sheet and the Developer tier

    @Test func developerNeedsAPairedClientEvenWithTheSheet() async throws {
        let rig = try makeRig(standing: .off, paired: false)
        rig.sheets.answer = .developer
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))

        _ = try await call(rig, "requestAccess", nil, ["development": true, "developer": true])
        // The sheet is not even offered Allow Developer, and an answer of it anyway is capped.
        #expect(rig.sheets.pages.first?.allSatisfy { !$0.developerEligible } == true)
        #expect(rig.session.grants[tab.id]?.access == .development)
        #expect(!rig.session.permits(tab, capability: .developer))
    }

    @Test func aPairedClientIsOfferedDeveloperOnlyOnADeveloperSiteInTheDeveloperProfile() async throws {
        let rig = try makeRig(standing: .off)
        rig.sheets.answer = .developer
        let local = await parkTab(rig.browser, at: try url("http://localhost:5173/"))

        _ = try await call(rig, "requestAccess", nil, ["development": true, "developer": true])
        #expect(rig.sheets.pages.first?.map(\.developerEligible) == [true])
        #expect(rig.session.grants[local.id]?.access == .developer)
        #expect(rig.session.grants[local.id]?.source == .sheet)
        #expect(rig.session.permits(local, capability: .developer))
    }

    @Test(arguments: ["https://shop.invalid/", "http://127.0.0.2:3000/"])
    func developerIsNotOfferedOnOtherSites(address: String) async throws {
        let rig = try makeRig(standing: .off)
        rig.sheets.answer = .developer
        let tab = await parkTab(rig.browser, at: try url(address))

        _ = try await call(rig, "requestAccess", nil, ["development": true, "developer": true])
        #expect(rig.sheets.pages.first?.map(\.developerEligible) == [false])
        #expect(rig.session.grants[tab.id]?.access == .development)
        #expect(!rig.session.permits(tab, capability: .developer))
    }

    @Test func developerIsNotOfferedOutsideTheDeveloperProfile() async throws {
        let rig = try makeRig(standing: .off, profile: nil)
        rig.sheets.answer = .developer
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))

        _ = try await call(rig, "requestAccess", nil, ["development": true, "developer": true])
        #expect(rig.sheets.pages.first?.map(\.developerEligible) == [false])
        #expect(rig.session.grants[tab.id]?.access == .development)
    }

    @Test(arguments: [
        (["development": false, "developer": false], MCPAccessConsent.Access.control),
        (["development": true, "developer": false], .development),
        (["development": true, "developer": true], .developer),
    ] as [([String: Bool], MCPAccessConsent.Access)])
    func aRequestCanOnlyBeGivenWhatItAskedFor(asked: [String: Bool], expected: MCPAccessConsent.Access) async throws {
        let rig = try makeRig(standing: .off)
        rig.sheets.answer = .developer  // the most the user could have clicked
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))

        _ = try await call(rig, "requestAccess", nil, asked.filter { $0.value }.mapValues { Value.bool($0) })
        #expect(rig.session.grants[tab.id]?.access == expected)
    }

    @Test func aSheetGrantedDeveloperFallsBackToDevelopmentWhenTheTierStopsHolding() async throws {
        let rig = try makeRig(standing: .off)
        rig.sheets.answer = .developer
        let tab = await parkTab(rig.browser, at: try url("http://localhost:5173/"))
        _ = try await call(rig, "requestAccess", nil, ["development": true, "developer": true])
        #expect(rig.session.permits(tab, capability: .developer))

        try rig.trust.setDeveloperProfile(nil)
        #expect(!rig.session.permits(tab, capability: .developer))
        #expect(rig.session.permits(tab, capability: .development))
    }

    // MARK: Consequential actions

    @Test func theDeveloperTierSkipsConfirmationsOnlyWhereItHolds() async throws {
        var asked = 0
        let policy = AgentActionPolicy(storage: MCPActionGrantStorage())
        func attempt(_ rig: Rig, _ tab: BrowserTab, applying: Bool = true) async -> Bool {
            await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, _ in
                asked += 1
                return .decline
            }) {
                if applying {
                    await AgentActionConsent.$developerApproval.withValue(rig.session.developerApproval(for: tab)) {
                        await AgentActionConsent.permit(label: "Pay now", category: .purchase, host: "localhost", policy: policy)
                    }
                } else {
                    await AgentActionConsent.permit(label: "Pay now", category: .purchase, host: "localhost", policy: policy)
                }
            }
        }

        // Developer on a developer site in the Developer profile: let through, and noted.
        let developer = try makeRig(standing: .developer)
        let developerTab = await parkTab(developer.browser, at: try url("http://localhost:5173/"))
        _ = try await call(developer, "requestAccess")
        #expect(await attempt(developer, developerTab))
        #expect(asked == 0)
        #expect(developer.session.developerApprovals.map(\.category) == [.purchase])
        #expect(developer.session.developerApprovals.first?.host == "localhost")

        // The same connection without the Developer tier's hook (the in-app assistant, or any other path) still asks.
        #expect(await attempt(developer, developerTab, applying: false) == false)
        #expect(asked == 1)

        // Development is not Developer.
        let development = try makeRig(standing: .development)
        let developmentTab = await parkTab(development.browser, at: try url("http://localhost:5173/"))
        _ = try await call(development, "requestAccess")
        #expect(await attempt(development, developmentTab) == false)
        #expect(asked == 2)
        #expect(development.session.developerApprovals.isEmpty)

        // An unpaired connection cannot hold Developer, so it asks.
        let unpaired = try makeRig(standing: .developer, paired: false)
        unpaired.sheets.answer = .developer
        let unpairedTab = await parkTab(unpaired.browser, at: try url("http://localhost:5173/"))
        _ = try await call(unpaired, "requestAccess", nil, ["development": true, "developer": true])
        #expect(await attempt(unpaired, unpairedTab) == false)
        #expect(asked == 3)

        // Developer in a window that is not the Developer profile never holds, so it asks.
        let outside = try makeRig(standing: .developer, profile: nil)
        outside.sheets.answer = .developer
        let outsideTab = await parkTab(outside.browser, at: try url("http://localhost:5173/"))
        _ = try await call(outside, "requestAccess", nil, ["development": true, "developer": true])
        #expect(await attempt(outside, outsideTab) == false)
        #expect(asked == 4)

        // Once the page is off the developer sites the confirmation is back.
        try developer.trust.setIncludesThisMac(false)
        #expect(await attempt(developer, developerTab) == false)
        #expect(asked == 5)
        #expect(developer.session.developerApprovals.count == 1)
    }

    // MARK: Catalog

    @Test func requestAccessAcceptsTheDeveloperFlag() throws {
        let entry = try #require(MCPToolCatalog.entries.first { $0.name == "requestAccess" })
        try entry.validate(["developer": true])
        try entry.validate(["development": true, "developer": true])
        #expect(throws: (any Error).self) { try entry.validate(["developer": "yes"]) }
    }
}
