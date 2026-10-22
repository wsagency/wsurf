// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Vault, Trash and earlier-version state

/// A restore the vault refused, shown until it is dismissed or tried again. It offers only the same Trash copy again or
/// nothing: never another id, and never over what the vault already holds. It writes nothing.
public nonisolated struct RestoreBlocked: Equatable, Sendable {
    public enum Action: Hashable, Sendable { case retrySameCopy, dismiss }

    public let entryID: UUID
    public let block: UndeleteBlock

    public init(entryID: UUID, block: UndeleteBlock) {
        self.entryID = entryID
        self.block = block
    }

    /// In the order the page offers them.
    public var actions: [Action] {
        [.retrySameCopy, .dismiss]
    }
}

/// A permanent delete the user was shown. It lives in the authorization session, so a lock, a re-unlock or a change of vault
/// drops it: a confirmation shown for one vault can never delete from another. `emptyAll` purges EVERY Trash entry at the
/// moment of the write and ignores `entryIDs`, so `count` is only what the vault held when the confirmation was shown.
public nonisolated struct PendingPurge: Equatable, Sendable {
    public struct Warning: Equatable, Sendable {
        /// A purge removes rows from the vault file only; it cannot reach copies saved elsewhere.
        public let logicalOnly: Bool
        /// The copy made before this vault was upgraded, which still holds what is being purged.
        public let preMigrationBackup: URL?

        public init(logicalOnly: Bool, preMigrationBackup: URL?) {
            self.logicalOnly = logicalOnly
            self.preMigrationBackup = preMigrationBackup
        }
    }

    public let entryIDs: [UUID]
    public let emptyAll: Bool
    public let count: Int
    public let vaultID: UUID
    public let epoch: UInt64
    public let warning: Warning

    public init(
        entryIDs: [UUID],
        emptyAll: Bool,
        count: Int,
        vaultID: UUID,
        epoch: UInt64,
        warning: Warning
    ) {
        self.entryIDs = entryIDs
        self.emptyAll = emptyAll
        self.count = count
        self.vaultID = vaultID
        self.epoch = epoch
        self.warning = warning
    }
}

nonisolated extension RecordSubject {
    /// Earlier versions restore only these. A passkey is never rolled back to an older key.
    var restoresFromEarlierVersions: Bool {
        self == .password || self == .totp || self == .note || self == .secureItem || self == .attachment || self == .metadata
    }
}

nonisolated extension VaultListing {
    /// A vault's name is sealed until it unlocks, so a locked one is told apart by its ordinal (1-based; a number can come back after the highest vault is deleted).
    public var numberedName: String {
        String(localized: "Vault \(ordinal)")
    }

    /// The name only while the vault is unlocked: a listing kept across a lock never shows it.
    public var displayName: String {
        guard isUnlocked, let name else { return numberedName }
        return name
    }

    /// What every surface that lists or asks for a vault calls it, so one vault never reads "Vault 1" in one place and "Personal" in
    /// another. Unlocked and named: the name with its number ("Personal · Vault 1"). Locked: the number alone, since the name is
    /// sealed ("Vault 1 (locked)"). The vault's own name, to edit it, is `displayName`.
    public var label: String {
        guard isUnlocked else { return String(localized: "Vault \(ordinal) (locked)") }
        guard let name, !name.isEmpty, name != numberedName else { return numberedName }
        return String(localized: "\(name) · Vault \(ordinal)")
    }
}
