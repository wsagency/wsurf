// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Developer sites, the Developer profile, standing levels and where they are stored. No window, page or keychain.
@MainActor
struct MCPDeveloperAccessTests {
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    private func matches(_ text: String, sites: [String] = [], thisMac: Bool = true) throws -> Bool {
        MCPDeveloperAccess.matches(try url(text), sites: sites, includesThisMac: thisMac)
    }

    private func store(_ storage: MemoryTrustStorage = MemoryTrustStorage()) -> MCPTrustStore {
        let trust = MCPTrustStore(storage: storage)
        trust.loadIfNeeded()
        return trust
    }

    // MARK: Developer sites

    @Test(arguments: [
        "http://localhost:3000/", "https://localhost/", "http://127.0.0.1:5173/app?x=1", "http://[::1]:8080/",
        "http://LOCALHOST./x", "https://127.0.0.1:8443", "http://[0:0:0:0:0:0:0:1]/",
    ])
    func thisMacCoversLoopbackOnAnyPort(address: String) throws {
        #expect(try matches(address))
    }

    @Test(arguments: [
        "http://127.0.0.2/", "http://0.0.0.0:3000/", "http://foo.localhost:3000/", "http://localhost.evil.com/",
        "http://localhost@evil.com/", "http://user:secret@localhost:3000/", "ftp://localhost/", "file:///tmp/x",
        "http://[::ffff:127.0.0.1]/", "http://2130706433/", "https://example.com/", "http://192.168.1.10:3000/",
    ])
    func thisMacCoversNothingElse(address: String) throws {
        #expect(try !matches(address))
    }

    @Test func turningThisMacOffLeavesOnlyListedSites() throws {
        #expect(try !matches("http://localhost:3000/", thisMac: false))
        #expect(try matches("http://localhost:3000/", sites: ["localhost:3000"], thisMac: false))
        #expect(try !matches("http://localhost:3001/", sites: ["localhost:3000"], thisMac: false))
    }

    @Test func listedSitesMatchExactHostsAndListedPortsOnly() throws {
        let sites = ["staging.example.com", "qa.example.com:8443", "[fd00::5]:9000", "10.1.2.3"]
        #expect(try matches("https://staging.example.com/", sites: sites))
        #expect(try matches("http://STAGING.example.com./page", sites: sites))
        // A site without a port is the scheme's own port: not every service on the host.
        #expect(try !matches("https://staging.example.com:8443/", sites: sites))
        #expect(try !matches("http://staging.example.com:3000/", sites: sites))
        #expect(try !matches("https://api.staging.example.com/", sites: sites))
        #expect(try !matches("https://example.com/", sites: sites))
        #expect(try !matches("https://staging.example.com.evil.test/", sites: sites))
        #expect(try matches("https://qa.example.com:8443/", sites: sites))
        #expect(try !matches("https://qa.example.com/", sites: sites))
        #expect(try matches("http://[fd00::5]:9000/", sites: sites))
        #expect(try !matches("http://[fd00::5]/", sites: sites))
        #expect(try matches("http://10.1.2.3/", sites: sites))
        #expect(try !matches("http://10.1.2.4/", sites: sites))
        #expect(try !matches("https://user@staging.example.com/", sites: sites))
    }

    @Test(arguments: [
        "*.example.com", "10.0.0.0/8", "example.com/path", "http://user@example.com", "ex ample.com", "", "  ", "0.0.0.0",
        "2130706433", "256.1.1.1", "example.com:0", "example.com:99999", "example.com:", "::1", "[::1", "[]", "exämple.com",
        "-bad.example.com", "a..b", "example.com?x=1", "example.com#x", "ftp://example.com", "%65xample.com", "a:b:c",
        "[example.com]:80", "http://", "example.com:8o", "127.1", "0x7f.0.0.1", "010.0.0.1", "1.2.3", "1.2.3.4.5", "foo.0x10", "foo.123",
    ])
    func unacceptableSitesAreRefused(text: String) {
        #expect(MCPDeveloperAccess.normalizedSite(text) == nil)
    }

    @Test func aSiteIsStoredInOneCanonicalForm() {
        #expect(MCPDeveloperAccess.normalizedSite(" Staging.Example.COM ") == "staging.example.com")
        #expect(MCPDeveloperAccess.normalizedSite("HTTPS://Staging.Example.com:8443/") == "staging.example.com:8443")
        #expect(MCPDeveloperAccess.normalizedSite("http://staging.example.com./") == "staging.example.com")
        #expect(MCPDeveloperAccess.normalizedSite("[0:0:0:0:0:0:0:1]:3000") == "[::1]:3000")
        #expect(MCPDeveloperAccess.normalizedSite("10.1.2.3:80") == "10.1.2.3:80")
        #expect(MCPDeveloperAccess.normalizedSite("localhost") == "localhost")
    }

    // MARK: The Developer profile

    @Test func theEverydayProfileIsNeverTheDeveloperProfileUnlessChosen() throws {
        let trust = store()
        let developer = Profile(id: UUID(), name: "Developer", symbol: "hammer", color: .teal)
        #expect(trust.developerProfileID == nil)
        #expect(!MCPDeveloperAccess.isDeveloperProfile(.original(), trust: trust))
        #expect(!MCPDeveloperAccess.isDeveloperProfile(developer, trust: trust))

        try trust.setDeveloperProfile(developer.id, dedicated: true)
        #expect(MCPDeveloperAccess.isDeveloperProfile(developer, trust: trust))
        #expect(!MCPDeveloperAccess.isDeveloperProfile(.original(), trust: trust))
        #expect(!MCPDeveloperAccess.needsConfirmation(choosing: developer.id, trust: trust))
        // The everyday profile only counts once it is the explicit choice, and that choice asks first.
        #expect(MCPDeveloperAccess.needsConfirmation(choosing: Profile.originalID, trust: trust))
        try trust.setDeveloperProfile(Profile.originalID)
        #expect(MCPDeveloperAccess.isDeveloperProfile(.original(), trust: trust))
        #expect(!MCPDeveloperAccess.isDeveloperProfile(developer, trust: trust))
        try trust.setDeveloperProfile(nil)
        #expect(!MCPDeveloperAccess.isDeveloperProfile(.original(), trust: trust))
    }

    @Test func privateBrowsingIsNeverTheDeveloperProfile() throws {
        let trust = store()
        #expect(throws: MCPTrustStore.Failure.invalidProfile) { try trust.setDeveloperProfile(Profile.privateID) }
        #expect(trust.developerProfileID == nil)
        // Even a stored document that names it.
        let seeded = #"{"version":1,"clients":[],"developerProfileID":"\#(Profile.privateID.uuidString)"}"#
        let planted = store(MemoryTrustStorage(data: Data(seeded.utf8)))
        #expect(planted.developerProfileID == Profile.privateID)
        #expect(!MCPDeveloperAccess.isDeveloperProfile(.privateBrowsing(), trust: planted))
    }

    @Test func theDeveloperProfileIsCreatedAndChosenWithoutAskingAgain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let catalog = ProfileStore(file: file)
        let trust = store()
        let profile = try MCPDeveloperAccess.createDeveloperProfile(in: catalog, trust: trust)
        #expect(catalog.profiles.contains(profile))
        #expect(!profile.isOriginal && !profile.isPrivate)
        #expect(trust.developerProfileID == profile.id)
        #expect(!MCPDeveloperAccess.needsConfirmation(choosing: profile.id, trust: trust))

        // Without the keychain nothing is created: the profile would not be usable.
        let before = catalog.profiles.count
        let unavailable = store(MemoryTrustStorage(refusesReads: true))
        #expect(throws: MCPTrustStore.Failure.unavailable) {
            try MCPDeveloperAccess.createDeveloperProfile(in: catalog, trust: unavailable)
        }
        #expect(catalog.profiles.count == before)
    }

    // MARK: Stored settings

    @Test func developerSettingsPersistAndSurviveAReload() throws {
        let storage = MemoryTrustStorage()
        let trust = store(storage)
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        let profile = UUID()
        try trust.setStanding(.developer, for: client.id)
        try trust.setPaused(true, for: client.id)
        #expect(try trust.addDeveloperSite("Staging.Example.com:8443") == "staging.example.com:8443")
        try trust.addDeveloperSite("staging.example.com:8443")
        try trust.setIncludesThisMac(false)
        try trust.setDeveloperProfile(profile, dedicated: true)

        let reopened = store(storage)
        #expect(reopened.client(id: client.id)?.standing == .developer)
        #expect(reopened.client(id: client.id)?.paused == true)
        #expect(reopened.developerSites == ["staging.example.com:8443"])
        #expect(!reopened.includesThisMac)
        #expect(reopened.developerProfileID == profile)
        #expect(reopened.dedicatedProfileID == profile)

        try reopened.removeDeveloperSite("staging.example.com:8443")
        #expect(store(storage).developerSites.isEmpty)
        // Pairing changes keep the developer settings.
        try reopened.pair(token: SyntheticToken.second, name: "Codex", kind: .codex)
        #expect(store(storage).developerProfileID == profile)
    }

    @Test func aDocumentFromBeforeThisSettingStillLoadsWithThisMacOn() throws {
        let profile = UUID()
        let older = #"{"version":1,"clients":[],"developerSites":["staging.example.test"],"developerProfileID":"\#(profile.uuidString)"}"#
        let trust = store(MemoryTrustStorage(data: Data(older.utf8)))
        #expect(trust.isAvailable)
        #expect(trust.includesThisMac)
        #expect(trust.developerSites == ["staging.example.test"])
        #expect(trust.developerProfileID == profile)
        #expect(trust.dedicatedProfileID == nil)
    }

    @Test func aFailedWriteLeavesTheDeveloperSettingsUnchanged() throws {
        let storage = MemoryTrustStorage()
        let trust = store(storage)
        let client = try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        storage.refuseWrites()
        #expect(throws: MCPTrustStore.Failure.storage) { try trust.setStanding(.developer, for: client.id) }
        #expect(throws: MCPTrustStore.Failure.storage) { try trust.addDeveloperSite("staging.example.com") }
        #expect(throws: MCPTrustStore.Failure.storage) { try trust.setDeveloperProfile(UUID()) }
        #expect(trust.client(id: client.id)?.standing == .off)
        #expect(trust.developerSites.isEmpty)
        #expect(trust.developerProfileID == nil)
    }

    @Test func invalidAndExcessSitesAreRefusedBeforeAnythingIsStored() throws {
        let storage = MemoryTrustStorage()
        let trust = store(storage)
        let writes = storage.writes
        for text in ["*.example.com", "10.0.0.0/8", "http://user@example.com", ""] {
            #expect(throws: MCPTrustStore.Failure.invalidSite) { try trust.addDeveloperSite(text) }
        }
        #expect(storage.writes == writes)
        for index in 0..<MCPDeveloperAccess.maximumSites {
            try trust.addDeveloperSite("site\(index).example.com")
        }
        #expect(throws: MCPTrustStore.Failure.tooManySites) { try trust.addDeveloperSite("one-more.example.com") }
        #expect(trust.developerSites.count == MCPDeveloperAccess.maximumSites)
    }

    @Test func anUnavailableStoreChangesNothingAndMatchesNothing() throws {
        let storage = MemoryTrustStorage(refusesReads: true)
        let trust = store(storage)
        #expect(!trust.isAvailable)
        #expect(throws: MCPTrustStore.Failure.unavailable) { try trust.addDeveloperSite("staging.example.com") }
        #expect(throws: MCPTrustStore.Failure.unavailable) { try trust.setIncludesThisMac(false) }
        #expect(throws: MCPTrustStore.Failure.unavailable) { try trust.setDeveloperProfile(UUID()) }
        #expect(storage.writes == 0)
        // No keychain, no Developer tier: not even This Mac counts.
        #expect(try !MCPDeveloperAccess.isDeveloperSite(url("http://localhost:3000/"), trust: trust))
        #expect(!MCPDeveloperAccess.isDeveloperProfile(.original(), trust: trust))
    }

    @Test func observersRunAfterEachChangeAndNotForNoOps() throws {
        let trust = store()
        let client = try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        var calls = 0
        trust.onChange { calls += 1 }
        try trust.setStanding(.development, for: client.id)
        #expect(calls == 1)
        try trust.setStanding(.development, for: client.id)
        try trust.setStanding(.off, for: UUID())
        #expect(calls == 1)
        try trust.setPaused(true, for: client.id)
        try trust.addDeveloperSite("staging.example.com")
        try trust.revoke(client.id)
        #expect(calls == 4)
        // Recording that a client was seen changes no access, so it does not wake the live connections.
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = MCPTrustStore(storage: MemoryTrustStorage(), now: { current })
        timed.loadIfNeeded()
        let seen = try timed.pair(token: SyntheticToken.second, name: "Cursor", kind: .cursor)
        var timedCalls = 0
        timed.onChange { timedCalls += 1 }
        current = current.addingTimeInterval(MCPTrustStore.lastUsedInterval + 1)
        timed.touch(seen.id)
        #expect(timed.client(id: seen.id)?.lastUsed == current)
        #expect(timedCalls == 0)
    }

    // MARK: Standing levels

    @Test func aStandingLevelNeedsAPairedUnpausedClientAboveOff() throws {
        let trust = store()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        #expect(MCPDeveloperAccess.standingAccess(for: client, trust: trust) == nil)
        try trust.setStanding(.development, for: client.id)
        // The record in the store decides, not a snapshot taken when the client connected.
        #expect(MCPDeveloperAccess.standingAccess(for: client, trust: trust) == .development)
        try trust.setStanding(.developer, for: client.id)
        #expect(MCPDeveloperAccess.standingAccess(for: client, trust: trust) == .developer)
        try trust.setPaused(true, for: client.id)
        #expect(MCPDeveloperAccess.standingAccess(for: client, trust: trust) == nil)
        try trust.setPaused(false, for: client.id)
        #expect(MCPDeveloperAccess.standingAccess(for: client, trust: trust) == .developer)
        #expect(MCPDeveloperAccess.standingAccess(for: nil, trust: trust) == nil)
        var stranger = PairedClient(id: UUID(), name: "Stranger", kindID: nil, tokenHash: client.tokenHash, created: Date())
        stranger.standing = .developer
        #expect(MCPDeveloperAccess.standingAccess(for: stranger, trust: trust) == nil)
        try trust.revoke(client.id)
        #expect(MCPDeveloperAccess.standingAccess(for: client, trust: trust) == nil)
    }

    @Test func aStoreThatCannotBeReadGrantsNoStandingLevel() throws {
        let trust = store()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(.developer, for: client.id)
        let locked = store(MemoryTrustStorage(refusesReads: true))
        #expect(MCPDeveloperAccess.standingAccess(for: trust.client(id: client.id), trust: locked) == nil)
    }

    @Test func aKeychainStoredLevelCannotBeChangedThroughDefaults() throws {
        let storage = MemoryTrustStorage()
        let trust = store(storage)
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(.development, for: client.id)
        let keys = [
            "mcp.standing", "mcp.standing.\(client.id.uuidString)", "mcp.paused", "mcp.developerSites", "mcp.developerProfileID",
            "mcp.developerProfile", "mcp.includesThisMac", "mcp.developer", "mcp.enabled",
        ]
        let suiteName = "mcp-p4-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            for key in keys + keys.map({ $0 + ".value" }) { UserDefaults.standard.removeObject(forKey: key) }
        }
        for target in [defaults, UserDefaults.standard] {
            for key in keys {
                target.set(["gmail.com"], forKey: key)
                target.set("developer", forKey: key + ".value")
            }
        }
        let reopened = store(storage)
        #expect(MCPDeveloperAccess.standingAccess(for: client, trust: reopened) == .development)
        #expect(reopened.developerSites.isEmpty)
        #expect(reopened.developerProfileID == nil)
        #expect(try !MCPDeveloperAccess.isDeveloperSite(url("https://gmail.com/"), trust: reopened))
        #expect(!MCPDeveloperAccess.isDeveloperProfile(.original(), trust: reopened))
        // And the other direction: a client at Off is not raised by a defaults key.
        let other = try reopened.pair(token: SyntheticToken.second, name: "Codex", kind: .codex)
        #expect(MCPDeveloperAccess.standingAccess(for: other, trust: reopened) == nil)
    }

    @Test func accessLevelsAreOrdered() {
        let levels: [MCPAccessConsent.Access] = [.readOnly, .control, .development, .developer]
        #expect(levels.map(\.rank) == [0, 1, 2, 3])
    }
}
