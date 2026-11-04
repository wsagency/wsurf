// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// When each saved login was last filled, or signed in with, on each website it is saved for: the fill dropdown and Pick Credential…
/// list the one used last on the page's website first (`CredentialAccountSelection.lastUsedFirst`). One profile's, on this Mac only:
/// never in the vault and never synced (`NeverSyncTests`). A use is recorded only on a website the credential is already saved for.
/// The file names no website or credential: a key is the vault's keyed digest of the credential and that website
/// (`ImportMemoryKey.use(of:on:)`), which only that vault, unlocked, makes again; a value is its date.
@MainActor
final class AutofillLastUsed {
    /// The most uses kept; past it the oldest is dropped.
    static let limit = 1_000
    private var dates: [String: Date]
    private let file: URL
    private let persists: Bool
    private var saving: Task<Void, Never>?

    init(file: URL, persists: Bool = true) {
        self.file = file
        self.persists = persists
        dates = persists ? ((try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]) : [:]
    }

    /// `nil` without the vault's key: a vault that did not give one orders nothing.
    func date(_ key: ImportMemoryKey?, account: UUID, origin: String) -> Date? {
        key.flatMap { dates[Self.name($0.use(of: account, on: origin))] }
    }

    /// Returns the write it starts. Writes land in the order they were made.
    @discardableResult
    func record(_ key: ImportMemoryKey, account: UUID, origin: String, at date: Date = .now) -> Task<Void, Never>? {
        dates[Self.name(key.use(of: account, on: origin))] = date
        if dates.count > Self.limit, let oldest = dates.min(by: { $0.value < $1.value })?.key {
            dates[oldest] = nil
        }
        guard persists else { return nil }
        let snapshot = dates, file = file, previous = saving
        saving = Task {
            await previous?.value
            await JSONFileStore.shared.write(snapshot, to: file)
        }
        return saving
    }

    /// A use, recorded with the key of `manager`'s vault once it gives one: a vault locked meanwhile records nothing.
    func record(account: UUID, origin: String, in manager: CredentialManager) {
        Task {
            guard let key = try? await manager.importMemoryKey() else { return }
            record(key, account: account, origin: origin)
        }
    }

    private nonisolated static func name(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
