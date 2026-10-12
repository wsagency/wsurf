// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB

nonisolated enum StoreOpenState: Equatable, Sendable {
    case legacy(vaultID: UUID), firstRun, provisional(storeID: UUID, stubMissing: Bool), resumeMigration(storeID: UUID)
    case failClosed(StoreFailClosed)
}

/// The three anchors of §6.2 and the §6.3 state machine. Evaluation reads and never writes. Only a verified absence
/// (`ENOENT`) is absence: any other failure to look at an existing file or directory is unreadable and fails closed.
nonisolated enum StoreAnchors {
    static let witnessKey = "io.wsagency.wsurf.credentialVault.storeID"

    private nonisolated enum Names {
        static let store = "Credentials.store"
        static let vault = "Credentials.vault"
        static let migrating = "Credentials.store.migrating"
        static let swap = "Credentials.vault.swap"
        static let cutover = "Credentials.vault.cutover-v1"
        static let preV2 = "Credentials.vault.pre-v2"
    }

    private nonisolated enum Vault {
        case absent, v1(vaultID: UUID), stub(StoreIDs), wrongProfile, unreadable
    }

    private nonisolated enum Store {
        case absent, present(StoreIDs), unreadable
    }

    /// A3 is present when its object exists, whatever its type; only a string parsing as a UUID can ever agree.
    private nonisolated enum Witness {
        case absent, present(UUID?)

        func disagrees(with storeID: UUID) -> Bool {
            if case .present(let witnessed) = self {
                return witnessed != storeID
            }
            return false
        }
    }

    private nonisolated struct StubPlist: Codable {
        let format: Int
        let profileID: UUID
        let storeID: UUID
    }

    private static let stubFormat = 2

    // MARK: Evaluation (§6.3)

    static func evaluate(directory: URL, profileID: UUID, defaults: UserDefaults) -> StoreOpenState {
        guard let cutovers = cutoverNames(in: directory) else { return failClosed(.unreadableStore, directory, cutovers: []) }
        func closed(_ cause: StoreFailCause) -> StoreOpenState {
            failClosed(cause, directory, cutovers: cutovers)
        }
        guard cutovers.isEmpty else { return closed(.cutoverV1Present) }  // row 13: before every other row

        let vault = readVault(url(directory, Names.vault), profileID: profileID)
        let store = readStore(url(directory, Names.store))
        if case .wrongProfile = vault {
            return closed(.wrongProfile)
        }
        if case .present(let meta) = store, meta.profileID != profileID {
            return closed(.wrongProfile)
        }
        let witness = readWitness(defaults)

        switch (vault, store) {
        case (.unreadable, _), (.wrongProfile, _):
            return closed(.unreadableVault)  // row 11 (wrongProfile returned above)
        case (_, .unreadable):
            return closed(.unreadableStore)  // row 12
        case (.v1(let vaultID), .absent):
            if case .absent = witness { return .legacy(vaultID: vaultID) }  // row 1
            return closed(.v1AfterMigration)  // row 2
        case (.v1, .present):
            return closed(.v1AfterMigration)  // row 3
        case (.stub(let ids), .present(let meta)):
            if meta.storeID != ids.storeID || witness.disagrees(with: ids.storeID) { return closed(.foreignStore) }  // row 5
            return .provisional(storeID: ids.storeID, stubMissing: false)  // row 4
        case (.stub(let ids), .absent):
            if witness.disagrees(with: ids.storeID) { return closed(.witnessMismatch) }  // row 6: before any resume (§6.2)
            if case .present(let pending) = readStore(url(directory, Names.migrating)), pending == ids {
                return .resumeMigration(storeID: ids.storeID)  // row 6
            }
            return closed(.storeMissing)
        case (.absent, .present(let meta)):
            if witness.disagrees(with: meta.storeID) { return closed(.witnessMismatch) }  // row 8
            return .provisional(storeID: meta.storeID, stubMissing: true)  // row 7
        case (.absent, .absent):
            if case .present = witness { return closed(.storeMissing) }  // row 9
            let leftovers = [Names.migrating, Names.swap, Names.preV2].contains { exists(url(directory, $0)) }
            return leftovers ? closed(.leftoversWithoutAuthority) : .firstRun  // row 10
        }
    }

    // MARK: Stub and witness writes

    /// Binary plist `{format: 2, profileID, storeID}`; an old reader's `decodeEnvelope` rejects it as corrupt (the fence).
    static func stubBytes(ids: StoreIDs) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(StubPlist(format: stubFormat, profileID: ids.profileID, storeID: ids.storeID))) ?? Data()
    }

    /// Temp file, `F_FULLFSYNC`, `RENAME_EXCL` onto `Credentials.vault` (an existing v1 file ⇒ `StoreFileError.exists`), fsync directory.
    static func writeStubIfAbsent(directory: URL, ids: StoreIDs, fileOps: StoreFileOps = .live) throws {
        let bytes = stubBytes(ids: ids)
        guard !bytes.isEmpty else { throw StoreFileError.io(EINVAL) }
        let temp = url(directory, "\(Names.vault).stub-\(UUID().uuidString)")
        try bytes.write(to: temp, options: .withoutOverwriting)
        do {
            try fileOps.fullFsync(temp)
            try fileOps.renameExclusive(temp, url(directory, Names.vault))
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try fileOps.fsyncDirectory(directory)
    }

    /// `false` = an A3 object already exists (of any type or content); it is never overwritten.
    static func setWitnessIfAbsent(_ storeID: UUID, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: witnessKey) == nil else { return false }
        defaults.set(storeID.uuidString, forKey: witnessKey)
        return true
    }

    // MARK: Reading

    private static func url(_ directory: URL, _ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Absent only when `lstat` says `ENOENT`; any other outcome counts as existing.
    static func exists(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return true }
            var info = stat()
            return lstat(path, &info) == 0 || errno != ENOENT
        }
    }

    /// The `cutover-v1*` names, `[]` for a directory that verifiably does not exist, `nil` when listing failed.
    private static func cutoverNames(in directory: URL) -> [String]? {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(Names.cutover) }.sorted()
        } catch {
            return exists(directory) ? nil : []
        }
    }

    private static func readPrefix(_ file: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func readVault(_ file: URL, profileID: UUID) -> Vault {
        guard exists(file) else { return .absent }
        guard let data = try? readPrefix(file, count: CredentialVaultLimits.fileBytes + 1) else { return .unreadable }
        do {
            return .v1(vaultID: try CredentialVaultCrypto.decodeEnvelope(data, profileID: profileID).vaultID)
        } catch CredentialVaultError.wrongProfile {
            return .wrongProfile
        } catch {
            guard data.starts(with: Data("bplist00".utf8)),
                  let stub = try? PropertyListDecoder().decode(StubPlist.self, from: data), stub.format == stubFormat else { return .unreadable }
            return stub.profileID == profileID ? .stub(StoreIDs(storeID: stub.storeID, profileID: stub.profileID)) : .wrongProfile
        }
    }

    /// Present = a readable `store_meta`, read through a read-only `immutable=1` connection: it never creates `-wal`/`-shm`, and
    /// (creation checkpoints) ignores any WAL. No separate header read: SQLite validates the header itself, and a second descriptor
    /// on a file other connections may hold open is avoidable I/O that SQLite §2.2 (POSIX advisory locks) says to avoid for portability.
    private static func readStore(_ file: URL) -> Store {
        guard exists(file) else { return .absent }
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: file.absoluteString + "?immutable=1", configuration: configuration)
            guard let meta = try queue.read({ (db: Database) throws in try StoreTables.storeMeta(db) }) else { return .unreadable }
            return .present(meta.ids)
        } catch {
            return .unreadable
        }
    }

    private static func readWitness(_ defaults: UserDefaults) -> Witness {
        guard let object = defaults.object(forKey: witnessKey) else { return .absent }
        return .present((object as? String).flatMap { UUID(uuidString: $0) })
    }

    // MARK: Fail closed (§6.4)

    /// The five core paths always; `.swap`, every `cutover-v1*` and `.pre-v2` only when they exist.
    private static func failClosed(_ cause: StoreFailCause, _ directory: URL, cutovers: [String]) -> StoreOpenState {
        let core = [Names.store, Names.store + "-wal", Names.store + "-shm", Names.vault, Names.migrating]
        let swap = exists(url(directory, Names.swap)) ? [Names.swap] : []
        let backup = exists(url(directory, Names.preV2)) ? [Names.preV2] : []
        return .failClosed(
            StoreFailClosed(
                cause: cause,
                paths: (core + swap + cutovers + backup).map { url(directory, $0) },
                preMigrationBackup: backup.isEmpty ? nil : url(directory, Names.preV2)
            )
        )
    }
}
