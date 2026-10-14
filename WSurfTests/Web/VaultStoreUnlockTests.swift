// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Darwin
import Foundation
import GRDB
import Synchronization
import Testing

@testable import WSurf

// Task 6: the §6.8 unlock pipeline of `ProfileVaultStore`, asserted only at the store's public boundary plus the real files and
// defaults. Every store comes from the fixture (`with`/`withEnvironment`), which closes it before the directory is removed.

private nonisolated struct RenameFacts: Sendable {
    let scratchEntries: [String]
    let operationLockHeld: Bool
}

// MARK: - Shared test plumbing (file-private)

private nonisolated struct UnlockTestError: Error {
    let message: String
}

/// A locked, append-only list a `@Sendable` callback or a synchronous file-ops hook records into.
private nonisolated final class UnlockJournal<Value: Sendable>: Sendable {
    private let items = Mutex<[Value]>([])

    func add(_ value: Value) {
        items.withLock { $0.append(value) }
    }

    var all: [Value] {
        items.withLock { $0 }
    }
}

/// `now()` that advances `step` on every read: `.zero` is a constant clock, 300 ms crosses the verifying threshold at the first
/// cancellation poll.
private nonisolated final class UnlockClock: Sendable {
    private let base = ContinuousClock().now
    private let reads = Mutex(0)
    private let step: Duration

    init(step: Duration) {
        self.step = step
    }

    func now() -> ContinuousClock.Instant {
        let count = reads.withLock { value -> Int in
            value += 1
            return value
        }
        return base.advanced(by: step * count)
    }
}

/// Cancels the task that runs an unlock from inside the `verifying` callback, which fires before the task handle exists to
/// capture: whichever of `fire`/`attach` comes second does the cancelling.
private nonisolated final class UnlockCanceller: Sendable {
    private let state = Mutex<(task: Task<Void, any Error>?, fired: Bool)>((nil, false))

    func fire() {
        let task = state.withLock { state -> Task<Void, any Error>? in
            state.fired = true
            return state.task
        }
        task?.cancel()
    }

    func attach(_ task: Task<Void, any Error>) {
        let fired = state.withLock { state -> Bool in
            state.task = task
            return state.fired
        }
        if fired {
            task.cancel()
        }
    }
}

nonisolated func v1Bytes(profileID: UUID, vaultID: UUID = UUID()) throws -> Data {
    let envelope = CredentialVaultEnvelope(
        format: 1,
        profileID: profileID,
        vaultID: vaultID,
        wrappers: [
            CredentialKeyWrapper(
                credentialID: Data([1]), prfInput: Data([2]), nonce: Data(repeating: 3, count: 12),
                ciphertext: Data(repeating: 4, count: 32), tag: Data(repeating: 5, count: 16)
            ),
        ],
        payload: CredentialSealedData(nonce: Data(repeating: 6, count: 12), ciphertext: Data([7, 8, 9]), tag: Data(repeating: 10, count: 16))
    )
    return try CredentialVaultCrypto.encodeEnvelope(envelope)
}

private nonisolated func scratchEntries(in directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: VerificationScratch.directory(in: directory).path)) ?? []
}

/// A test-local non-blocking `flock(LOCK_EX)` on a FRESH descriptor of `Credentials.lock`: it can only fail with `EWOULDBLOCK`
/// while some descriptor (the store's) still holds the operation lock.
nonisolated func operationLockIsHeld(in directory: URL) -> Bool {
    let descriptor = open(directory.appendingPathComponent("Credentials.lock").path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        flock(descriptor, LOCK_UN)
        return false
    }
    return errno == EWOULDBLOCK
}

private nonisolated func setMode(_ mode: Int, _ url: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

/// The error `unlockInitialized` throws, or nil when it returned.
func unlockResult(
    _ f: VaultStoreFixture,
    _ store: ProfileVaultStore,
    vault: UUID? = nil,
    proof: VaultUnlockProof? = nil,
    access: VaultAccess,
    verifying: (@Sendable (Bool) -> Void)? = nil,
    scratchWarning: (@Sendable (URL) -> Void)? = nil
) async -> (any Error)? {
    let target = vault ?? f.vaultID
    let used = proof ?? f.proof(for: target)
    do {
        try await store.unlockInitialized(
            vaultID: target, credentialID: used.credentialID, prf: used.prf, access: access, verifying: verifying, scratchWarning: scratchWarning
        )
        return nil
    } catch {
        return error
    }
}

func expectNoGrant(_ store: ProfileVaultStore, _ vault: UUID, _ access: VaultAccess, sourceLocation: SourceLocation = #_sourceLocation) async {
    await #expect(throws: CredentialVaultError.unauthorized, sourceLocation: sourceLocation) {
        _ = try await store.snapshot(vaultID: vault, using: access)
    }
}

/// The WAL sidecars on disk: the fixture's closed store may leave them, so "no sidecar was created" means "the same set as before".
func sidecars(_ f: VaultStoreFixture) throws -> [String] {
    try f.directoryImage().keys.filter { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") }.sorted()
}

/// Every regular file under the directory except the empty `Credentials.lock` the operation lock creates on acquisition.
func settledImage(_ f: VaultStoreFixture, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Data] {
    var image = try f.directoryImage()
    if let lock = image.removeValue(forKey: "Credentials.lock") {
        #expect(lock.isEmpty, sourceLocation: sourceLocation)
    }
    return image
}

nonisolated func secondVault(of f: VaultStoreFixture) throws -> UUID {
    guard let id = f.secondVaultID else { throw UnlockTestError(message: "fixture has no second vault") }
    return id
}

/// Deletes one vault's head, rows, journal and vault row (heads reference the vault row, so it goes last).
private nonisolated func removeRows(_ f: VaultStoreFixture, vault: UUID) throws {
    try f.mutate { db in
        for table in ["head", "record", "journal", "vault"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE vaultID = ?", arguments: [vault.lowerText])
        }
    }
}

private nonisolated func flipLiveRow(_ f: VaultStoreFixture, vault: UUID, account: CredentialAccount) throws {
    let row = try f.storedRecord(vault, account.id)
    try f.mutate { db in
        try db.execute(
            sql: "UPDATE record SET sealed = ? WHERE vaultID = ? AND recordID = ?",
            arguments: [VaultStoreFixture.flipped(row.sealed), vault.lowerText, account.id.lowerText]
        )
    }
}

// MARK: - Parameters

private nonisolated enum BadAnchor: CaseIterable, Sendable {
    case foreignA3, a3DiffersStubMissing, v1BesideStore, storeMissing, wrongProfile

    var stubAbsent: Bool {
        self == .a3DiffersStubMissing
    }

    var expectedCause: StoreFailCause {
        switch self {
        case .foreignA3:
            .foreignStore  // §6.3 row 5: stub and store agree, A3 names another store
        case .a3DiffersStubMissing:
            .witnessMismatch  // row 8: no stub, A3 disagrees with the store
        case .v1BesideStore:
            .v1AfterMigration  // row 3
        case .storeMissing:
            .storeMissing  // row 6: stub, no store, nothing to resume
        case .wrongProfile:
            .wrongProfile
        }
    }

    func arrange(_ f: VaultStoreFixture) throws {
        switch self {
        case .foreignA3, .a3DiffersStubMissing:
            f.env.defaults.set(UUID().uuidString, forKey: StoreAnchors.witnessKey)
        case .v1BesideStore:
            try v1Bytes(profileID: f.env.profileID).write(to: f.vaultFile)
        case .storeMissing:
            try FileManager.default.removeItem(at: f.storeURL)
        case .wrongProfile:
            try StoreAnchors.stubBytes(ids: StoreIDs(storeID: f.ids.storeID, profileID: UUID())).write(to: f.vaultFile)
        }
    }
}

private nonisolated enum WrongCredential: CaseIterable, Sendable {
    case wrongPRF, unenrolledCredential

    func proof(from enrolled: VaultUnlockProof) -> VaultUnlockProof {
        switch self {
        case .wrongPRF:
            VaultUnlockProof(credentialID: enrolled.credentialID, prfInput: enrolled.prfInput, prf: SymmetricKey(size: .bits256))
        case .unenrolledCredential:
            VaultUnlockProof(credentialID: Data(repeating: 0xEE, count: 32), prfInput: enrolled.prfInput, prf: enrolled.prf)
        }
    }
}

private nonisolated enum RegistryFault: CaseIterable, Sendable {
    case forgedMAC, rowMissing, olderEntryReplayed, headSwapped, wrapperListSwapped, secondVaultRowsRemoved, linkedTrashRemoved

    /// The ordinal §6.8 step 3 names for the failure: only a MISSING vault or Trash row names its vault ("Missing rows name the vault
    /// by ordinal"); every other catalog difference names none. The failure is store-wide either way: the ordinal is a display
    /// identity, not the scope of the denial.
    var expectedOrdinal: Int? {
        switch self {
        case .secondVaultRowsRemoved:
            2
        case .linkedTrashRemoved:
            1
        default:
            nil
        }
    }

    func arrange(_ f: inout VaultStoreFixture) throws {
        let second = try secondVault(of: f)
        switch self {
        case .forgedMAC:
            try f.putRegistry(try f.storedRegistry().catalog, mac: Data(repeating: 0xAB, count: 32))
        case .rowMissing:
            try f.mutate { try $0.execute(sql: "DELETE FROM registry") }
        case .olderEntryReplayed:
            let old = try f.storedRegistry()
            try f.editHead(f.vaultID) { $0.revision += 1 }  // a legitimate later head of vault A ...
            try f.putRegistry(try f.rebuiltRegistry(revision: old.revision + 1), mac: nil)  // ... the registry once covered it ...
            try f.putRegistry(old.catalog, mac: nil)  // ... and a validly MAC'd older registry is put back
        case .headSwapped:
            // The healthy vault B's Trash head is copied into A's linked-Trash head row; A's active head and B's whole pair stay
            // untouched, so §6.8 step 2 (A's head) passes and step 3 (the registry head digest of A's Trash) is what fails.
            guard let secondTrash = f.secondTrashID else { throw UnlockTestError(message: "fixture has no second trash") }
            let other = try f.read { try StoreTables.head($0, vaultID: secondTrash) }
            guard let other else { throw UnlockTestError(message: "vault B's trash has no head") }
            try f.putHead(other.sealed, vault: f.trashID, revision: other.revision)
        case .wrapperListSwapped:
            // A different, internally consistent wrapper list + head pair that the (MAC'd) registry never covered.
            let extra = try CredentialVaultCrypto.wrap(f.dek, with: VaultFixtures.proof(9), profileID: f.ids.profileID, vaultID: f.vaultID)
            let list = try VaultStoreFixture.encodeWrapperList(f.wrapperRows(of: f.vaultID) + [extra])
            let head = try StoreSeal.sealHead(
                f.sourceHead, key: f.dek, wrappersDigest: StoreSeal.digest(list), keyWrapDigest: f.sourceDigests.keyWrap
            )
            try f.mutate { db in
                try db.execute(sql: "UPDATE vault SET wrappers = ? WHERE vaultID = ?", arguments: [list, f.vaultID.lowerText])
                try StoreTables.putHead(db, vaultID: f.vaultID, revision: f.sourceHead.revision, sealed: head)
            }
        case .secondVaultRowsRemoved:
            guard let trash = f.secondTrashID else { throw UnlockTestError(message: "fixture has no second trash") }
            try removeRows(f, vault: second)
            try removeRows(f, vault: trash)
        case .linkedTrashRemoved:
            try removeRows(f, vault: f.trashID)
        }
    }
}

private nonisolated enum RowFault: CaseIterable, Sendable {
    case liveRowAltered, trashKeyWrapDoesNotOpen
}

private nonisolated enum HeadFault: CaseIterable, Sendable {
    case flippedTag, wrongKey
    case storeIDInAAD, profileIDInAAD, vaultIDInAAD, revisionInAAD, wrappersDigestInAAD, keyWrapDigestInAAD
    case undecodablePlaintext
    case unsortedOrigins, duplicatedOrigins, notACanonicalOrigin, overLimitOrigins

    /// A stored head that fails §6.8 step 2 (and nothing else about the store is wrong).
    func forge(_ f: VaultStoreFixture) throws -> Data {
        let head = f.sourceHead
        var plaintext = head.encode()
        var key = f.dek
        var ids = f.ids
        var vaultID = f.vaultID
        var revision = head.revision
        var wrappersDigest = f.sourceDigests.wrappers
        var keyWrapDigest = f.sourceDigests.keyWrap
        func withOrigins(_ origins: [String]) -> Data {
            var edited = head
            edited.blockedOrigins = origins
            return edited.encode()
        }
        switch self {
        case .flippedTag:
            let stored = try f.read { try StoreTables.head($0, vaultID: f.vaultID) }
            guard let stored else { throw UnlockTestError(message: "no stored head") }
            return VaultStoreFixture.flipped(stored.sealed)
        case .wrongKey:
            key = SymmetricKey(size: .bits256)
        case .storeIDInAAD:
            ids = StoreIDs(storeID: UUID(), profileID: ids.profileID)
        case .profileIDInAAD:
            ids = StoreIDs(storeID: ids.storeID, profileID: UUID())
        case .vaultIDInAAD:
            vaultID = UUID()
        case .revisionInAAD:
            revision += 1
        case .wrappersDigestInAAD:
            wrappersDigest = Data(repeating: 0x07, count: 32)
        case .keyWrapDigestInAAD:
            keyWrapDigest = Data(repeating: 0x07, count: 32)
        case .undecodablePlaintext:
            plaintext = Data([1, 2, 3])
        case .unsortedOrigins:
            plaintext = withOrigins(["https://b.example", "https://a.example"])
        case .duplicatedOrigins:
            plaintext = withOrigins(["https://a.example", "https://a.example"])
        case .notACanonicalOrigin:
            plaintext = withOrigins(["https://a.example/path"])
        case .overLimitOrigins:
            // 4,097 sorted, unique, canonical origins: only the §7 cap is violated, and the plaintext is sealed raw so the store's
            // public unlock (not fixture validation) is what meets it.
            plaintext = withOrigins((0...4096).map { "https://o\(String(format: "%04d", $0)).example" })
        }
        return try StoreSeal.sealHeadPlaintext(
            plaintext, key: key, ids: ids, vaultID: vaultID, revision: revision, wrappersDigest: wrappersDigest, keyWrapDigest: keyWrapDigest
        )
    }
}

// MARK: - Tests

struct VaultStoreUnlockTests {
    static let lockWait: Duration = .milliseconds(150)

    private var steppingNow: @Sendable () -> ContinuousClock.Instant {
        let clock = UnlockClock(step: .milliseconds(300))
        return { clock.now() }
    }

    // MARK: Publication

    @Test func grantIsPublishedOnlyAfterVerification() async throws {
        let accounts = [
            VaultFixtures.account(username: "ada", origin: "https://a.example"),
            VaultFixtures.account(username: "grace", origin: "https://b.example"),
        ]
        let blocked = ["https://a.example", "https://b.example"]
        try await VaultStoreFixture.with(accounts: accounts, blockedOrigins: blocked, historyRows: 2) { f in
            let store = f.makeStore()
            let access = f.beginAccess()
            await expectNoGrant(store, f.vaultID, access)

            let failure = await unlockResult(f, store, access: access)
            #expect(failure == nil)

            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(snapshot.vaultID == f.vaultID)
            #expect(snapshot.revision == f.sourceHead.revision)
            #expect(snapshot.accounts.sorted { $0.id.uuidString < $1.id.uuidString } == accounts.sorted { $0.id.uuidString < $1.id.uuidString })
            #expect(snapshot.blockedPasswordOrigins == Set(blocked))
            let stamps = Dictionary(
                uniqueKeysWithValues: f.sourceHead.liveCatalog.map { ($0.recordID, AccountStamp(version: $0.version, digest: $0.digest)) }
            )
            #expect(snapshot.stamps == stamps)
            #expect(stamps.count == accounts.count)
        }
    }

    @Test(arguments: BadAnchor.allCases)
    private func badAnchorStatesGrantNothing(_ anchor: BadAnchor) async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], stubAbsent: anchor.stubAbsent) { f in
            try anchor.arrange(f)
            guard case .failClosed(let closed) = f.evaluate() else {
                Issue.record("\(anchor) did not arrange a fail-closed state")
                return
            }
            #expect(closed.cause == anchor.expectedCause)
            let directoryBefore = try settledImage(f)
            let defaultsBefore = f.defaultsImage()

            let store = f.makeStore()
            let access = f.beginAccess()
            let failure = await unlockResult(f, store, access: access)

            #expect(failure as? CredentialStoreError == .failClosed(closed))
            await expectNoGrant(store, f.vaultID, access)
            #expect(try settledImage(f) == directoryBefore)
            #expect(f.defaultsImage() == defaultsBefore)
        }
    }

    @Test(arguments: WrongCredential.allCases)
    private func wrongPRFOrUnenrolledCredentialGrantsNothing(_ wrong: WrongCredential) async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let store = f.makeStore()
            let access = f.beginAccess()
            let rowsBefore = try f.recordAndJournalImage()

            let failure = await unlockResult(f, store, proof: wrong.proof(from: f.proof), access: access)

            #expect(failure as? CredentialVaultError == .authenticationFailed)
            await expectNoGrant(store, f.vaultID, access)
            #expect(try f.recordAndJournalImage() == rowsBefore)
            #expect(try f.headRevision(of: f.vaultID) == f.sourceHead.revision)

            // The refusal poisons nothing: the enrolled credential still opens the vault on the same store.
            #expect(await unlockResult(f, store, access: access) == nil)
            _ = try await store.snapshot(vaultID: f.vaultID, using: access)
        }
    }

    // MARK: Registry and per-vault integrity

    @Test(arguments: RegistryFault.allCases)
    private func registryFailuresAreStoreWide(_ fault: RegistryFault) async throws {
        let a = VaultFixtures.account(username: "ada", origin: "https://a.example")
        let b = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [a], historyRows: 1, secondVault: true, secondAccounts: [b]) { base in
            var f = base
            try fault.arrange(&f)
            let second = try secondVault(of: f)
            let store = f.makeStore()
            let access = f.beginAccess()

            let failure = await unlockResult(f, store, access: access)
            #expect(failure as? CredentialStoreError == .integrityFailure(vaultOrdinal: fault.expectedOrdinal))
            await expectNoGrant(store, f.vaultID, access)

            // A vault the fault did not touch is refused too, on the same store and on a fresh one (the failure is on disk).
            let healthy = fault == .secondVaultRowsRemoved ? f.vaultID : second
            let other = f.beginAccess()
            #expect(await unlockResult(f, store, vault: healthy, access: other) as? CredentialStoreError == .integrityFailure(vaultOrdinal: fault.expectedOrdinal))
            await expectNoGrant(store, healthy, other)

            let fresh = f.makeStore()
            let freshAccess = f.beginAccess()
            let freshFailure = await unlockResult(f, fresh, vault: healthy, proof: f.proof(for: healthy), access: freshAccess)
            #expect(freshFailure as? CredentialStoreError == .integrityFailure(vaultOrdinal: fault.expectedOrdinal))
            await expectNoGrant(fresh, healthy, freshAccess)
        }
    }

    @Test(arguments: RowFault.allCases)
    private func rowTamperFailsOnlyThatVault(_ fault: RowFault) async throws {
        let a = VaultFixtures.account(username: "ada", origin: "https://a.example")
        let b = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [a], historyRows: 2, secondVault: true, secondAccounts: [b]) { f in
            let second = try secondVault(of: f)
            switch fault {
            case .liveRowAltered:
                try flipLiveRow(f, vault: f.vaultID, account: a)
            case .trashKeyWrapDoesNotOpen:
                // A key wrap sealed under another key: it never opens under vault A's DEK, yet the head AAD, the trash head and the
                // registry are all brought in line with it, so the catalog still verifies and only this vault is affected.
                let wrap = try StoreSeal.wrapTrashKey(
                    f.trashDEK, under: SymmetricKey(size: .bits256), ids: f.ids, source: f.vaultID, trash: f.trashID, nonce: f.sourceHead.link.nonce
                )
                let head = try StoreSeal.sealHead(
                    f.trashHead, key: f.trashDEK, wrappersDigest: f.trashDigests.wrappers, keyWrapDigest: StoreSeal.digest(wrap)
                )
                try f.mutate { db in
                    try db.execute(sql: "UPDATE vault SET keyWrap = ? WHERE vaultID = ?", arguments: [wrap, f.trashID.lowerText])
                    try StoreTables.putHead(db, vaultID: f.trashID, revision: f.trashHead.revision, sealed: head)
                }
                try f.putRegistry(try f.rebuiltRegistry(), mac: nil)
            }

            let store = f.makeStore()
            let access = f.beginAccess()
            let failure = await unlockResult(f, store, access: access)
            #expect(failure as? CredentialStoreError == .integrityFailure(vaultOrdinal: 1))
            await expectNoGrant(store, f.vaultID, access)

            let secondAccess = f.beginAccess()
            #expect(await unlockResult(f, store, vault: second, access: secondAccess) == nil)
            let snapshot = try await store.snapshot(vaultID: second, using: secondAccess)
            #expect(snapshot.accounts == [b])
            await expectNoGrant(store, f.vaultID, access)
        }
    }

    @Test(arguments: HeadFault.allCases)
    private func headAuthenticationFailuresAreIntegrityFailuresAtUnlock(_ fault: HeadFault) async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            try f.putHead(try fault.forge(f), vault: f.vaultID, revision: f.sourceHead.revision)
            let store = f.makeStore()
            let access = f.beginAccess()

            let failure = await unlockResult(f, store, access: access)

            // Never the CryptoKit or `malformed` error that `openHead` throws.
            #expect(failure as? CredentialStoreError == .integrityFailure(vaultOrdinal: 1))
            await expectNoGrant(store, f.vaultID, access)
        }
    }

    // MARK: Lock

    @Test func lockIsTakenBeforeAnyReadAndNeverUpgraded() async throws {
        // (a) an EXCLUSIVE holder: bounded wait, `storeBusy`, nothing verified, no sidecar.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let sidecarsBefore = try sidecars(f)
            let hold = try await OperationLock.acquire(in: f.directory, mode: .exclusive)
            let store = f.makeStore(lockWait: Self.lockWait)
            let access = f.beginAccess()
            let verifying = UnlockJournal<Bool>()

            let failure = await unlockResult(f, store, access: access, verifying: { verifying.add($0) })

            #expect(failure as? CredentialStoreError == .storeBusy)
            #expect(verifying.all.isEmpty)
            #expect(try sidecars(f) == sidecarsBefore)
            await expectNoGrant(store, f.vaultID, access)

            hold.release()
            #expect(await unlockResult(f, store, access: access) == nil)
        }

        // (b) the stub is absent, so EXCLUSIVE is needed: a SHARED holder is never upgraded past, and the stub stays absent.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], stubAbsent: true) { f in
            let hold = try await OperationLock.acquire(in: f.directory, mode: .shared)
            let store = f.makeStore(lockWait: Self.lockWait)
            let access = f.beginAccess()

            let failure = await unlockResult(f, store, access: access)

            #expect(failure as? CredentialStoreError == .storeBusy)
            #expect(!FileManager.default.fileExists(atPath: f.vaultFile.path))
            #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: true))
            await expectNoGrant(store, f.vaultID, access)
            hold.release()
        }

        // (c) the stub is present: SHARED is enough, and a SHARED holder does not block it.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let hold = try await OperationLock.acquire(in: f.directory, mode: .shared)
            let store = f.makeStore(lockWait: Self.lockWait)
            let access = f.beginAccess()

            #expect(await unlockResult(f, store, access: access) == nil)
            _ = try await store.snapshot(vaultID: f.vaultID, using: access)
            hold.release()
        }
    }

    // MARK: Verification callbacks and access

    @Test func verifyingCallbackFiresOnlyPastTheThreshold() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 3) { f in
            let constant = UnlockClock(step: .zero)
            let quiet = UnlockJournal<Bool>()
            let first = f.makeStore(now: { constant.now() })
            #expect(await unlockResult(f, first, access: f.beginAccess(lifetime: .seconds(3600)), verifying: { quiet.add($0) }) == nil)
            #expect(quiet.all.isEmpty)

            let stepping = UnlockClock(step: .milliseconds(300))
            let loud = UnlockJournal<Bool>()
            let second = f.makeStore(now: { stepping.now() })
            #expect(await unlockResult(f, second, access: f.beginAccess(lifetime: .seconds(3600)), verifying: { loud.add($0) }) == nil)
            #expect(loud.all == [true, false])
        }
    }

    @Test func accessRevokedDuringVerificationIsNeverPublished() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 3) { f in
            let store = f.makeStore(now: steppingNow)
            let access = f.beginAccess(lifetime: .seconds(3600))

            let failure = await unlockResult(f, store, access: access, verifying: { _ in access.revoke() })

            #expect(failure as? CredentialVaultError == .unauthorized)
            await expectNoGrant(store, f.vaultID, access)

            // The next unlock, with a fresh access, is not affected.
            let next = f.beginAccess(lifetime: .seconds(3600))
            #expect(await unlockResult(f, store, access: next) == nil)
            _ = try await store.snapshot(vaultID: f.vaultID, using: next)
        }
    }

    // MARK: Ordering of snapshot, scratch, stub repair and publication

    @Test func snapshotEndsAndScratchIsGoneBeforeStubRepairAndPublish() async throws {

        // Success: at the stub repair the verification snapshot is over, its scratch file is gone, the lock is still held.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 3, stubAbsent: true) { f in
            let facts = UnlockJournal<RenameFacts>()
            let directory = f.directory
            var ops = StoreFileOps.live
            ops.renameExclusive = { from, to in
                facts.add(RenameFacts(scratchEntries: scratchEntries(in: directory), operationLockHeld: operationLockIsHeld(in: directory)))
                try StoreFileOps.live.renameExclusive(from, to)
            }
            let store = f.makeStore(fileOps: ops)
            let access = f.beginAccess()

            #expect(await unlockResult(f, store, access: access) == nil)

            #expect(facts.all.count == 1)
            #expect(facts.all.first?.scratchEntries == [])
            #expect(facts.all.first?.operationLockHeld == true)
            _ = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: false))
        }

        // EIO from the stub repair: publication comes after it, so nothing is granted, nothing is repaired and the lock is released.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 3, stubAbsent: true) { f in
            let attempts = UnlockJournal<String>()
            var ops = StoreFileOps.live
            ops.renameExclusive = { _, destination in
                attempts.add(destination.lastPathComponent)
                throw StoreFileError.io(EIO)
            }
            let store = f.makeStore(fileOps: ops)
            let access = f.beginAccess()

            let failure = await unlockResult(f, store, access: access)

            // The stub repair really ran (so the failure is not an earlier authentication one) and was the only thing that failed.
            #expect(attempts.all == ["Credentials.vault"])
            #expect(failure != nil)
            await expectNoGrant(store, f.vaultID, access)
            #expect(!FileManager.default.fileExists(atPath: f.vaultFile.path))
            #expect(scratchEntries(in: f.directory).isEmpty)
            let lock = try await OperationLock.acquire(in: f.directory, mode: .exclusive, wait: Self.lockWait)
            lock.release()
        }
    }

    @Test(.enabled(if: getuid() != 0))
    func scratchCleanupFailureIsAWarningAndNeverTheOutcome() async throws {
        let accounts = [VaultFixtures.account(username: "ada"), VaultFixtures.account(username: "grace", origin: "https://b.example")]

        func isTheScratchFile(_ url: URL) -> Bool {
            url.deletingLastPathComponent().lastPathComponent == "Credentials.scratch" && url.pathExtension == "db"
        }

        // A valid vault still unlocks.
        try await VaultStoreFixture.with(accounts: accounts, historyRows: 20) { f in
            let scratch = VerificationScratch.directory(in: f.directory)
            defer { setMode(0o700, scratch) }
            let warnings = UnlockJournal<URL>()
            let store = f.makeStore(now: steppingNow)
            let access = f.beginAccess(lifetime: .seconds(3600))

            let failure = await unlockResult(
                f, store, access: access, verifying: { if $0 { setMode(0o500, scratch) } }, scratchWarning: { warnings.add($0) }
            )

            #expect(failure == nil)
            #expect(warnings.all.contains(where: isTheScratchFile))
            _ = try await store.snapshot(vaultID: f.vaultID, using: access)
        }

        // A tampered live row is still `integrityFailure(vaultOrdinal: 1)`, not a file error.
        try await VaultStoreFixture.with(accounts: accounts, historyRows: 20) { f in
            let scratch = VerificationScratch.directory(in: f.directory)
            defer { setMode(0o700, scratch) }
            try flipLiveRow(f, vault: f.vaultID, account: accounts[0])
            let warnings = UnlockJournal<URL>()
            let store = f.makeStore(now: steppingNow)
            let access = f.beginAccess(lifetime: .seconds(3600))

            let failure = await unlockResult(
                f, store, access: access, verifying: { if $0 { setMode(0o500, scratch) } }, scratchWarning: { warnings.add($0) }
            )

            #expect(failure as? CredentialStoreError == .integrityFailure(vaultOrdinal: 1))
            #expect(warnings.all.contains(where: isTheScratchFile))
            await expectNoGrant(store, f.vaultID, access)
        }

        // A cancelled unlock is `CancellationError`, publishes nothing and still reports the path.
        try await VaultStoreFixture.with(accounts: accounts, historyRows: 20) { f in
            let scratch = VerificationScratch.directory(in: f.directory)
            defer { setMode(0o700, scratch) }
            let warnings = UnlockJournal<URL>()
            let canceller = UnlockCanceller()
            let store = f.makeStore(now: steppingNow)
            let access = f.beginAccess(lifetime: .seconds(3600))
            let used = f.proof
            let vault = f.vaultID

            let task = Task {
                try await store.unlockInitialized(
                    vaultID: vault, credentialID: used.credentialID, prf: used.prf, access: access,
                    verifying: { if $0 { setMode(0o500, scratch); canceller.fire() } },
                    scratchWarning: { warnings.add($0) }
                )
            }
            canceller.attach(task)
            var failure: (any Error)?
            do {
                try await task.value
            } catch {
                failure = error
            }

            #expect(failure is CancellationError)
            #expect(warnings.all.contains(where: isTheScratchFile))
            await expectNoGrant(store, f.vaultID, access)
        }
    }

    @Test(.enabled(if: getuid() != 0))
    func crashLeftoverIsCleanedOnlyUnderExclusiveAndNeverUnlinksALiveSharedScratch() async throws {
        func plant(_ f: VaultStoreFixture, name: String = "leftover.db", bytes: Data = Data(repeating: 0x42, count: 64)) throws -> URL {
            let scratch = VerificationScratch.directory(in: f.directory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(
                at: scratch.appendingPathComponent(name).deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let file = scratch.appendingPathComponent(name)
            try bytes.write(to: file)
            return file
        }

        // (a) a leftover is removed under EXCLUSIVE, with the stub present and with it absent.
        for stubAbsent in [false, true] {
            try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], stubAbsent: stubAbsent) { f in
                let leftover = try plant(f)
                let store = f.makeStore()
                let access = f.beginAccess()

                #expect(await unlockResult(f, store, access: access) == nil)

                #expect(!FileManager.default.fileExists(atPath: leftover.path))
                #expect(scratchEntries(in: f.directory).isEmpty)
                _ = try await store.snapshot(vaultID: f.vaultID, using: access)
            }
        }

        // (b) another process's live scratch file: EXCLUSIVE is chosen, the SHARED holder makes it `storeBusy`, the file is untouched.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let bytes = Data(repeating: 0x77, count: 128)
            let live = try plant(f, name: "live.db", bytes: bytes)
            let hold = try await OperationLock.acquire(in: f.directory, mode: .shared)
            let store = f.makeStore(lockWait: Self.lockWait)
            let access = f.beginAccess()

            let failure = await unlockResult(f, store, access: access)

            #expect(failure as? CredentialStoreError == .storeBusy)
            #expect(try Data(contentsOf: live) == bytes)
            await expectNoGrant(store, f.vaultID, access)
            hold.release()
        }

        // (c) an empty scratch directory keeps the concurrent SHARED path.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            try FileManager.default.createDirectory(
                at: VerificationScratch.directory(in: f.directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let hold = try await OperationLock.acquire(in: f.directory, mode: .shared)
            let store = f.makeStore(lockWait: Self.lockWait)
            let access = f.beginAccess()

            #expect(await unlockResult(f, store, access: access) == nil)
            _ = try await store.snapshot(vaultID: f.vaultID, using: access)
            hold.release()
        }

        // (d) an unremovable subdirectory is a warning, not an outcome.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let leftover = try plant(f, name: "stuck/inner.db")
            let stuck = leftover.deletingLastPathComponent()
            setMode(0o500, stuck)
            defer { setMode(0o700, stuck) }
            let warnings = UnlockJournal<URL>()
            let store = f.makeStore()
            let access = f.beginAccess()

            #expect(await unlockResult(f, store, access: access, scratchWarning: { warnings.add($0) }) == nil)

            #expect(warnings.all.contains { $0.lastPathComponent == "stuck" })
            _ = try await store.snapshot(vaultID: f.vaultID, using: access)
        }

        // (e) a scratch directory that cannot be listed selects EXCLUSIVE, so a SHARED holder makes it `storeBusy`.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let scratch = VerificationScratch.directory(in: f.directory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            setMode(0o000, scratch)
            defer { setMode(0o700, scratch) }
            let hold = try await OperationLock.acquire(in: f.directory, mode: .shared)
            let store = f.makeStore(lockWait: Self.lockWait)
            let access = f.beginAccess()

            let failure = await unlockResult(f, store, access: access)

            #expect(failure as? CredentialStoreError == .storeBusy)
            await expectNoGrant(store, f.vaultID, access)
            hold.release()
        }
    }

    // MARK: Anchor repair

    @Test func stubMissingIsRepairedOnlyAfterAuthenticatedUnlock() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], stubAbsent: true) { f in
            #expect(!FileManager.default.fileExists(atPath: f.vaultFile.path))
            #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: true))
            let store = f.makeStore()
            let access = f.beginAccess()

            // Without an unlock no write-class operation is available.
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await store.updatePasswordSavePolicy(vaultID: f.vaultID, [], expectedRevision: f.sourceHead.revision, using: access)
            }
            // An unauthenticated attempt repairs nothing.
            let wrong = WrongCredential.wrongPRF.proof(from: f.proof)
            let wrongFailure = await unlockResult(f, store, proof: wrong, access: access)
            #expect(wrongFailure as? CredentialVaultError == .authenticationFailed)
            #expect(!FileManager.default.fileExists(atPath: f.vaultFile.path))

            #expect(await unlockResult(f, store, access: access) == nil)

            #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: false))
            let repaired = try Data(contentsOf: f.vaultFile)
            #expect(repaired == StoreAnchors.stubBytes(ids: f.ids))
        }
    }

    @Test func v1FileAppearingBeforeStubRepairIsNeverOverwritten() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], stubAbsent: true) { f in
            let v1 = try v1Bytes(profileID: f.env.profileID)
            let vaultFile = f.vaultFile
            var ops = StoreFileOps.live
            ops.renameExclusive = { from, to in
                try v1.write(to: vaultFile)  // an old build writes its file just before the stub would land
                try StoreFileOps.live.renameExclusive(from, to)
            }
            let store = f.makeStore(fileOps: ops)
            let access = f.beginAccess()

            let failure = await unlockResult(f, store, access: access)

            guard case .failClosed(let closed) = f.evaluate() else {
                Issue.record("the directory is not fail-closed after the collision")
                return
            }
            #expect(closed.cause == .v1AfterMigration)
            #expect(failure as? CredentialStoreError == .failClosed(closed))
            #expect(try Data(contentsOf: vaultFile) == v1)
            await expectNoGrant(store, f.vaultID, access)
        }
    }

    @Test func a3IsSetOnlyWhenAbsentAfterUnlock() async throws {
        // Absent: not set by a refused unlock, set to the storeID by the authenticated one.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            f.env.defaults.removeObject(forKey: StoreAnchors.witnessKey)
            #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: false))
            let store = f.makeStore()
            let access = f.beginAccess()

            #expect(await unlockResult(f, store, proof: WrongCredential.wrongPRF.proof(from: f.proof), access: access) != nil)
            #expect(f.env.defaults.object(forKey: StoreAnchors.witnessKey) == nil)

            #expect(await unlockResult(f, store, access: access) == nil)
            let stored = f.env.defaults.string(forKey: StoreAnchors.witnessKey)
            #expect(stored.flatMap(UUID.init(uuidString:)) == f.ids.storeID)
        }

        // Present and different: fail closed, unchanged.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            f.env.defaults.set(UUID().uuidString, forKey: StoreAnchors.witnessKey)
            guard case .failClosed(let closed) = f.evaluate() else {
                Issue.record("a foreign A3 did not fail closed")
                return
            }
            let before = f.defaultsImage()
            let store = f.makeStore()

            let failure = await unlockResult(f, store, access: f.beginAccess())

            #expect(failure as? CredentialStoreError == .failClosed(closed))
            #expect(f.defaultsImage() == before)
        }

        // Present and agreeing: left exactly as it was.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let spelling = f.ids.storeID.uuidString.lowercased()
            f.env.defaults.set(spelling, forKey: StoreAnchors.witnessKey)
            let store = f.makeStore()

            #expect(await unlockResult(f, store, access: f.beginAccess()) == nil)
            #expect(f.env.defaults.string(forKey: StoreAnchors.witnessKey) == spelling)
        }
    }
}
