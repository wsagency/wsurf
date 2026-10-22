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

    func validate() throws {
        let digests = logins + [password, note].compactMap { $0 }
        guard logins.count <= Self.loginLimit, digests.allSatisfy({ $0.count == ImportMemoryKey.digestBytes }),
              zip(logins, logins.dropFirst()).allSatisfy({ $0.lexicographicallyPrecedes($1) }) else { throw CredentialVaultError.invalidData }
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
