// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// In-memory stand-in for the keychain item. Tests never reach the real keychain.
final class MemoryTrustStorage: MCPTrustStorage, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var data: Data?
    private var refusesReads: Bool
    private var refusesWrites = false
    private var writeCount = 0

    init(data: Data? = nil, refusesReads: Bool = false) {
        self.data = data
        self.refusesReads = refusesReads
    }

    var stored: Data? {
        lock.withLock { data }
    }

    var writes: Int {
        lock.withLock { writeCount }
    }

    func refuseWrites() {
        lock.withLock { refusesWrites = true }
    }

    func read() throws -> Data? {
        try lock.withLock {
            if refusesReads {
                throw Refused()
            }
            return data
        }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            if refusesWrites {
                throw Refused()
            }
            self.data = data
            writeCount += 1
        }
    }
}

/// Synthetic values only: these tokens belong to no real client.
enum SyntheticToken {
    static let first = String(repeating: "A", count: 43)
    static let second = String(repeating: "B", count: 43)
    static let stranger = String(repeating: "C", count: 43)
}

@MainActor
struct MCPPairingTests {
    private func store(_ storage: MemoryTrustStorage = MemoryTrustStorage(), now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }) -> MCPTrustStore {
        MCPTrustStore(storage: storage, now: now)
    }

    // MARK: Tokens

    @Test func generatedTokensAreRandomWellFormedAndHashToDigests() throws {
        let tokens = try (0..<20).map { _ in try MCPPairing.makeToken() }
        #expect(Set(tokens).count == tokens.count)
        for token in tokens {
            #expect(MCPPairing.isWellFormed(token))
            #expect(MCPPairing.hash(token).count == 32)
            #expect(MCPPairing.hash(token) == MCPPairing.hash(token))
        }
        #expect(MCPPairing.hash(SyntheticToken.first) != MCPPairing.hash(SyntheticToken.second))
    }

    @Test(arguments: ["", "short", String(repeating: "A", count: 44), String(repeating: "+", count: 43),
                      String(repeating: "A", count: 42) + "=", String(repeating: "é", count: 22),
                      ])
    func malformedTokensAreNeverWellFormed(token: String) {
        #expect(!MCPPairing.isWellFormed(token))
        #expect(MCPPairing.helloMessage(token: token) == nil)
    }

    @Test func comparisonIsExactForEqualAndDifferentDigests() {
        let digest = MCPPairing.hash(SyntheticToken.first)
        var flipped = digest
        flipped[flipped.count - 1] ^= 1
        #expect(MCPPairing.constantTimeEquals(digest, digest))
        #expect(!MCPPairing.constantTimeEquals(digest, flipped))
        #expect(!MCPPairing.constantTimeEquals(digest, digest.dropLast()))
        #expect(!MCPPairing.constantTimeEquals(digest, Data()))
    }

    @Test func onlyAWellFormedEnvironmentTokenIsUsed() {
        #expect(MCPPairing.environmentToken([MCPPairing.environmentName: SyntheticToken.first]) == SyntheticToken.first)
        #expect(MCPPairing.environmentToken([MCPPairing.environmentName: "nope"]) == nil)
        #expect(MCPPairing.environmentToken([:]) == nil)
    }

    // MARK: Hello line

    @Test func aHelloLineCarriesItsTokenAndLeavesTheRestForMCP() throws {
        let hello = try #require(MCPPairing.helloMessage(token: SyntheticToken.first))
        #expect(hello.count < MCPHelloGate.maximumBytes)
        var gate = MCPHelloGate()
        let rest = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8) + Data([10])
        #expect(gate.append(hello + Data([10]) + rest) == .hello(token: SyntheticToken.first, rest: rest))
    }

    @Test func aHelloLineSplitIntoSingleBytesIsStillRecognized() throws {
        let line = try #require(MCPPairing.helloMessage(token: SyntheticToken.second)) + Data([10])
        var gate = MCPHelloGate()
        for byte in line.dropLast() {
            #expect(gate.append(Data([byte])) == .undecided)
        }
        #expect(gate.append(Data([10])) == .hello(token: SyntheticToken.second, rest: Data()))
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
        #"{"id":1,"method":"ping"}"#, "[]", "garbage", #"{"wsurf":"other"}"#,
    ])
    func anythingElseReachesMCPByteForByte(first: String) {
        var gate = MCPHelloGate()
        let bytes = Data(first.utf8) + Data([10])
        #expect(gate.append(bytes) == .passthrough(bytes))
    }

    @Test func aFirstChunkThatDivergesLaterIsReturnedWhole() {
        var gate = MCPHelloGate()
        #expect(gate.append(Data(#"{"#.utf8)) == .undecided)
        #expect(gate.append(Data(#""w"#.utf8)) == .undecided)
        #expect(gate.append(Data(#"x":1}"#.utf8) + Data([10])) == .passthrough(Data(#"{"wx":1}"#.utf8) + Data([10])))
    }

    @Test func aHelloWithoutAValidTokenIsConsumedButCarriesNoToken() {
        for line in [#"{"wsurf":"hello","v":1}"#, #"{"wsurf":"hello","v":1,"token":"short"}"#,
                     #"{"wsurf":"hello","v":2,"token":"\#(SyntheticToken.first)"}"#, #"{"wsurf":"hello","v":1,"token":7}"#,
                     #"{"wsurf":"hello","v":1,"#, ] {
            var gate = MCPHelloGate()
            let outcome = gate.append(Data(line.utf8) + Data([10]))
            #expect(outcome == .hello(token: nil, rest: Data()))
        }
    }

    @Test func anOversizedHelloIsRejectedWithOrWithoutANewline() {
        let padding = String(repeating: "x", count: MCPHelloGate.maximumBytes)
        var unterminated = MCPHelloGate()
        #expect(unterminated.append(Data(#"{"wsurf":"hello","pad":"\#(padding)"#.utf8)) == .rejected)
        var terminated = MCPHelloGate()
        #expect(terminated.append(Data(#"{"wsurf":"hello","pad":"\#(padding)"}"#.utf8) + Data([10])) == .rejected)
    }

    // MARK: Trust store

    @Test func aTokenIsNeverStoredOrLoggedInPlainText() throws {
        let storage = MemoryTrustStorage()
        let trust = store(storage)
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        let stored = try #require(storage.stored)
        let text = String(decoding: stored, as: UTF8.self)
        #expect(!text.contains(SyntheticToken.first))
        #expect(!stored.contains(Data(SyntheticToken.first.utf8)))
        #expect(!stored.contains(Data(SyntheticToken.first.utf8).base64EncodedData()))
        let object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let record = try #require((object["clients"] as? [[String: Any]])?.first)
        #expect(record["tokenHash"] as? String == MCPPairing.hash(SyntheticToken.first).base64EncodedString())
        #expect(Set(record.keys).isDisjoint(with: ["token", "secret"]))
        for description in [String(describing: client), String(reflecting: client), String(describing: trust.clients)] {
            #expect(!description.contains(SyntheticToken.first))
        }
        var dumped = ""
        dump(client, to: &dumped)
        #expect(!dumped.contains(SyntheticToken.first))
    }

    @Test func authenticationAcceptsOnlyThePairedToken() throws {
        let trust = store()
        let client = try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        try trust.pair(token: SyntheticToken.second, name: "Cursor", kind: .cursor)
        #expect(trust.authenticate(token: SyntheticToken.first)?.id == client.id)
        #expect(trust.authenticate(token: SyntheticToken.stranger) == nil)
        for malformed in ["", "short", String(repeating: "A", count: 44)] {
            #expect(trust.authenticate(token: malformed) == nil)
        }
        #expect(trust.client(forToken: SyntheticToken.second)?.kind == .cursor)
    }

    @Test func pairedClientsSurviveAReload() throws {
        let storage = MemoryTrustStorage()
        let client = try store(storage).pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        let reopened = store(storage)
        reopened.loadIfNeeded()
        #expect(reopened.isAvailable)
        #expect(reopened.clients.map(\.id) == [client.id])
        #expect(reopened.authenticate(token: SyntheticToken.first)?.name == "Claude Code")
    }

    @Test func rePairRotatesTheTokenAndKeepsTheClient() throws {
        let trust = store()
        let first = try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        let rotated = try trust.pair(token: SyntheticToken.second, name: "Codex", kind: .codex, replacing: first.id)
        #expect(rotated.id == first.id)
        #expect(rotated.created == first.created)
        #expect(trust.clients.count == 1)
        #expect(trust.authenticate(token: SyntheticToken.first) == nil)
        #expect(trust.authenticate(token: SyntheticToken.second)?.id == first.id)
    }

    @Test func sameNamesGetNumbersAndNamesAreCleaned() throws {
        let trust = store()
        let names = try [" Claude\nCode ", "Claude Code", "Claude Code", "  "].enumerated().map { index, name in
            try trust.pair(token: String(repeating: Character(UnicodeScalar(UInt8(65 + index))), count: 43), name: name, kind: nil).name
        }
        #expect(names == ["ClaudeCode", "Claude Code", "Claude Code 2", String(localized: "External app")])
    }

    @Test func revokeInvalidatesTheTokenAndPersists() throws {
        let storage = MemoryTrustStorage()
        let trust = store(storage)
        let kept = try trust.pair(token: SyntheticToken.second, name: "Cursor", kind: .cursor)
        let revoked = try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        try trust.revoke(revoked.id)
        #expect(trust.authenticate(token: SyntheticToken.first) == nil)
        #expect(trust.authenticate(token: SyntheticToken.second)?.id == kept.id)
        let reopened = store(storage)
        reopened.loadIfNeeded()
        #expect(reopened.clients.map(\.id) == [kept.id])
        #expect(reopened.authenticate(token: SyntheticToken.first) == nil)
    }

    @Test func aFailedWriteLeavesTheStoreAndItsTokensUnchanged() throws {
        let storage = MemoryTrustStorage()
        let trust = store(storage)
        let client = try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        storage.refuseWrites()
        #expect(throws: MCPTrustStore.Failure.storage) {
            try trust.pair(token: SyntheticToken.second, name: "Cursor", kind: .cursor)
        }
        #expect(throws: MCPTrustStore.Failure.storage) { try trust.revoke(client.id) }
        #expect(trust.clients.map(\.id) == [client.id])
        #expect(trust.authenticate(token: SyntheticToken.second) == nil)
        #expect(trust.authenticate(token: SyntheticToken.first)?.id == client.id)
    }

    @Test func lastUsedIsRecordedOncePerInterval() throws {
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        let storage = MemoryTrustStorage()
        let trust = MCPTrustStore(storage: storage, now: { current })
        let client = try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        #expect(client.lastUsed == nil)
        let writesAfterPairing = storage.writes
        #expect(trust.authenticate(token: SyntheticToken.first) != nil)
        #expect(trust.client(id: client.id)?.lastUsed == current)
        #expect(storage.writes == writesAfterPairing + 1)
        current = current.addingTimeInterval(MCPTrustStore.lastUsedInterval - 1)
        trust.touch(client.id)
        #expect(storage.writes == writesAfterPairing + 1)
        current = current.addingTimeInterval(2)
        trust.touch(client.id)
        #expect(storage.writes == writesAfterPairing + 2)
        #expect(trust.client(id: client.id)?.lastUsed == current)
    }

    @Test func settingsReservedForLaterAreKeptWhenClientsChange() throws {
        let site = "staging.example.test"
        let profile = UUID()
        let seeded = #"{"version":1,"clients":[],"developerSites":["\#(site)"],"developerProfileID":"\#(profile.uuidString)"}"#
        let storage = MemoryTrustStorage(data: Data(seeded.utf8))
        try store(storage).pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        let stored = try #require(storage.stored)
        let object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(object["developerSites"] as? [String] == [site])
        #expect(object["developerProfileID"] as? String == profile.uuidString)
    }

    @Test(arguments: [0, 1, 2])
    func anUnreadableStoreFailsClosedAndNeverOverwritesWhatItCouldNotRead(scenario: Int) throws {
        let existing = Data(#"{"version":2,"clients":[]}"#.utf8)
        let storage = switch scenario {
        case 0:
            MemoryTrustStorage(refusesReads: true)
        case 1:
            MemoryTrustStorage(data: Data("not json".utf8))
        default:
            MemoryTrustStorage(data: existing)
        }
        let trust = store(storage)
        trust.loadIfNeeded()
        #expect(!trust.isAvailable)
        #expect(trust.clients.isEmpty)
        #expect(trust.authenticate(token: SyntheticToken.first) == nil)
        #expect(throws: MCPTrustStore.Failure.unavailable) {
            try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        }
        #expect(throws: MCPTrustStore.Failure.unavailable) { try trust.revoke(UUID()) }
        #expect(storage.writes == 0)
        if scenario == 2 {
            #expect(storage.stored == existing)
        }
    }

    @Test func aStoreWithoutStorageIsNeverAvailable() {
        let trust = MCPTrustStore(storage: nil)
        trust.loadIfNeeded()
        #expect(!trust.isAvailable)
        #expect(throws: MCPTrustStore.Failure.unavailable) {
            try trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
        }
    }

    @Test func theKeychainItemIsALocalDataProtectionItem() {
        let query = MCPKeychainTrustStorage.query(service: "test.service")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == "test.service")
        #expect(query[kSecAttrSynchronizable as String] == nil)
    }

    @Test func aCopiedConfigurationCarriesATokenOnlyWhenTheAppWasPaired() throws {
        let server = BrowserMCPServer(trustStore: store(), target: { nil }, available: { _ in true })
        func entry(_ text: String) throws -> [String: Any] {
            let root = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let servers = try #require(root["mcpServers"] as? [String: Any])
            return try #require(servers["wsurf"] as? [String: Any])
        }
        #expect(try entry(server.configuration)["env"] == nil)
        let paired = try entry(server.configuration(pairedWith: SyntheticToken.first))
        #expect(paired["env"] as? [String: String] == [MCPPairing.environmentName: SyntheticToken.first])
        #expect(paired["args"] as? [String] == MCPClientConfiguration.arguments)
    }
}
