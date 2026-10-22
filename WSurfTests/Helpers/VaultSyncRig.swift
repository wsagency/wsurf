// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import WSurfCore

@testable import WSurfVault

/// Two or more Macs, one profile and one vault, on one cloud.
@MainActor
final class VaultSyncRig {
    let cloud = FakeSyncCloud()
    let root = FileManager.default.temporaryDirectory.appending(path: "vault-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    let profile = UUID()
    let vaultID = UUID()
    let dek = SymmetricKey(size: .bits256)
    private var count = 0
    private var macs: [SimulatedMac] = []

    var zone: String {
        SyncZone.vault(profileID: profile, vaultID: vaultID)
    }

    var key: VaultSyncKey {
        VaultSyncKey.derive(dek: dek, profileID: profile, vaultID: vaultID)
    }

    func record(_ name: String) -> SyncRecord? {
        cloud.record(SyncRecordID(zone: zone, name: name))
    }

    func item(_ account: CredentialAccount) -> SyncRecord? {
        record(account.id.uuidString)
    }

    func status(_ mac: SimulatedMac) -> VaultSyncStatus {
        mac.sync.status(profileID: profile, vaultID: vaultID)
    }

    /// A Mac that holds the vault with `accounts`.
    func mac(
        holding accounts: [CredentialAccount] = [], unlocked: Bool = true, dek: SymmetricKey? = nil, excluded: Set<UUID> = []
    ) throws -> (mac: SimulatedMac, vault: FakeVault) {
        count += 1
        let mac = SimulatedMac(cloud: cloud, root: root.appending(path: "mac-\(count)", directoryHint: .isDirectory), excluded: excluded)
        let vault = try mac.host.addVault(profile: profile, vault: vaultID, dek: dek ?? self.dek, unlocked: unlocked)
        for account in accounts {
            vault.add(account)
        }
        mac.start()
        macs.append(mac)
        return (mac, vault)
    }

    /// A Mac that turned sync on for its vault, and sent it.
    func syncedMac(holding accounts: [CredentialAccount]) async throws -> (mac: SimulatedMac, vault: FakeVault) {
        let pair = try mac(holding: accounts)
        try await pair.mac.sync.enable(profileID: profile, vaultID: vaultID)
        try await pair.mac.pump()
        return pair
    }

    /// A Mac that adds the vault from iCloud, as the app does after the passkey: locked and empty, then unlocked.
    func addedMac(unlock: Bool = true, dek: SymmetricKey? = nil) async throws -> (mac: SimulatedMac, vault: FakeVault) {
        let pair = try mac(unlocked: false, dek: dek)
        await pair.mac.sync.adopted(profileID: profile, vaultID: vaultID)
        if unlock {
            await pair.mac.unlock(pair.vault)
            try await pair.mac.pump()
        }
        return pair
    }

    func finish() {
        // Close the sync databases before their folders go.
        for mac in macs {
            mac.sync.profileErased(profile)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

func syncAccounts(_ count: Int) -> [CredentialAccount] {
    (0..<count).map { SyncVaultFixtures.account(username: "user\($0)", origin: "https://site\($0).test") }
}

func syncChanging(_ account: CredentialAccount, password: String? = nil, note: String? = nil) -> CredentialAccount {
    var changed = account
    if let password {
        changed.password = password
    }
    if let note {
        changed.notes = [CredentialNote(text: note)]
    }
    return changed
}
