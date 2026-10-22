// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// What an import last brought for one entry, kept as keyed digests (`ImportMemoryKey`) and never as a value: the logins it stands for
/// (a website and an exact username each) and the password and note it had. A later import tells by these whether the other app changed
/// the entry since, whether WSurf did, or both; once the entry is deleted or merged away, they are what keeps an import from bringing it
/// back. It lives in the entry (or in the link of the entry it was merged into, or in its Trash entry or tombstone), so it is sealed with
/// the vault and travels with it to another Mac.
public nonisolated struct ImportTrace: Codable, Equatable, Sendable {
    /// `ImportMemoryKey.login` of each login, sorted, without repeats.
    public var logins: [Data]
    /// `ImportMemoryKey.password` of the password the import last saw, if it had one.
    public var password: Data?
    /// `ImportMemoryKey.note` of the note it last saw; `nil` when it had none.
    public var note: Data?

    /// Most logins one trace remembers. ponytail: a trace that would grow past it keeps the logins it has; raise it if an entry ever
    /// stands for more websites and usernames than this.
    public static let loginLimit = 256

    public init(logins: [Data], password: Data? = nil, note: Data? = nil) {
        self.logins = Array(Set(logins)).sorted { $0.lexicographicallyPrecedes($1) }
        self.password = password
        self.note = note
    }

    /// The logins of both, each once. A union past `loginLimit` keeps `self`'s.
    public func adding(_ other: [Data]) -> [Data] {
        let united = Array(Set(logins).union(other)).sorted { $0.lexicographicallyPrecedes($1) }
        return united.count <= Self.loginLimit ? united : logins
    }

    /// Only the logins: what a purged or removed entry keeps (`RemovedMemory`), never the digest of its password or note.
    var loginsOnly: ImportTrace {
        ImportTrace(logins: logins)
    }

    func validate() throws {
        let digests = logins + [password, note].compactMap { $0 }
        guard logins.count <= Self.loginLimit, digests.allSatisfy({ $0.count == ImportMemoryKey.digestBytes }),
              zip(logins, logins.dropFirst()).allSatisfy({ $0.lexicographicallyPrecedes($1) }) else { throw CredentialVaultError.invalidData }
    }
}

/// What a removed entry leaves for a Mac that never held it, so an import there does not bring it back: the logins it stood for, as
/// keyed digests (`ImportMemoryKey.login`), and the two ids the other app exported it under (`CredentialExchangeCodec`), which a
/// Passwords-app import matches exactly. Never the digest of a password or a note: once an entry is purged its History is gone, and
/// the digest of its last password would be all that is left of it. (An entry merged away keeps those in its survivor's link.) It is
/// what a removed state seals (`VaultSyncCodec`) and what a remembered tombstone keeps; the store's own tombstone of a purge keeps the
/// same logins (`TombstoneBody.trace`).
public nonisolated struct RemovedMemory: Codable, Equatable, Sendable {
    /// `ImportMemoryKey.login` of each login, sorted, without repeats.
    public var logins: [Data]
    /// The other app's account and item ids of the removed entry, as it stored them; `nil` for one that came from nowhere else.
    public var exchangeAccountID: Data?
    public var exchangeItemID: Data?

    /// Longest exchange id one removed state carries. ponytail: an id over it is left out (an exporter's ids are a few dozen bytes);
    /// the Mac that removed the entry still matches it by its own tombstone.
    public static let idLimit = 1_024

    public init(logins: [Data] = [], exchangeAccountID: Data? = nil, exchangeItemID: Data? = nil) {
        self.logins = Array(Set(logins)).sorted { $0.lexicographicallyPrecedes($1) }
        self.exchangeAccountID = exchangeAccountID.flatMap { Self.fits($0) ? $0 : nil }
        self.exchangeItemID = exchangeItemID.flatMap { Self.fits($0) ? $0 : nil }
    }

    /// Nothing an import could match.
    public var isEmpty: Bool {
        logins.isEmpty && !hasExchangeIDs
    }

    public var hasExchangeIDs: Bool {
        exchangeAccountID != nil || exchangeItemID != nil
    }

    private static func fits(_ id: Data) -> Bool {
        !id.isEmpty && id.count <= idLimit
    }

    func validate() throws {
        guard logins.count <= ImportTrace.loginLimit, logins.allSatisfy({ $0.count == ImportMemoryKey.digestBytes }),
              zip(logins, logins.dropFirst()).allSatisfy({ $0.lexicographicallyPrecedes($1) }),
              [exchangeAccountID, exchangeItemID].compactMap({ $0 }).allSatisfy(Self.fits) else { throw CredentialVaultError.invalidData }
    }
}

/// The key of a vault's import memory: HKDF-SHA256 of the vault's key under its own label, bound to the profile and the vault, so it is
/// the same on every Mac that holds the vault and never the vault's key. Only the store makes one, for an unlocked vault, and nothing
/// persists it. It turns a login, a password or a note into an HMAC that can be matched and not read.
public nonisolated struct ImportMemoryKey: Sendable {
    static let label = "WSurf import memory v1"
    static let digestBytes = 32
    private let key: SymmetricKey

    static func derive(dek: SymmetricKey, profileID: UUID, vaultID: UUID) -> ImportMemoryKey {
        var info = StoreWriter()
        info.text(label)
        info.uuid(profileID)
        info.uuid(vaultID)
        return ImportMemoryKey(key: HKDF<SHA256>.deriveKey(inputKeyMaterial: dek, salt: Data(), info: info.data, outputByteCount: 32))
    }

    /// One website and one exact username (UTF-8 bytes, as the vault compares them).
    public func login(origin: String, username: String) -> Data {
        digest("login") { $0.text(origin); $0.text(username) }
    }

    public func password(_ value: String) -> Data {
        digest("password") { $0.text(value) }
    }

    public func note(_ text: String) -> Data {
        digest("note") { $0.text(text) }
    }

    /// What `account` stands for now: each of its websites with its username and every login an import recorded for it, and the
    /// password and note an import last saw (else its own password, and its note when it has exactly one).
    public func trace(of account: CredentialAccount) -> ImportTrace {
        let own = account.origins.map { login(origin: $0, username: account.username) }
        let recorded = account.importTrace
        return ImportTrace(
            logins: (recorded?.adding(own) ?? ImportTrace(logins: own).logins),
            password: recorded?.password ?? account.password.map(password),
            note: recorded?.note ?? account.notes.flatMap { $0.count == 1 ? note($0[0].text) : nil }
        )
    }

    /// What a deleted `account` leaves to remember: its own trace, with the logins of the entries that were merged into it.
    public func removedTrace(of account: CredentialAccount) -> ImportTrace {
        var trace = trace(of: account)
        trace.logins = trace.adding((account.mergedFrom ?? []).flatMap { $0.trace?.logins ?? [] })
        return trace
    }

    /// What a deleted `account` leaves for a Mac that never held it: the logins of `removedTrace`, without the digest of its password
    /// or note, and the ids it was exported under.
    public func removedMemory(of account: CredentialAccount) -> RemovedMemory {
        RemovedMemory(logins: removedTrace(of: account).logins, exchangeAccountID: account.exchangeAccountID, exchangeItemID: account.exchangeItemID)
    }

    private func digest(_ kind: String, _ fields: (inout StoreWriter) -> Void) -> Data {
        var message = StoreWriter()
        message.text(kind)
        fields(&message)
        return Data(HMAC<SHA256>.authenticationCode(for: message.data, using: key))
    }
}

/// A key never prints, in a log line or in a failed assertion.
nonisolated extension ImportMemoryKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ImportMemoryKey"
    }

    public var debugDescription: String {
        "ImportMemoryKey"
    }
}
