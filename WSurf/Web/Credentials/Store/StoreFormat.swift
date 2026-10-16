// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated enum StoreFormat {
    static let schema = 2, wrapperFormat = 1
    static let rowLabel = "WSurf credential store", registryLabel = "WSurf registry v1"
    static let busyTimeoutMS = 5000, historyPage = 50, nameLimit = 64, activeVaultLimit = 16
    static let journalOpsPerRow = 1000, historyRowBytes = 8_000_000, blockedOriginLimit = 4_096
    static let lockWait: Duration = .seconds(5), verifyingThreshold: Duration = .milliseconds(250)
}

// The SQL spellings below are the persisted format (§5): frozen strings, deliberately not derived from the Swift case names.
nonisolated enum VaultRole: UInt8, Sendable {
    case active = 1, trash

    var sqlName: String {
        switch self {
        case .active:
            "active"
        case .trash:
            "trash"
        }
    }

    init?(sqlName: String) {
        switch sqlName {
        case "active":
            self = .active
        case "trash":
            self = .trash
        default:
            return nil
        }
    }
}

nonisolated enum RecordKind: UInt8, Sendable {
    case account = 1, revision, trashEntry, tombstone

    var sqlName: String {
        switch self {
        case .account:
            "account"
        case .revision:
            "revision"
        case .trashEntry:
            "trashEntry"
        case .tombstone:
            "tombstone"
        }
    }

    init?(sqlName: String) {
        switch sqlName {
        case "account":
            self = .account
        case "revision":
            self = .revision
        case "trashEntry":
            self = .trashEntry
        case "tombstone":
            self = .tombstone
        default:
            return nil
        }
    }
}

nonisolated enum RecordSubject: UInt8, Codable, Sendable {
    case account = 1, password, totp, passkey, metadata, note

    var sqlName: String {
        switch self {
        case .account:
            "account"
        case .password:
            "password"
        case .totp:
            "totp"
        case .passkey:
            "passkey"
        case .metadata:
            "metadata"
        case .note:
            "note"
        }
    }

    init?(sqlName: String) {
        switch sqlName {
        case "account":
            self = .account
        case "password":
            self = .password
        case "totp":
            self = .totp
        case "passkey":
            self = .passkey
        case "metadata":
            self = .metadata
        case "note":
            self = .note
        default:
            return nil
        }
    }
}

nonisolated enum JournalOpKind: UInt8, Sendable { case add = 1, remove }
nonisolated enum TransferDirection: UInt8, Sendable { case `in` = 1, out }
nonisolated enum TransferScope: UInt8, Codable, Sendable { case account = 1, credential }
