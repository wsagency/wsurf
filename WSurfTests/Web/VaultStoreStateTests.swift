// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import SQLite3
import Synchronization
import Testing

@testable import WSurf

private nonisolated enum Names {
    static let store = "Credentials.store"
    static let vault = "Credentials.vault"
    static let migrating = "Credentials.store.migrating"
    static let swap = "Credentials.vault.swap"
    static let cutover = "Credentials.vault.cutover-v1"
    static let preV2 = "Credentials.vault.pre-v2"
}

private nonisolated struct FixtureError: Error {
    let message: String
}

/// A type-wrong or unparsable A3 value: the object exists, so it is "present", never "absent".
private nonisolated enum MalformedWitness: CaseIterable, Sendable {
    case integer, emptyString, notAUUID, data, boolean, array

    var value: Any {
        switch self {
        case .integer:
            7
        case .emptyString:
            ""
        case .notAUUID:
            "not-a-uuid"
        case .data:
            Data([1, 2, 3])
        case .boolean:
            true
        case .array:
            ["a"]
        }
    }
}

/// Real files in a `VaultTestEnvironment` directory, real SQLite stores (WAL mode, checkpointed and closed, as the creator leaves them).
private nonisolated struct StateFixture {
    static let storeID = UUID(uuid: (2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
    static let otherStoreID = UUID(uuid: (3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3))
    static let vaultID = UUID(uuid: (4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4))

    let env: VaultTestEnvironment
    let ids: StoreIDs
    let foreign: StoreIDs
    let strangerProfile: StoreIDs

    init() throws {
        env = try VaultTestEnvironment.make()
        ids = StoreIDs(storeID: Self.storeID, profileID: env.profile.id)
        foreign = StoreIDs(storeID: Self.otherStoreID, profileID: env.profile.id)
        strangerProfile = StoreIDs(storeID: Self.storeID, profileID: UUID())
    }

    var directory: URL {
        env.directory
    }

    var defaults: UserDefaults {
        env.defaults
    }

    func url(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    func evaluate() -> StoreOpenState {
        StoreAnchors.evaluate(directory: directory, profileID: ids.profileID, defaults: defaults)
    }

    // MARK: Arranging

    func writeV1(profileID: UUID? = nil) throws {
        let envelope = CredentialVaultEnvelope(
            format: 1,
            profileID: profileID ?? ids.profileID,
            vaultID: Self.vaultID,
            wrappers: [
                CredentialKeyWrapper(
                    credentialID: Data([1]), prfInput: Data([2]), nonce: Data(repeating: 3, count: 12),
                    ciphertext: Data(repeating: 4, count: 32), tag: Data(repeating: 5, count: 16)
                ),
            ],
            payload: CredentialSealedData(nonce: Data(repeating: 6, count: 12), ciphertext: Data([7, 8, 9]), tag: Data(repeating: 10, count: 16))
        )
        try CredentialVaultCrypto.encodeEnvelope(envelope).write(to: url(Names.vault))
    }

    func writeStub(_ stub: StoreIDs) throws {
        try StoreAnchors.stubBytes(ids: stub).write(to: url(Names.vault))
    }

    func writeGarbage(_ name: String) throws {
        try Data("not a vault, not a database".utf8).write(to: url(name))
    }

    func writeStore(_ name: String = Names.store, ids stored: StoreIDs? = nil) throws {
        let file = url(name)
        // Observed natively (evidence/task4-wal-close-probe, task4-vnode-unlink-probe): flag 0 alone makes close() unlink -shm while still open (SQLite API-violation log);
        // EXCLUSIVE locking before WAL never creates -shm, so with flag 0 the close leaves only the database. Creator connection only; runtime NORMAL connections keep defaults.
        var configuration = Configuration()
        configuration.prepareDatabase { (db: Database) throws in
            let locking = try String.fetchOne(db, sql: "PRAGMA locking_mode = EXCLUSIVE")
            guard locking?.lowercased() == "exclusive" else {
                throw FixtureError(message: "locking_mode=EXCLUSIVE refused (\(locking ?? "nil"))")
            }
            var zero: Int32 = 0
            let status = sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_PERSIST_WAL, &zero)
            if status != SQLITE_OK {
                throw FixtureError(message: "PERSIST_WAL=0 refused (\(status))")
            }
        }
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        try queue.writeWithoutTransaction { (db: Database) throws in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        try queue.write { (db: Database) throws in try StoreTables.create(in: db, ids: stored ?? ids) }
        let checkpoint = try queue.writeWithoutTransaction { (db: Database) throws in
            try GRDB.Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        guard let busy: Int = checkpoint?[0], busy == 0 else {
            throw FixtureError(message: "\(name) checkpoint(TRUNCATE) did not complete")
        }
        try queue.close()
        for sidecar in ["-wal", "-shm"] where exists(name + sidecar) {
            throw FixtureError(message: "\(name)\(sidecar) survived the close")
        }
    }

    /// A valid SQLite file with no usable `store_meta`.
    func writeSQLite(_ sql: String) throws {
        let queue = try DatabaseQueue(path: url(Names.store).path)
        try queue.write { (db: Database) throws in try db.execute(sql: sql) }
        try queue.close()
    }

    func writeEmpty(_ name: String) throws {
        try Data().write(to: url(name))
    }

    func setWitness(_ value: Any) {
        defaults.set(value, forKey: StoreAnchors.witnessKey)
    }

    // MARK: Expectations

    /// §6.4: the five core paths always, `.swap`, every `cutover-v1*` and `.pre-v2` only when they exist.
    func failClosed(_ cause: StoreFailCause) -> StoreOpenState {
        let cutovers = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(Names.cutover) }
            .sorted()
        var names = [Names.store, Names.store + "-wal", Names.store + "-shm", Names.vault, Names.migrating]
        names += ([Names.swap] + cutovers + [Names.preV2]).filter { exists($0) }
        return .failClosed(StoreFailClosed(cause: cause, paths: names.map(url), preMigrationBackup: exists(Names.preV2) ? url(Names.preV2) : nil))
    }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func deny(_ name: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url(name).path)
    }

    /// Restores the owned fixture (directory and files) so it can be inspected and deleted.
    func makeReadable() {
        let fileManager = FileManager.default
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url(name).path)
        }
    }

    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            result[name] = try Data(contentsOf: url(name))
        }
        return result
    }
}

/// Every layout of the §6.3 table, with the A3 variants the Director ruling distinguishes (absent / agreeing / disagreeing / malformed).
private nonisolated enum Row: String, CaseIterable, Sendable {
    // row 1-3: v1 file
    case legacy, v1WithWitness, v1WithMalformedWitness, v1WithStore, v1WithStoreAndWitness
    // row 4-5: stub + store
    case stubStore, stubStoreAgreeingWitness, stubStoreForeignStore, stubStoreDisagreeingWitness, stubStoreMalformedWitness
    // row 6: stub, no store
    case resume, resumeAgreeingWitness, stubOnly, migratingOfAnotherStore, migratingWithAnotherProfile, stubOnlyDisagreeingWitness
    case resumeDisagreeingWitness, resumeMalformedWitness
    // row 7-9: no vault file
    case storeOnly, storeOnlyAgreeingWitness, storeOnlyDisagreeingWitness, storeOnlyMalformedWitness
    case witnessOnly, malformedWitnessOnly
    // row 10-12
    case nothing, garbageVault, garbageVaultWithStore, garbageStoreWithStub, garbageStoreWithV1, garbageStoreAlone
    // "A profileID mismatch in stub or store is the existing wrongProfile"
    case v1WrongProfile, stubWrongProfile, storeWrongProfile, stubStoreWrongProfileStore

    func arrange(_ f: StateFixture) throws {
        switch self {
        case .legacy, .v1WithWitness, .v1WithMalformedWitness, .v1WithStore, .v1WithStoreAndWitness, .v1WrongProfile, .garbageStoreWithV1:
            try arrangeV1(f)
        case .stubStore, .stubStoreAgreeingWitness, .stubStoreForeignStore, .stubStoreDisagreeingWitness, .stubStoreMalformedWitness,
            .resume, .resumeAgreeingWitness, .stubOnly, .migratingOfAnotherStore, .migratingWithAnotherProfile, .stubOnlyDisagreeingWitness,
            .resumeDisagreeingWitness, .resumeMalformedWitness, .stubWrongProfile, .stubStoreWrongProfileStore, .garbageStoreWithStub:
            try arrangeStub(f)
        default:
            try arrangeWithoutVaultFile(f)
        }
    }

    private func arrangeV1(_ f: StateFixture) throws {
        switch self {
        case .legacy:
            try f.writeV1()
        case .v1WithWitness:
            try f.writeV1()
            f.setWitness(f.ids.storeID.uuidString)
        case .v1WithMalformedWitness:
            try f.writeV1()
            f.setWitness(7)
        case .v1WithStore:
            try f.writeV1()
            try f.writeStore()
        case .v1WithStoreAndWitness:
            try f.writeV1()
            try f.writeStore()
            f.setWitness(f.ids.storeID.uuidString)
        case .v1WrongProfile:
            try f.writeV1(profileID: UUID())
        case .garbageStoreWithV1:
            try f.writeV1()
            try f.writeGarbage(Names.store)
        default:
            break
        }
    }

    private func arrangeStub(_ f: StateFixture) throws {
        switch self {
        case .stubStore:
            try f.writeStub(f.ids)
            try f.writeStore()
        case .stubStoreAgreeingWitness:
            try f.writeStub(f.ids)
            try f.writeStore()
            f.setWitness(f.ids.storeID.uuidString.lowercased())
        case .stubStoreForeignStore:
            try f.writeStub(f.ids)
            try f.writeStore(ids: f.foreign)
        case .stubStoreDisagreeingWitness:
            try f.writeStub(f.ids)
            try f.writeStore()
            f.setWitness(f.foreign.storeID.uuidString)
        case .stubStoreMalformedWitness:
            try f.writeStub(f.ids)
            try f.writeStore()
            f.setWitness(7)
        case .resume:
            try f.writeStub(f.ids)
            try f.writeStore(Names.migrating)
        case .resumeAgreeingWitness:
            try f.writeStub(f.ids)
            try f.writeStore(Names.migrating)
            f.setWitness(f.ids.storeID.uuidString)
        case .stubOnly:
            try f.writeStub(f.ids)
        case .migratingOfAnotherStore:
            try f.writeStub(f.ids)
            try f.writeStore(Names.migrating, ids: f.foreign)
        case .migratingWithAnotherProfile:
            try f.writeStub(f.ids)
            try f.writeStore(Names.migrating, ids: f.strangerProfile)  // same storeID as the stub, other profileID
        case .stubOnlyDisagreeingWitness:
            try f.writeStub(f.ids)
            f.setWitness(f.foreign.storeID.uuidString)
        case .resumeDisagreeingWitness:
            try f.writeStub(f.ids)
            try f.writeStore(Names.migrating)
            f.setWitness(f.foreign.storeID.uuidString)
        case .resumeMalformedWitness:
            try f.writeStub(f.ids)
            try f.writeStore(Names.migrating)
            f.setWitness(7)
        case .stubWrongProfile:
            try f.writeStub(f.strangerProfile)
        case .stubStoreWrongProfileStore:
            try f.writeStub(f.ids)
            try f.writeStore(ids: f.strangerProfile)
        case .garbageStoreWithStub:
            try f.writeStub(f.ids)
            try f.writeGarbage(Names.store)
        default:
            break
        }
    }

    private func arrangeWithoutVaultFile(_ f: StateFixture) throws {
        switch self {
        case .storeOnly:
            try f.writeStore()
        case .storeOnlyAgreeingWitness:
            try f.writeStore()
            f.setWitness(f.ids.storeID.uuidString)
        case .storeOnlyDisagreeingWitness:
            try f.writeStore()
            f.setWitness(f.foreign.storeID.uuidString)
        case .storeOnlyMalformedWitness:
            try f.writeStore()
            f.setWitness(7)
        case .witnessOnly:
            f.setWitness(f.ids.storeID.uuidString)
        case .malformedWitnessOnly:
            f.setWitness(7)
        case .garbageVault:
            try f.writeGarbage(Names.vault)
        case .garbageVaultWithStore:
            try f.writeGarbage(Names.vault)
            try f.writeStore()
        case .storeWrongProfile:
            try f.writeStore(ids: f.strangerProfile)
        case .garbageStoreAlone:
            try f.writeGarbage(Names.store)
        default:
            break  // .nothing
        }
    }

    func expected(_ f: StateFixture) -> StoreOpenState {
        switch self {
        case .legacy:
            .legacy(vaultID: StateFixture.vaultID)  // row 1
        case .v1WithWitness, .v1WithMalformedWitness:
            f.failClosed(.v1AfterMigration)  // row 2: an unparsable A3 is still present
        case .v1WithStore, .v1WithStoreAndWitness:
            f.failClosed(.v1AfterMigration)  // row 3
        case .stubStore, .stubStoreAgreeingWitness:
            .provisional(storeID: f.ids.storeID, stubMissing: false)  // row 4
        case .stubStoreForeignStore, .stubStoreDisagreeingWitness, .stubStoreMalformedWitness:
            f.failClosed(.foreignStore)  // row 5
        case .resume, .resumeAgreeingWitness:
            .resumeMigration(storeID: f.ids.storeID)  // row 6
        case .stubOnly, .migratingOfAnotherStore, .migratingWithAnotherProfile:
            f.failClosed(.storeMissing)  // row 6, no `.migrating` carrying both of the stub's IDs
        case .stubOnlyDisagreeingWitness, .resumeDisagreeingWitness, .resumeMalformedWitness:
            f.failClosed(.witnessMismatch)  // row 6 + §6.2
        case .storeOnly, .storeOnlyAgreeingWitness:
            .provisional(storeID: f.ids.storeID, stubMissing: true)  // row 7
        case .storeOnlyDisagreeingWitness, .storeOnlyMalformedWitness:
            f.failClosed(.witnessMismatch)  // row 8
        case .witnessOnly, .malformedWitnessOnly:
            f.failClosed(.storeMissing)  // row 9
        case .nothing:
            .firstRun  // row 10
        case .garbageVault, .garbageVaultWithStore:
            f.failClosed(.unreadableVault)  // row 11
        case .garbageStoreWithStub, .garbageStoreWithV1, .garbageStoreAlone:
            f.failClosed(.unreadableStore)  // row 12
        case .v1WrongProfile, .stubWrongProfile, .storeWrongProfile, .stubStoreWrongProfileStore:
            f.failClosed(.wrongProfile)
        }
    }
}

/// Anchors that exist but cannot be read: a read failure is never "absent". Permission cases need a non-root test user.
private nonisolated enum Unreadable: CaseIterable, Sendable {
    case v1File, storeAlone, storeBesideStub, vaultIsADirectory, storeIsADirectory, migratingBesideStub

    func arrange(_ f: StateFixture) throws {
        switch self {
        case .v1File:
            try Row.legacy.arrange(f)
            try f.deny(Names.vault)
        case .storeAlone:
            try Row.storeOnly.arrange(f)
            try f.deny(Names.store)
        case .storeBesideStub:
            try Row.stubStore.arrange(f)
            try f.deny(Names.store)
        case .vaultIsADirectory:
            try FileManager.default.createDirectory(at: f.url(Names.vault), withIntermediateDirectories: false)
        case .storeIsADirectory:
            try FileManager.default.createDirectory(at: f.url(Names.store), withIntermediateDirectories: false)
        case .migratingBesideStub:
            try Row.resume.arrange(f)
            try f.deny(Names.migrating)
        }
    }

    var expectedCause: StoreFailCause {
        switch self {
        case .v1File, .vaultIsADirectory:
            .unreadableVault
        case .storeAlone, .storeBesideStub, .storeIsADirectory:
            .unreadableStore
        case .migratingBesideStub:
            .storeMissing  // a `.migrating` that cannot be read does not carry the stub's storeID: no resume
        }
    }
}

struct VaultStoreStateTests {
    // MARK: §6.3 table

    @Test(arguments: Row.allCases)
    private func everyRowOfTheStateTableYieldsItsOutcome(_ row: Row) throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try row.arrange(f)
        #expect(f.evaluate() == row.expected(f))
    }

    @Test(arguments: Row.allCases)
    private func cutoverFileWinsOverEveryOtherRow(_ row: Row) throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try row.arrange(f)
        try f.writeGarbage("\(Names.cutover)-\(UUID().uuidString)")
        let state = f.evaluate()
        #expect(state == f.failClosed(.cutoverV1Present))
        guard case .failClosed(let closed) = state else { return }
        #expect(closed.paths.contains { $0.lastPathComponent.hasPrefix(Names.cutover) })
    }

    @Test func aBareCutoverNameAndAnotherProfilesStubStillYieldCutoverFirst() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try f.writeStub(f.strangerProfile)
        try f.writeGarbage(Names.cutover)
        #expect(f.evaluate() == f.failClosed(.cutoverV1Present))
    }

    @Test(arguments: [Names.migrating, Names.swap, Names.preV2])
    private func firstRunIsOfferedOnlyWithoutLeftovers(_ leftover: String) throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        #expect(f.evaluate() == .firstRun)
        try f.writeGarbage(leftover)
        let state = f.evaluate()
        #expect(state == f.failClosed(.leftoversWithoutAuthority))
        #expect(state != .firstRun)
    }

    @Test func aCutoverLeftoverIsRowThirteenNotARowTenLeftover() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try f.writeGarbage(Names.cutover)
        #expect(f.evaluate() == f.failClosed(.cutoverV1Present))
    }

    @Test(arguments: Row.allCases)
    private func evaluateWritesNothing(_ row: Row) throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try row.arrange(f)
        let filesBefore = try f.snapshot()
        let keysBefore = Set(f.defaults.dictionaryRepresentation().keys)
        let witnessBefore = f.defaults.object(forKey: StoreAnchors.witnessKey).map { String(describing: $0) }
        _ = f.evaluate()
        _ = f.evaluate()
        #expect(try f.snapshot() == filesBefore)  // names, sizes and bytes: no -wal/-shm/scratch appears
        #expect(Set(f.defaults.dictionaryRepresentation().keys) == keysBefore)
        #expect(f.defaults.object(forKey: StoreAnchors.witnessKey).map { String(describing: $0) } == witnessBefore)
    }

    // MARK: Fail-closed paths

    @Test func failClosedPathsAreAbsoluteAndListOnlyExistingOptionalFiles() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try f.writeV1()
        try f.writeStore()

        func closed() -> StoreFailClosed? {
            guard case .failClosed(let closed) = f.evaluate() else { return nil }
            return closed
        }

        let plain = try #require(closed())
        #expect(plain.cause == .v1AfterMigration)
        #expect(plain.paths.allSatisfy { $0.path.hasPrefix("/") })
        #expect(
            plain.paths == [Names.store, Names.store + "-wal", Names.store + "-shm", Names.vault, Names.migrating].map(f.url)
        )
        #expect(plain.preMigrationBackup == nil)

        try f.writeGarbage(Names.preV2)
        let withBackup = try #require(closed())
        #expect(withBackup.paths.contains(f.url(Names.preV2)))
        #expect(withBackup.preMigrationBackup == f.url(Names.preV2))
        #expect(!withBackup.paths.contains(f.url(Names.swap)))

        try f.writeGarbage(Names.swap)
        try f.writeGarbage("\(Names.cutover)-A")
        try f.writeGarbage("\(Names.cutover)-B")
        let everything = try #require(closed())
        #expect(everything.cause == .cutoverV1Present)
        #expect(everything.paths.allSatisfy { $0.path.hasPrefix("/") })
        #expect(everything.paths.suffix(4) == [Names.swap, "\(Names.cutover)-A", "\(Names.cutover)-B", Names.preV2].map(f.url))
        #expect(everything.preMigrationBackup == f.url(Names.preV2))
    }

    // MARK: Read failures are never absence

    @Test(arguments: Unreadable.allCases)
    private func anExistingButUnreadableAnchorIsNeverAbsent(_ unreadable: Unreadable) throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        defer { f.makeReadable() }
        try unreadable.arrange(f)
        let namesBefore = try f.names()
        let state = f.evaluate()
        #expect(state == f.failClosed(unreadable.expectedCause))
        #expect(try f.names() == namesBefore)  // no -wal/-shm/scratch appears
        try f.writeGarbage("\(Names.cutover)-\(UUID().uuidString)")
        #expect(f.evaluate() == f.failClosed(.cutoverV1Present))  // row 13 still precedes an unreadable anchor
    }

    @Test(arguments: [Row.nothing, .legacy, .stubStore, .resume, .storeOnly])
    private func aDirectoryThatCannotBeListedProvesNeitherAbsenceNorLeftovers(_ row: Row) throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        defer { f.makeReadable() }
        try row.arrange(f)
        try f.writeGarbage("\(Names.cutover)-\(UUID().uuidString)")  // present but invisible once listing fails
        let namesBefore = try f.names()
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: f.directory.path)  // owner write+search, no read
        let state = f.evaluate()
        f.makeReadable()
        guard case .failClosed(let closed) = state else {
            Issue.record("\(row) yielded \(state) although the directory could not be listed")
            return
        }
        #expect(closed.cause == .unreadableStore)  // never .firstRun, .resumeMigration, .legacy or .provisional
        #expect(closed.paths.allSatisfy { $0.path.hasPrefix("/") })
        #expect(closed.paths.contains(f.url(Names.store)) && closed.paths.contains(f.url(Names.vault)))
        #expect(try f.names() == namesBefore)
    }

    @Test func aGenuinelyNonexistentDirectoryReadsAsEmptyAndIsNotCreated() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try FileManager.default.removeItem(at: f.directory)
        #expect(f.evaluate() == .firstRun)
        #expect(!FileManager.default.fileExists(atPath: f.directory.path))
    }

    @Test func aDirectoryPathThatIsAFileCannotBeListedAndFailsClosed() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try FileManager.default.removeItem(at: f.directory)
        try Data([1]).write(to: f.directory)
        let state = f.evaluate()
        guard case .failClosed(let closed) = state else {
            Issue.record("a file in place of the directory yielded \(state)")
            return
        }
        #expect(closed.cause == .unreadableStore)
    }

    // MARK: Store reading

    @Test func sqliteFileWithoutAUsableStoreMetaIsUnreadable() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try f.writeSQLite("CREATE TABLE unrelated(x INTEGER)")
        #expect(f.evaluate() == f.failClosed(.unreadableStore))
    }

    @Test func storeMetaWithWrongStorageClassesIsUnreadable() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try f.writeSQLite(
            """
            CREATE TABLE store_meta(id INTEGER PRIMARY KEY, schema INTEGER, storeID, profileID);
            INSERT INTO store_meta VALUES (1, 2, 12345, 67890);
            """
        )
        #expect(f.evaluate() == f.failClosed(.unreadableStore))
    }

    @Test func anEmptyStoreOrVaultFileIsUnreadableNotAbsent() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try f.writeEmpty(Names.store)
        #expect(f.evaluate() == f.failClosed(.unreadableStore))
        try FileManager.default.removeItem(at: f.url(Names.store))
        try f.writeEmpty(Names.vault)
        #expect(f.evaluate() == f.failClosed(.unreadableVault))
    }

    // MARK: Malformed A3 (Director ruling on §6.2/§6.3)

    @Test(arguments: MalformedWitness.allCases)
    private func aMalformedWitnessNeverCountsAsAbsent(_ malformed: MalformedWitness) throws {
        let layouts: [(Row, StoreFailCause)] = [
            (.nothing, .storeMissing),  // row 9: no authority, the witness remembers a store
            (.legacy, .v1AfterMigration),  // row 2
            (.storeOnly, .witnessMismatch),  // row 8
            (.stubStore, .foreignStore),  // row 5
            (.resume, .witnessMismatch),  // row 6: never resumes under a witness that cannot agree
            (.stubOnly, .witnessMismatch),
        ]
        for (row, cause) in layouts {
            let f = try StateFixture()
            defer { f.env.cleanUp() }
            try row.arrange(f)
            f.setWitness(malformed.value)
            #expect(f.evaluate() == f.failClosed(cause), "\(row) with \(malformed)")
        }
    }

    @Test func aPresentWitnessDisagreeingWithTheStubFailsClosedBeforeAnyResume() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try Row.resume.arrange(f)
        #expect(f.evaluate() == .resumeMigration(storeID: f.ids.storeID))  // the matching `.migrating` alone would resume
        f.setWitness(f.foreign.storeID.uuidString)
        let state = f.evaluate()
        #expect(state == f.failClosed(.witnessMismatch))
        if case .resumeMigration = state { Issue.record("resumed under a disagreeing witness") }
    }

    // MARK: Stub writing

    @Test func stubBytesAreTheBinaryPlistOfFormatTwo() throws {
        let ids = StoreIDs(storeID: StateFixture.storeID, profileID: StateFixture.vaultID)
        let bytes = StoreAnchors.stubBytes(ids: ids)
        #expect(bytes.starts(with: Data("bplist00".utf8)))
        let plist = try #require(try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any])
        #expect(Set(plist.keys) == ["format", "profileID", "storeID"])
        #expect(plist["format"] as? Int == 2)
        #expect(plist["profileID"] as? String == ids.profileID.uuidString)
        #expect(plist["storeID"] as? String == ids.storeID.uuidString)
    }

    @Test func oldReaderRejectsTheStubAsCorrupt() throws {
        let ids = StoreIDs(storeID: StateFixture.storeID, profileID: StateFixture.vaultID)
        #expect(throws: CredentialVaultError.corruptVault) {
            try CredentialVaultCrypto.decodeEnvelope(StoreAnchors.stubBytes(ids: ids), profileID: ids.profileID)
        }
    }

    @Test func stubWriteNeverOverwritesAnExistingV1File() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try f.writeV1()
        let before = try f.snapshot()
        #expect(throws: StoreFileError.exists) {
            try StoreAnchors.writeStubIfAbsent(directory: f.directory, ids: f.ids)
        }
        #expect(try f.snapshot() == before)  // v1 bytes unchanged, no temp file left behind
    }

    @Test func stubWriteCreatesTheStubWhenAbsent() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        try f.writeStore()
        #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: true))
        try StoreAnchors.writeStubIfAbsent(directory: f.directory, ids: f.ids)
        #expect(try Data(contentsOf: f.url(Names.vault)) == StoreAnchors.stubBytes(ids: f.ids))
        #expect(Set(try f.snapshot().keys) == [Names.store, Names.vault])
        #expect(f.evaluate() == .provisional(storeID: f.ids.storeID, stubMissing: false))

        let g = try StateFixture()
        defer { g.env.cleanUp() }
        try Row.resume.arrange(g)
        try FileManager.default.removeItem(at: g.url(Names.vault))
        try StoreAnchors.writeStubIfAbsent(directory: g.directory, ids: g.ids)
        #expect(g.evaluate() == .resumeMigration(storeID: g.ids.storeID))
    }

    @Test func stubWriteSyncsTheTempFileThenRenamesExclusivelyThenSyncsTheDirectory() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        let directoryPath = f.directory.path
        let steps = Mutex<[String]>([])
        var ops = StoreFileOps.live
        ops.fullFsync = { file in
            steps.withLock { $0.append("fullFsync:\(file.deletingLastPathComponent().path == directoryPath ? "dir" : "other")") }
            try StoreFileOps.live.fullFsync(file)
        }
        ops.renameExclusive = { from, to in
            steps.withLock { $0.append("renameExclusive:\(to.lastPathComponent)") }
            try StoreFileOps.live.renameExclusive(from, to)
        }
        ops.fsyncDirectory = { directory in
            steps.withLock { $0.append("fsyncDirectory:\(directory.path == directoryPath)") }
            try StoreFileOps.live.fsyncDirectory(directory)
        }
        try StoreAnchors.writeStubIfAbsent(directory: f.directory, ids: f.ids, fileOps: ops)
        #expect(steps.withLock { $0 } == ["fullFsync:dir", "renameExclusive:\(Names.vault)", "fsyncDirectory:true"])
    }

    @Test func stubWriteLeavesNoTempFileWhenAStepFails() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        var ops = StoreFileOps.live
        ops.fullFsync = { _ in throw StoreFileError.io(5) }
        #expect(throws: StoreFileError.io(5)) {
            try StoreAnchors.writeStubIfAbsent(directory: f.directory, ids: f.ids, fileOps: ops)
        }
        #expect(try f.snapshot().isEmpty)
    }

    // MARK: Witness

    @Test func witnessIsSetOnlyWhenAbsent() throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        #expect(StoreAnchors.setWitnessIfAbsent(f.ids.storeID, defaults: f.defaults))
        #expect(f.defaults.string(forKey: StoreAnchors.witnessKey) == f.ids.storeID.uuidString)
        #expect(!StoreAnchors.setWitnessIfAbsent(f.foreign.storeID, defaults: f.defaults))
        #expect(f.defaults.string(forKey: StoreAnchors.witnessKey) == f.ids.storeID.uuidString)
        #expect(!StoreAnchors.setWitnessIfAbsent(f.ids.storeID, defaults: f.defaults))
    }

    @Test(arguments: MalformedWitness.allCases)
    private func aMalformedWitnessIsNeverOverwritten(_ malformed: MalformedWitness) throws {
        let f = try StateFixture()
        defer { f.env.cleanUp() }
        f.setWitness(malformed.value)
        #expect(!StoreAnchors.setWitnessIfAbsent(f.ids.storeID, defaults: f.defaults))
        let stored = try #require(f.defaults.object(forKey: StoreAnchors.witnessKey))
        #expect((stored as AnyObject).isEqual(malformed.value), "\(malformed) was replaced by \(stored)")
    }
}
