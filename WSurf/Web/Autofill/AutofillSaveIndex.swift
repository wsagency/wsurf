// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import CryptoKit
import Foundation
import LocalAuthentication
import Synchronization

/// Per profile: the "Never for This Site" digests of every kind, and the rows the old Keychain lists filled from. Nothing writes the
/// rows of cards and addresses any more (a card's network, last four digits and holder, a contact's email and street, readable without
/// a prompt): they stay only until the person confirms the move into the vault, and `AutofillVaultMigration` then erases them.
nonisolated enum AutofillSaveIndex {
    enum Decision: Sendable {
        case new, update, unchanged, blocked
    }

    private struct Index: Codable {
        var key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var records: [String: [String: String]] = [:]
        var blocked: [String: Set<String>] = [:]
        var suggestions: [String: [AutofillSuggestion]] = [:]

        func digest(_ parts: [String]) throws -> String {
            guard key.count == 32 else { throw AutofillVaultError.invalidData }
            let data = try JSONEncoder().encode(parts)
            return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))).base64EncodedString()
        }
    }

    private static let lock = Mutex(())
    static let keychain: any AutofillSecureStorage = AutofillKeychainStorage(access: .whenUnlocked)

    static func service(_ profileID: UUID) -> String {
        var namespace = "io.wsagency.wsurf.autofill"
        if AppDatabase.isRunningTests { namespace += ".tests.\(ProcessInfo.processInfo.processIdentifier)" }
        #if DEBUG
        if StageMode.isActive { namespace += ".stage" }
        #endif
        return "\(namespace).save-index.\(profileID.uuidString)"
    }

    private static func access<T>(
        profileID: UUID, saving: Bool, storage: any AutofillSecureStorage = AutofillSaveIndex.keychain, _ body: (inout Index) throws -> T
    ) throws -> T {
        guard profileID != Profile.privateID else { throw AutofillVaultError.privateBrowsing }
        return try lock.withLock { _ in
            let context = LAContext()
            context.interactionNotAllowed = true
            let data = try storage.read(service: service(profileID), context: context)
            guard (data?.count ?? 0) <= 8_000_000 else { throw AutofillVaultError.invalidData }
            var index = try data.map { try JSONDecoder().decode(Index.self, from: $0) } ?? Index()
            let result = try body(&index)
            if saving {
                let encoded = try JSONEncoder().encode(index)
                guard encoded.count <= 8_000_000 else { throw AutofillVaultError.invalidData }
                try storage.write(encoded, service: service(profileID), context: context)
            }
            return result
        }
    }

    /// Whether the person chose "Never for This Site" for `kind` on `origin`.
    static func isBlocked(
        kind: AutofillSaveKind, origin: String, profileID: UUID, storage: any AutofillSecureStorage = AutofillSaveIndex.keychain
    ) throws -> Bool {
        try access(profileID: profileID, saving: false, storage: storage) { index in
            try index.blocked[kind.rawValue]?.contains(index.digest([kind.rawValue, origin])) == true
        }
    }

    static func replace(
        _ candidates: [AutofillSaveCandidate], kind: AutofillSaveKind, profileID: UUID,
        storage: any AutofillSecureStorage = AutofillSaveIndex.keychain
    ) throws {
        try access(profileID: profileID, saving: true, storage: storage) { index in
            var records: [String: String] = [:]
            for candidate in candidates {
                records[try index.digest([kind.rawValue] + candidate.identity)] = try index.digest([kind.rawValue] + candidate.values)
            }
            index.records[kind.rawValue] = records
            index.suggestions[kind.rawValue] = candidates.map(AutofillSuggestion.init)
        }
    }

    static func suggestions(kind: AutofillSaveKind, origin: String, profileID: UUID) throws -> [AutofillSuggestion] {
        try access(profileID: profileID, saving: false) { index in
            (index.suggestions[kind.rawValue] ?? []).filter {
                (kind != .password || $0.origin == origin) && !$0.isExpired
            }
        }
    }

    static func block(
        kind: AutofillSaveKind, origin: String, profileID: UUID, storage: any AutofillSecureStorage = AutofillSaveIndex.keychain
    ) throws {
        try access(profileID: profileID, saving: true, storage: storage) { index in
            var blocked = index.blocked[kind.rawValue] ?? []
            guard blocked.count < 1000 else { return }
            blocked.insert(try index.digest([kind.rawValue, origin]))
            index.blocked[kind.rawValue] = blocked
        }
    }

    static func resetBlocks(kind: AutofillSaveKind, profileID: UUID) throws {
        try access(profileID: profileID, saving: true) { $0.blocked[kind.rawValue] = nil }
    }

    /// Whether the index still holds a row (a digest or a suggestion) of any of `kinds`. Reads without a prompt.
    static func hasRows(of kinds: [AutofillSaveKind], profileID: UUID, storage: any AutofillSecureStorage = AutofillSaveIndex.keychain) throws -> Bool {
        try access(profileID: profileID, saving: false, storage: storage) { index in
            kinds.contains { !(index.records[$0.rawValue] ?? [:]).isEmpty || !(index.suggestions[$0.rawValue] ?? []).isEmpty }
        }
    }

    /// Removes every row of `kinds`: the record digests and the suggestions, keys and all. "Never for This Site" stays. An index that
    /// holds none is left as it is, and one that does not exist is not created.
    static func eraseRows(of kinds: [AutofillSaveKind], profileID: UUID, storage: any AutofillSecureStorage = AutofillSaveIndex.keychain) throws {
        guard try hasRows(of: kinds, profileID: profileID, storage: storage) else { return }
        try access(profileID: profileID, saving: true, storage: storage) { index in
            for kind in kinds {
                index.records[kind.rawValue] = nil
                index.suggestions[kind.rawValue] = nil
            }
        }
    }

    static func erase(profileID: UUID) throws {
        try lock.withLock { _ in try keychain.erase(service: service(profileID)) }
    }
}
