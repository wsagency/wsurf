// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// When each saved login was last filled, or signed in with, on each website it is saved for: the fill dropdown and Pick Credential…
/// list the one used last on the page's website first (`CredentialAccountSelection.lastUsedFirst`). One profile's, on this Mac only:
/// never in the vault and never synced (`NeverSyncTests`). A use is recorded only on a website the credential is already saved for,
/// and the file names no website or credential: a key is a digest of the vault, the credential and that website, a value its date.
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

    func date(vault: UUID, account: UUID, origin: String) -> Date? {
        dates[Self.key(vault: vault, account: account, origin: origin)]
    }

    /// Returns the write it starts. Writes land in the order they were made.
    @discardableResult
    func record(vault: UUID, account: UUID, origin: String, at date: Date = .now) -> Task<Void, Never>? {
        dates[Self.key(vault: vault, account: account, origin: origin)] = date
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

    private nonisolated static func key(vault: UUID, account: UUID, origin: String) -> String {
        SHA256.hash(data: Data("\(vault.uuidString) \(account.uuidString) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
