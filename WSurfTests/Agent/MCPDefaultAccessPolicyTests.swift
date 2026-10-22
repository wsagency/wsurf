// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Who follows the Website access default, and how much, without a web view: the keychain's switch and level, the profile
/// file's default, the website's own record and the app. In-memory trust storage, so nothing reaches the real keychain.
@MainActor
struct MCPDefaultAccessPolicyTests {
    private static let shop = URL(string: "https://shop.example/cart")!

    struct Case: Sendable {
        let keychain: AssistantAccessPolicy
        let file: AssistantAccessPolicy
        let expected: AssistantAccessPolicy
    }

    private struct Setup {
        let trust: MCPTrustStore
        let storage: MemoryTrustStorage
        let client: PairedClient
        let permissions: SitePermissions
        let browser: BrowserModel

        func opens(_ url: URL = MCPDefaultAccessPolicyTests.shop, as app: PairedClient? = nil) -> Bool {
            MCPDefaultAccess.opens(url, client: app ?? client, in: browser, trust: trust)
        }

        var level: AssistantAccessPolicy {
            MCPDefaultAccess.level(in: browser, trust: trust)
        }
    }

    private func makeSetup(
        follows: Bool = true, keychain: AssistantAccessPolicy = .control, file: AssistantAccessPolicy = .control
    ) throws -> Setup {
        let storage = MemoryTrustStorage()
        let trust = MCPTrustStore(storage: storage)
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setAppsFollowDefault(follows, level: keychain)
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDefaultPolicy-\(UUID().uuidString).json"))
        permissions.setAssistantDefault(file)
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        return Setup(trust: trust, storage: storage, client: client, permissions: permissions, browser: browser)
    }

    // MARK: Which level

    @Test(arguments: [
        Case(keychain: .ask, file: .ask, expected: .ask), Case(keychain: .ask, file: .readOnly, expected: .ask),
        Case(keychain: .ask, file: .control, expected: .ask), Case(keychain: .readOnly, file: .ask, expected: .ask),
        Case(keychain: .readOnly, file: .readOnly, expected: .readOnly), Case(keychain: .readOnly, file: .control, expected: .readOnly),
        Case(keychain: .control, file: .ask, expected: .ask), Case(keychain: .control, file: .readOnly, expected: .readOnly),
        Case(keychain: .control, file: .control, expected: .control),
    ])
    func theLowerOfTheKeychainAndFileLevelsIsUsed(_ levels: Case) throws {
        let setup = try makeSetup(keychain: levels.keychain, file: levels.file)
        #expect(setup.level == levels.expected)
        // Only Allow Control opens a new website without the sheet; Ask and Read Only keep today's sheets.
        #expect(setup.opens() == (levels.expected == .control))
    }

    @Test func aFileThatSaysAllowControlCannotTurnItOn() throws {
        let off = try makeSetup(follows: false, keychain: .control, file: .control)
        #expect(off.permissions.assistantDefault == .control)
        #expect(off.level == .ask)
        #expect(!off.opens())

        // A keychain that was never asked to follow stays off however the file reads.
        let storage = MemoryTrustStorage()
        let trust = MCPTrustStore(storage: storage)
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.second, name: "Codex", kind: .codex)
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDefaultPolicyFile-\(UUID().uuidString).json"))
        permissions.setAssistantDefault(.control)
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        #expect(!trust.appsFollowDefault && trust.appsDefaultLevel == .ask)
        #expect(!MCPDefaultAccess.opens(Self.shop, client: client, in: browser, trust: trust))
    }

    /// A website's own choice covers all of it: a stricter one saved on one subdomain keeps a paired app from opening any
    /// other page of the site under the default, and a different site is unaffected.
    @Test func aWebsiteChoiceCoversItsSubdomains() throws {
        let setup = try makeSetup()
        let cart = URL(string: "https://shop.example.com/cart")!
        #expect(setup.opens(cart))

        setup.permissions.setAssistantAccess(.readOnly, for: "https://www.example.com")
        #expect(!setup.opens(cart))
        #expect(!setup.opens(URL(string: "https://example.com/")!))
        #expect(setup.opens(URL(string: "https://example.org/")!))

        setup.permissions.setAssistantAccess(.control, for: "https://blog.example.com")
        #expect(setup.opens(cart))
        // A private-section host is a site of its own.
        setup.permissions.setAssistantAccess(.deny, for: "https://alice.github.io")
        #expect(setup.opens(URL(string: "https://bob.github.io/")!))
        #expect(!setup.opens(URL(string: "https://docs.alice.github.io/")!))
    }

    @Test func anUnreadableKeychainTurnsItOff() throws {
        let on = try makeSetup()
        #expect(on.opens())
        let locked = MCPTrustStore(storage: MemoryTrustStorage(data: on.storage.stored, refusesReads: true))
        locked.loadIfNeeded()
        #expect(!locked.isAvailable)
        #expect(!locked.appsFollowDefault)
        #expect(!MCPDefaultAccess.opens(Self.shop, client: on.client, in: on.browser, trust: locked))
        #expect(MCPDefaultAccess.level(in: on.browser, trust: locked) == .ask)
    }

    // MARK: Which app, which website, which window

    @Test func onlyAPairedAppThatIsNotPausedFollowsIt() throws {
        let setup = try makeSetup()
        #expect(setup.opens())
        #expect(MCPDefaultAccess.opens(Self.shop, client: nil, in: setup.browser, trust: setup.trust) == false, "an unpaired connection")

        try setup.trust.setPaused(true, for: setup.client.id)
        #expect(!setup.opens(), "Stop paused it")
        try setup.trust.setPaused(false, for: setup.client.id)
        #expect(setup.opens(), "Resume brings it back")

        try setup.trust.revoke(setup.client.id)
        #expect(!setup.opens(), "a revoked app's old record gets nothing")
    }

    @Test func aWebsitesOwnRecordWins() throws {
        let setup = try makeSetup()
        let origin = SitePermissions.origin(for: Self.shop)
        let other = try #require(URL(string: "https://news.example/"))

        for record in [AssistantAccessPolicy.ask, .readOnly, .deny] {
            setup.permissions.setAssistantAccess(record, for: origin)
            #expect(!setup.opens(), "a \(record) record keeps its own rule")
            #expect(setup.opens(other), "another website still follows the default")
        }
        setup.permissions.setAssistantAccess(.control, for: origin)
        #expect(setup.opens(), "an Allow Control record agrees with the default")
        setup.permissions.setAssistantAccess(nil, for: origin)
        #expect(setup.opens())

        // A record cannot turn the default on by itself.
        let off = try makeSetup(follows: false)
        off.permissions.setAssistantAccess(.control, for: origin)
        #expect(!off.opens())
    }

    @Test func privateWindowsNeverFollowIt() throws {
        let setup = try makeSetup()
        let privateBrowser = BrowserModel(context: .shared(for: .privateBrowsing()), windowID: UUID())
        #expect(privateBrowser.opensPrivately)
        #expect(MCPDefaultAccess.level(in: privateBrowser, trust: setup.trust) == .ask)
        #expect(!MCPDefaultAccess.opens(Self.shop, client: setup.client, in: privateBrowser, trust: setup.trust))
    }

    // MARK: Where it is stored

    @Test func theSwitchAndTheLevelLiveInTheKeychainDocument() throws {
        let setup = try makeSetup(follows: true, keychain: .readOnly)
        #expect(setup.trust.appsFollowDefault)
        #expect(setup.trust.appsDefaultLevel == .readOnly)

        let reloaded = MCPTrustStore(storage: setup.storage)
        reloaded.loadIfNeeded()
        #expect(reloaded.appsFollowDefault)
        #expect(reloaded.appsDefaultLevel == .readOnly)

        try setup.trust.setAppsDefaultLevel(.control)
        reloaded.reload()
        #expect(reloaded.appsDefaultLevel == .control)
        #expect(reloaded.appsFollowDefault, "keeping the level in step does not turn the switch on or off")
    }

    @Test func theLevelIsKeptInStepOnlyWhileFollowingIsOn() throws {
        let setup = try makeSetup(follows: false, keychain: .ask)
        let writes = setup.storage.writes
        try setup.trust.setAppsDefaultLevel(.control)
        #expect(setup.trust.appsDefaultLevel == .ask, "nothing to keep in step while it is off")
        #expect(setup.storage.writes == writes, "and no keychain write for someone who never turned it on")

        try setup.trust.setAppsFollowDefault(true, level: .readOnly)
        try setup.trust.setAppsDefaultLevel(.control)
        #expect(setup.trust.appsDefaultLevel == .control)
        try setup.trust.setAppsDefaultLevel(.ask)
        #expect(setup.trust.appsDefaultLevel == .ask)
    }

    @Test func aDocumentWithoutTheKeysIsOffAndOneWithAnUnknownLevelReadsAsAsk() {
        let old = MCPTrustStore(storage: MemoryTrustStorage(data: Data(#"{"version":1,"clients":[]}"#.utf8)))
        old.loadIfNeeded()
        #expect(old.isAvailable)
        #expect(!old.appsFollowDefault && old.appsDefaultLevel == .ask)

        for level in ["bogus", "deny", ""] {
            let data = Data(#"{"version":1,"appsFollowDefault":true,"appsDefaultLevel":"\#(level)"}"#.utf8)
            let store = MCPTrustStore(storage: MemoryTrustStorage(data: data))
            store.loadIfNeeded()
            #expect(store.isAvailable, "level \(level) must not make the document unreadable")
            #expect(store.appsFollowDefault)
            #expect(store.appsDefaultLevel == .ask)
        }
    }

    @Test func noAccessIsStoredAsAskAndAnUnavailableStoreRefusesTheChange() throws {
        let setup = try makeSetup()
        try setup.trust.setAppsDefaultLevel(.deny)
        #expect(setup.trust.appsDefaultLevel == .ask)
        try setup.trust.setAppsFollowDefault(true, level: .deny)
        #expect(setup.trust.appsDefaultLevel == .ask)

        let unavailable = MCPTrustStore(storage: MemoryTrustStorage(refusesReads: true))
        unavailable.loadIfNeeded()
        #expect(throws: MCPTrustStore.Failure.unavailable) { try unavailable.setAppsFollowDefault(true, level: .control) }
        #expect(!unavailable.appsFollowDefault)
    }

    @Test func aFailedWriteLeavesTheSettingAsItWas() throws {
        let setup = try makeSetup(follows: false, keychain: .ask)
        setup.storage.refuseWrites()
        #expect(throws: MCPTrustStore.Failure.storage) { try setup.trust.setAppsFollowDefault(true, level: .control) }
        #expect(!setup.trust.appsFollowDefault && setup.trust.appsDefaultLevel == .ask)
        #expect(!setup.opens())
    }

    @Test func changingTheSwitchTellsLiveConnections() throws {
        let setup = try makeSetup(follows: false)
        final class Count {
            var value = 0
        }
        let changes = Count()
        setup.trust.onChange { changes.value += 1 }
        try setup.trust.setAppsFollowDefault(true, level: .control)
        #expect(changes.value == 1)
        try setup.trust.setAppsFollowDefault(true, level: .control)
        #expect(changes.value == 1, "nothing changed")
        try setup.trust.setAppsFollowDefault(false, level: .control)
        #expect(changes.value == 2)
    }
}
