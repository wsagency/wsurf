// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Input History's key for one vault: HKDF-SHA256 of the vault's key, bound to the profile and the vault
/// (`ProfileVaultStore.inputHistoryKey`). It is never the vault's key, and only an unlocked vault gives it.
public nonisolated struct InputHistoryVaultKey: Sendable {
    public let vaultID: UUID
    public let key: SymmetricKey
}
