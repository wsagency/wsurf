// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Synchronization
import Testing

@testable import WSurf

// Input History kept with a vault: the private key sealed to an inbox key that only the vault's Input History key opens, recording
// while the vault is locked, the one-time move of today's key, Delete Vault, and the key the vault store derives. Synthetic values,
// temporary directories and in-memory keys only; nothing here touches the real Keychain.

/// In-memory key storage that counts the reads that could have shown a prompt, and can refuse or damage writes.
nonisolated final class InputHistoryProbeStorage: AutofillSecureStorage {
    private struct State {
        var promptableReads = 0
        var failsWrites = false
        var damagesNextWrite = false
    }

    let memory = MemoryAutofillStorage()
    private let state = Mutex(State())

    /// Reads whose context was allowed to prompt.
    var promptableReads: Int {
        state.withLock { $0.promptableReads }
    }

    func failWrites(_ fails: Bool) {
        state.withLock { $0.failsWrites = fails }
    }

    /// The next write stores the data with its last byte flipped, as a damaged write would.
    func damageNextWrite() {
        state.withLock { $0.damagesNextWrite = true }
    }

    func read(service: String, context: LAContext) throws -> Data? {
        let promptable = !context.interactionNotAllowed
        state.withLock { $0.promptableReads += promptable ? 1 : 0 }
        return try memory.read(service: service, context: context)
    }

    func write(_ data: Data, service: String, context: LAContext) throws {
        let (fails, damages) = state.withLock { state -> (Bool, Bool) in
            defer { state.damagesNextWrite = false }
            return (state.failsWrites, state.damagesNextWrite)
        }
        if fails {
            throw AutofillVaultError.keychain(errSecInteractionNotAllowed)
        }
        var stored = data
        if damages, let last = stored.indices.last {
            stored[last] ^= 0xFF
        }
        try memory.write(stored, service: service, context: context)
    }

    func erase(service: String) throws {
        try memory.erase(service: service)
    }

    func exists(service: String) throws -> Bool {
        try memory.exists(service: service)
    }
}

/// One store over a temporary directory and probe key storages, and a vault key made up for it.
struct InputHistoryVaultFixture {
    let root: URL
    let privateKeys: InputHistoryProbeStorage
    let publicKeys: InputHistoryProbeStorage
    let clock: InputHistoryTestWallClock
    let vault: InputHistoryVaultKey
    let store: InputHistoryStore

    /// A vault's Input History key as `ProfileVaultStore.inputHistoryKey` would give it: random here.
    static func key(_ vaultID: UUID = UUID()) -> InputHistoryVaultKey {
        InputHistoryVaultKey(vaultID: vaultID, key: SymmetricKey(size: .bits256))
    }

    init() {
        let clock = InputHistoryTestWallClock()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InputHistoryVaultTests-\(UUID().uuidString)", isDirectory: true)
        let privateKeys = InputHistoryProbeStorage()
        let publicKeys = InputHistoryProbeStorage()
        self.root = root
        self.privateKeys = privateKeys
        self.publicKeys = publicKeys
        self.clock = clock
        vault = Self.key()
        store = InputHistoryStore(
            profileID: UUID(),
            directory: root.appendingPathComponent("InputHistory", isDirectory: true),
            privateKeys: privateKeys,
            publicKeys: publicKeys,
            ownsSession: true,
            now: { clock.now() }
        )
    }

    var files: [URL] {
        let directory = root.appendingPathComponent("InputHistory", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".wih") }.sorted().map { directory.appendingPathComponent($0) }
    }

    /// The private key item as it is stored.
    func storedPrivateKey() throws -> Data? {
        try privateKeys.memory.read(service: store.service, context: LAContext())
    }

    /// The item that keeps Input History with a vault.
    func storedBinding() throws -> Data? {
        try publicKeys.memory.read(service: "\(store.service).vault", context: LAContext())
    }

    func record(_ values: [String]) async throws {
        for value in values {
            _ = try await store.record(.testSample(value), key: "field-\(value)", retention: .thirtyMinutes)
            clock.advance(1)
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// What a test's vault key source answers, and what it was asked.
final class InputHistoryVaultAnswers {
    var answer: Result<InputHistoryVaultKey?, InputHistoryError> = .success(nil)
    var asked: [UUID?] = []

    var source: InputHistory.VaultKeySource {
        { [self] _, bound in
            asked.append(bound)
            return try answer.get()
        }
    }
}

struct InputHistoryVaultTests {
    private let reason = "Test"

    private func values(_ entries: [InputHistoryEntry]) -> [String] {
        entries.map(\.payload.value)
    }

    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Wrapping

    @Test func aKeptPrivateKeyOpensOnlyWithItsVaultsKey() async throws {
        let fixture = InputHistoryVaultFixture()
        defer { fixture.cleanUp() }
        try await fixture.record(["first"])
        let raw = try #require(try fixture.storedPrivateKey())
        #expect(raw.count == 32, "before any vault: today's key")
        #expect(try await fixture.store.boundVault() == nil)

        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)) == ["first"])

        let kept = try #require(try fixture.storedPrivateKey())
        let binding = try #require(try fixture.storedBinding())
        #expect(kept.first == 2 && kept.count == 1 + 32 + 32 + 16)
        #expect(binding.first == 2 && binding.dropFirst().prefix(36) == Data(fixture.vault.vaultID.uuidString.utf8))
        #expect(kept.range(of: raw) == nil && binding.range(of: raw) == nil, "the raw key is stored nowhere")
        #expect(try await fixture.store.boundVault() == fixture.vault.vaultID)

        // Without the vault, or with another vault's key, nothing is read: not even the private key, so no Touch ID either.
        let reads = fixture.privateKeys.memory.readCount
        await #expect(throws: InputHistoryError.vaultLocked) { _ = try await fixture.store.unlock(reason: reason) }
        await #expect(throws: InputHistoryError.vaultLocked) {
            _ = try await fixture.store.unlock(reason: reason, vault: InputHistoryVaultFixture.key())
        }
        #expect(fixture.privateKeys.memory.readCount == reads)
        #expect(fixture.files.count == 1)
        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)) == ["first"])

        // A forged key for the right vault opens nothing and fails closed, as a mismatched pair does.
        let forged = InputHistoryVaultFixture.key(fixture.vault.vaultID)
        await #expect(throws: InputHistoryError.keysUnusable) { _ = try await fixture.store.unlock(reason: reason, vault: forged) }
        #expect(fixture.files.isEmpty)
        #expect(try fixture.storedBinding() == nil)
        #expect(fixture.privateKeys.memory.itemCount == 0 && fixture.publicKeys.memory.itemCount == 0)
    }

    // MARK: - Recording while the vault is locked

    @Test func recordingWhileTheVaultIsLockedNeverPromptsAndOpensAfterUnlock() async throws {
        let fixture = InputHistoryVaultFixture()
        defer { fixture.cleanUp() }
        try await fixture.record(["bound"])
        _ = try await fixture.store.unlock(reason: reason, vault: fixture.vault)
        // Both keys go with the entries; the binding stays, so the next pair is kept with the vault from the start.
        _ = try await fixture.store.clear()
        #expect(fixture.privateKeys.memory.itemCount == 0)
        #expect(try fixture.storedBinding() != nil)

        let before = (fixture.privateKeys.memory.readCount, fixture.privateKeys.promptableReads, fixture.publicKeys.promptableReads)
        // A read of the private key would fail here, as a canceled prompt does: recording must not notice.
        fixture.privateKeys.memory.failReads(with: errSecAuthFailed)
        try await fixture.record(["one", "two"])
        _ = try await fixture.store.forget("field-nothing")
        fixture.privateKeys.memory.failReads(with: nil)

        #expect(fixture.privateKeys.memory.readCount == before.0, "recording never reads the private key")
        #expect(fixture.privateKeys.promptableReads == before.1 && fixture.publicKeys.promptableReads == before.2, "nothing it reads may prompt")
        #expect(try fixture.storedPrivateKey()?.first == 2, "the new private key is kept with the vault")

        await #expect(throws: InputHistoryError.vaultLocked) { _ = try await fixture.store.unlock(reason: reason) }
        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)) == ["two", "one"])
    }

    // MARK: - Moving today's key

    @Test func todaysKeyMovesUnderTheVaultOnceAndEveryEntryStays() async throws {
        let fixture = InputHistoryVaultFixture()
        defer { fixture.cleanUp() }
        try await fixture.record(["one", "two", "three"])
        let bodies = try fixture.files.map { try Data(contentsOf: $0) }
        let raw = try #require(try fixture.storedPrivateKey())
        // A profile without a vault: today's key opens with Touch ID alone, as before.
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["three", "two", "one"])
        #expect(try fixture.storedPrivateKey() == raw)

        let writes = fixture.privateKeys.memory.writeCount
        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)) == ["three", "two", "one"])
        #expect(fixture.privateKeys.memory.writeCount == writes + 1, "one write moves it")
        #expect(try fixture.files.map { try Data(contentsOf: $0) } == bodies, "the entries are not encrypted again")
        let kept = try #require(try fixture.storedPrivateKey())
        #expect(kept != raw && kept.first == 2)

        // Once: opening again writes nothing.
        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)).count == 3)
        #expect(fixture.privateKeys.memory.writeCount == writes + 1)
        #expect(try fixture.storedPrivateKey() == kept)
    }

    @Test func aMoveThatFailsPutsTodaysKeyBackAndLosesNothing() async throws {
        let fixture = InputHistoryVaultFixture()
        defer { fixture.cleanUp() }
        try await fixture.record(["kept"])
        let raw = try #require(try fixture.storedPrivateKey())

        // The write is refused.
        fixture.privateKeys.failWrites(true)
        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)) == ["kept"])
        fixture.privateKeys.failWrites(false)
        #expect(try fixture.storedPrivateKey() == raw)

        // The write lands damaged: reading it back finds that, and the raw key is written back.
        fixture.privateKeys.damageNextWrite()
        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)) == ["kept"])
        #expect(try fixture.storedPrivateKey() == raw)

        // The next opening moves it, and it keeps opening.
        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)) == ["kept"])
        #expect(try fixture.storedPrivateKey()?.first == 2)
        #expect(values(try await fixture.store.unlock(reason: reason, vault: fixture.vault)) == ["kept"])
    }

    // MARK: - Deleting the vault

    @Test func deletingTheVaultDeletesWhatItKeptAndRecordingStartsOver() async throws {
        let fixture = InputHistoryVaultFixture()
        defer { fixture.cleanUp() }
        try await fixture.record(["one", "two"])
        _ = try await fixture.store.unlock(reason: reason, vault: fixture.vault)
        try await fixture.record(["three"])
        let other = UUID()
        #expect(await fixture.store.count(keptWith: fixture.vault.vaultID) == 3)
        #expect(await fixture.store.count(keptWith: other) == 0)

        // Another vault changes nothing.
        #expect(try await fixture.store.vaultDeleted(other).count == 3)
        #expect(fixture.files.count == 3)
        #expect(try fixture.storedBinding() != nil)

        #expect(try await fixture.store.vaultDeleted(fixture.vault.vaultID) == InputHistoryStatus(count: 0, nextExpiry: nil))
        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.memory.itemCount == 0 && fixture.publicKeys.memory.itemCount == 0, "both keys and the binding are gone")

        // Recording goes on with today's kind of key, which opens without a vault.
        try await fixture.record(["after"])
        #expect(try fixture.storedPrivateKey()?.count == 32)
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["after"])
    }

    @Test func erasingTheProfileAlsoRemovesTheBinding() async throws {
        let fixture = InputHistoryVaultFixture()
        defer { fixture.cleanUp() }
        try await fixture.record(["one"])
        _ = try await fixture.store.unlock(reason: reason, vault: fixture.vault)
        try await fixture.store.erase()
        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.memory.itemCount == 0 && fixture.publicKeys.memory.itemCount == 0)
    }

    // MARK: - Opening through InputHistory

    @Test func openingAsksForTheVaultOnlyWithSomethingToOpen() async throws {
        let answers = InputHistoryVaultAnswers()
        let vault = InputHistoryVaultFixture.key()
        answers.answer = .success(vault)
        let harness = InputHistoryHarness(vaultKey: answers.source)
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()

        try await harness.history.unlock(profile)
        #expect(answers.asked.isEmpty, "nothing to open asks for no vault")

        try await harness.seed(profile, ["secret"])
        try await harness.history.unlock(profile)
        #expect(harness.history.unlocked[profile.id]?.map(\.payload.value) == ["secret"])
        harness.history.lock(profileID: profile.id)
        try await harness.history.unlock(profile)
        #expect(answers.asked == [nil, vault.vaultID], "first the vault that will keep it, then the one that does")
    }

    @Test func aLockedVaultKeepsTheEntriesClosedWhileRecordingGoesOn() async throws {
        let answers = InputHistoryVaultAnswers()
        let vault = InputHistoryVaultFixture.key()
        answers.answer = .success(vault)
        let harness = InputHistoryHarness(vaultKey: answers.source)
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["before"])
        try await harness.history.unlock(profile)
        harness.history.lock(profileID: profile.id)

        answers.answer = .failure(.vaultLocked)
        harness.history.record(.testSample("while locked"), key: "b", profile: profile, retention: .thirtyMinutes)
        await harness.history.drain(profileID: profile.id)
        #expect(harness.history.count(for: profile.id) == 2)
        await #expect(throws: InputHistoryError.vaultLocked) { try await harness.history.unlock(profile) }
        #expect(harness.history.unlocked[profile.id] == nil)
        let message = try #require(InputHistoryListModel.message(for: InputHistoryError.vaultLocked))
        #expect(message != InputHistoryListModel.message(for: InputHistoryError.invalid))

        answers.answer = .success(vault)
        try await harness.history.unlock(profile)
        #expect(harness.history.unlocked[profile.id]?.map(\.payload.value) == ["while locked", "before"])
    }

    @Test func aVaultDeletedUnseenIsClearedOnOpeningAndSaysSo() async throws {
        let answers = InputHistoryVaultAnswers()
        answers.answer = .success(InputHistoryVaultFixture.key())
        let harness = InputHistoryHarness(vaultKey: answers.source)
        defer { harness.cleanUp() }
        let profile = harness.makeProfile()
        try await harness.seed(profile, ["secret"])
        try await harness.history.unlock(profile)
        harness.history.lock(profileID: profile.id)

        answers.answer = .failure(.vaultDeleted)
        await #expect(throws: InputHistoryError.vaultDeleted) { try await harness.history.unlock(profile) }
        await harness.history.drain(profileID: profile.id)
        #expect(harness.history.count(for: profile.id) == 0)
        #expect(!harness.exists(profile))
        let message = try #require(InputHistoryListModel.message(for: InputHistoryError.vaultDeleted))
        #expect(message != InputHistoryListModel.message(for: InputHistoryError.invalid))

        // Recording starts over with today's key.
        answers.answer = .success(nil)
        harness.history.record(.testSample("new"), key: "c", profile: profile, retention: .thirtyMinutes)
        await harness.history.drain(profileID: profile.id)
        try await harness.history.unlock(profile)
        #expect(harness.history.unlocked[profile.id]?.map(\.payload.value) == ["new"])
    }

    // MARK: - Real vaults

    @Test func eachVaultGivesItsOwnInputHistoryKeyAndNeverItsDEK() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let first = try await vaults[0].manager.inputHistoryKey()
            let second = try await vaults[1].manager.inputHistoryKey()
            #expect(first.vaultID == vaults[0].vaultID && second.vaultID == vaults[1].vaultID)
            #expect(bytes(first.key) != bytes(second.key))
            let store = try CredentialManager.store(for: profile)
            let dek = try #require(await store.grants[vaults[0].vaultID]?.dek)
            #expect(bytes(first.key) != bytes(dek))

            // Locked, it gives nothing; unlocked again, the same key, so what was kept with it still opens.
            vaults[0].manager.lock(reason: .manual)
            await #expect(throws: CredentialVaultError.self) { _ = try await vaults[0].manager.inputHistoryKey() }
            try await VaultManagerFixture.unlock(vaults[0])
            let again = try await vaults[0].manager.inputHistoryKey()
            #expect(bytes(again.key) == bytes(first.key))
        }
    }

    @Test func theLiveVaultKeyIsTheDefaultVaultsOrTheBoundOnesAndNeverPrompts() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .locked]) { profile, passkeys, vaults in
            let asserted = passkeys.assertions.count
            let chosen = try #require(try await InputHistory.liveVaultKey(for: profile, bound: nil))
            #expect(chosen.vaultID == vaults[0].vaultID, "the default vault keeps it")
            let expected = try await vaults[0].manager.inputHistoryKey()
            #expect(bytes(chosen.key) == bytes(expected.key))
            #expect(try await InputHistory.liveVaultKey(for: profile, bound: vaults[0].vaultID)?.vaultID == vaults[0].vaultID)

            await #expect(throws: InputHistoryError.vaultLocked) { _ = try await InputHistory.liveVaultKey(for: profile, bound: vaults[1].vaultID) }
            await #expect(throws: InputHistoryError.vaultDeleted) { _ = try await InputHistory.liveVaultKey(for: profile, bound: UUID()) }
            vaults[0].manager.lock(reason: .manual)
            await #expect(throws: InputHistoryError.vaultLocked) { _ = try await InputHistory.liveVaultKey(for: profile, bound: nil) }
            #expect(passkeys.assertions.count == asserted, "no passkey was asked for")
        }
    }

    @Test func aProfileWithoutAVaultKeepsTodaysKey() async throws {
        try await VaultManagerFixture.with(vaults: []) { profile, _, _ in
            #expect(try await InputHistory.liveVaultKey(for: profile, bound: nil)?.vaultID == nil)
            // A key already kept with a vault is never given up for lost on this: it waits.
            await #expect(throws: InputHistoryError.vaultLocked) { _ = try await InputHistory.liveVaultKey(for: profile, bound: UUID()) }
        }
    }

    @Test func deletingTheVaultInCredentialsNamesAndDeletesWhatItKept() async throws {
        try await VaultManagerFixture.exclusive {
            try await VaultManagerFixture.with(vaults: [.locked, .locked]) { profile, passkeys, vaults in
                let harness = InputHistoryHarness(vaultKey: InputHistory.liveVaultKey)
                let saved = InputHistory.shared
                InputHistory.shared = harness.history
                defer { InputHistory.shared = saved }
                let model = CredentialSettingsModel(profile: profile, exchange: CredentialExchangeCoordinator(), native: passkeys.native)
                await model.load()
                await model.select(vaultID: vaults[0].vaultID)
                await model.unlock(in: VaultManagerFixture.anchor())
                #expect(model.isUnlocked)

                try await harness.seed(profile, ["one", "two"])
                try await harness.history.unlock(profile)
                #expect(harness.history.unlocked[profile.id]?.count == 2)
                #expect(await harness.history.entries(keptWith: vaults[0].vaultID, in: profile) == 2)
                #expect(await harness.history.entries(keptWith: vaults[1].vaultID, in: profile) == 0)

                // Vault 1 holds no credential, yet it is not deleted at once: the sheet names the entries that go with it.
                await model.requestVaultDeletion()
                let pending = try #require(model.pendingVaultDeletion)
                #expect(pending.counts.inputHistory == 2 && pending.counts.credentials == 0)
                #expect(model.vaults.count == 2)

                #expect(await model.confirmVaultDeletion(typedName: pending.name, in: VaultManagerFixture.anchor()))
                await harness.history.drain(profileID: profile.id)
                #expect(harness.history.count(for: profile.id) == 0)
                #expect(harness.history.unlocked[profile.id] == nil)
                #expect(!harness.exists(profile))
            }
        }
    }
}
