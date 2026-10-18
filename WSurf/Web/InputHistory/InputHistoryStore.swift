// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import LocalAuthentication

// The encrypted store behind Input History: one directory per profile, one file per remembered field.
//
// - Recording can encrypt but never decrypt. It reads the public key and only checks that the private key exists, so it never
//   prompts and nothing on that path can open an entry. Opening needs the private key, which asks for Touch ID or the Mac password.
// - A file name carries what purging needs (`<expiry>-<created>-<uuid>.wih`), so expiry never reads or decrypts anything.
// - When the last entry goes, both keys go with it. Ciphertext that survives on the disk can no longer be read.
// - Nothing here logs, and no plaintext reaches the disk, the Keychain or user defaults.

nonisolated enum InputHistoryRetention: String, CaseIterable, Sendable {
    case thirtyMinutes
    case twoHours
    case oneDay
    case oneWeek
    case untilDeleted

    static let standard = InputHistoryRetention.thirtyMinutes

    /// Nil: the entry never expires.
    var milliseconds: Int64? {
        switch self {
        case .thirtyMinutes:
            30 * 60 * 1000
        case .twoHours:
            2 * 60 * 60 * 1000
        case .oneDay:
            24 * 60 * 60 * 1000
        case .oneWeek:
            7 * 24 * 60 * 60 * 1000
        case .untilDeleted:
            nil
        }
    }
}

nonisolated enum InputHistoryLimits {
    static let entries = 500
    static let value = 10_000
    static let password = 4_096
    static let username = 500
    static let title = 200
    static let label = 120
    static let url = 2_048
    static let key = 256
    /// One entry is far below this. A larger file was not written by the store and is deleted unread.
    static let fileBytes = 256 * 1024
    /// An entry created further ahead than this means the clock moved back since, and counts as expired.
    static let futureSkewMilliseconds: Int64 = 5 * 60 * 1000
}

nonisolated enum InputHistoryError: Error, Equatable {
    case privateBrowsing
    /// Another copy of WSurf owns the session and this copy keeps nothing.
    case unavailable
    case invalid
    case tooLarge
    /// The key pair could not open its own entries. Everything was deleted so the next entry starts a new pair.
    case keysUnusable
}

nonisolated struct InputHistoryStatus: Sendable, Equatable {
    var count: Int
    /// The earliest expiry still ahead, or nil when nothing expires.
    var nextExpiry: Date?
}

/// What is remembered for one field. The value is secret: a description never shows it.
nonisolated struct InputHistoryPayload: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    nonisolated enum Kind: String, Codable, Sendable, CaseIterable {
        case password, username, email, search, multiline, text
    }

    /// Origin and path of the top-level page. Query and fragment can hold reset tokens and are never kept.
    var url: String
    var frameOrigin: String?
    var title: String
    var label: String
    var kind: Kind
    var value: String
    /// The username next to a password.
    var username: String?

    var description: String {
        "InputHistoryPayload(\(kind.rawValue), redacted)"
    }

    var debugDescription: String {
        description
    }

    /// Rejects a value the store must not hold, and cuts the descriptive fields to their limits. A value is never cut: half a
    /// password is worse than none.
    func validated() throws -> InputHistoryPayload {
        guard !value.isEmpty else { throw InputHistoryError.invalid }
        let limit = kind == .password ? InputHistoryLimits.password : InputHistoryLimits.value
        // A grapheme count walks the whole string; the byte count bounds that work first.
        guard value.utf8.count <= limit * 4, value.count <= limit else { throw InputHistoryError.tooLarge }
        var copy = self
        copy.url = String(url.prefix(InputHistoryLimits.url))
        copy.frameOrigin = frameOrigin.map { String($0.prefix(InputHistoryLimits.url)) }
        copy.title = String(title.prefix(InputHistoryLimits.title))
        copy.label = String(label.prefix(InputHistoryLimits.label))
        // Half a username is as wrong as half a password: one that is too long is dropped.
        if let username, username.utf8.count > InputHistoryLimits.username * 4 || username.count > InputHistoryLimits.username {
            copy.username = nil
        }
        return copy
    }
}

nonisolated struct InputHistoryEntry: Identifiable, Sendable, Equatable {
    /// `<created milliseconds>-<uuid>`: the part of the file name that a retention change leaves alone.
    let id: String
    let createdAt: Date
    /// Nil when the entry is kept until the user deletes it.
    let expiresAt: Date?
    let payload: InputHistoryPayload
}

actor InputHistoryStore {
    private nonisolated static let fileExtension = "wih"
    private nonisolated static let version: UInt8 = 1
    private nonisolated static let encapsulatedKeyLength = 32

    private nonisolated static var suite: HPKE.Ciphersuite {
        .Curve25519_SHA256_ChachaPoly
    }

    private nonisolated struct Item {
        let url: URL
        let expiry: Int64?
        let created: Int64
        let identity: String

        /// Reads `<expiry>-<created>-<uuid>.wih`, where the expiry is milliseconds or `never`.
        init?(url: URL) {
            guard url.pathExtension == InputHistoryStore.fileExtension else { return nil }
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let created = Int64(parts[1]), created > 0, UUID(uuidString: String(parts[2])) != nil else { return nil }
            if parts[0] == "never" {
                expiry = nil
            } else if let expiry = Int64(parts[0]), expiry > 0 {
                self.expiry = expiry
            } else {
                return nil
            }
            self.url = url
            self.created = created
            identity = "\(parts[1])-\(parts[2])"
        }

        func isExpired(at now: Int64) -> Bool {
            // "Until I delete" has no expiry to stretch, so a clock change never removes it.
            guard let expiry else { return false }
            return expiry <= now || created > now + InputHistoryLimits.futureSkewMilliseconds
        }

        static func newerFirst(_ lhs: Item, _ rhs: Item) -> Bool {
            lhs.created != rhs.created ? lhs.created > rhs.created : lhs.identity > rhs.identity
        }
    }

    nonisolated let profileID: UUID
    /// The Keychain service of both keys. The two items differ in their account.
    nonisolated let service: String
    private let directory: URL
    private let privateKeys: any AutofillSecureStorage
    private let publicKeys: any AutofillSecureStorage
    private let ownsSession: Bool
    private let now: @Sendable () -> Date
    private let info: Data
    /// Coalescing key to entry identity, so the next commit of a field replaces its entry. Memory only: the keys name the fields
    /// of one page load and mean nothing after it.
    private var identities: [String: String] = [:]

    /// `privateKeys` holds the key that opens entries (user presence required) and `publicKeys` the key that seals them.
    /// `ownsSession` is false in a second copy of the app, which then changes nothing.
    init(
        profileID: UUID,
        directory: URL,
        privateKeys: any AutofillSecureStorage,
        publicKeys: any AutofillSecureStorage,
        ownsSession: Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profileID = profileID
        self.directory = directory
        self.privateKeys = privateKeys
        self.publicKeys = publicKeys
        self.ownsSession = ownsSession
        self.now = now
        service = "\(AutofillVaults.serviceNamespace()).input-history.\(profileID.uuidString)"
        info = Data("wsurf.input-history.v1|\(profileID.uuidString)".utf8)
    }

    // MARK: - Recording

    /// Seals `payload` to the public key. The next call with the same `key` replaces this entry.
    func record(_ payload: InputHistoryPayload, key: String, retention: InputHistoryRetention) throws -> InputHistoryStatus {
        try requireWritable()
        guard !key.isEmpty, key.utf8.count <= InputHistoryLimits.key else { throw InputHistoryError.invalid }
        let payload = try payload.validated()
        let publicKey = try keyForRecording()
        try prepareDirectory()
        let created = millis(now())
        let identity = "\(created)-\(UUID().uuidString)"
        let expiry = retention.milliseconds.map { String(created + $0) } ?? "never"
        let url = directory.appendingPathComponent("\(expiry)-\(identity).\(Self.fileExtension)")
        try write(seal(JSONEncoder().encode(payload), to: publicKey, identity: identity), to: url)

        var live = settle()
        if let previous = identities.updateValue(identity, forKey: key) {
            for item in live where item.identity == previous {
                _ = remove(item)
            }
            live.removeAll { $0.identity == previous }
        }
        let overflow = live.count - InputHistoryLimits.entries
        if overflow > 0 {
            for item in live.sorted(by: Item.newerFirst).suffix(overflow) {
                _ = remove(item)
            }
        }
        return status(settle())
    }

    /// Removes the entry the field's earlier commits made, after the user emptied the field.
    func forget(_ key: String) throws -> InputHistoryStatus {
        try requireWritable()
        var removed = false
        if let identity = identities.removeValue(forKey: key) {
            for item in settle() where item.identity == identity {
                removed = remove(item) || removed
            }
        }
        return status(settle(removed: removed))
    }

    // MARK: - Reading

    /// The number of entries and the next expiry, after deleting what has expired. Needs no authentication.
    func purge() -> InputHistoryStatus {
        status(settle())
    }

    func count() -> Int {
        purge().count
    }

    /// Decrypts every entry, newest first. Reading the private key is what asks for Touch ID or the Mac password.
    func unlock(reason: String) throws -> [InputHistoryEntry] {
        guard profileID != Profile.privateID else { throw InputHistoryError.privateBrowsing }
        let live = settle()
        guard !live.isEmpty else { return [] }
        let context = LAContext()
        context.localizedReason = reason
        guard let secret = try privateKeys.read(service: service, context: context),
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret),
              try publicKeys.read(service: service, context: context) == privateKey.publicKey.rawRepresentation
        else {
            throw resetUnusableKeys()
        }

        var entries: [InputHistoryEntry] = []
        var removed = false
        for item in live.sorted(by: Item.newerFirst) {
            guard let size = try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            guard size <= InputHistoryLimits.fileBytes else {
                removed = remove(item) || removed
                continue
            }
            guard let body = try? Data(contentsOf: item.url) else { continue }
            // A body that does not open under this name was moved here or damaged. It can never be shown.
            guard let plaintext = try? open(body, identity: item.identity, with: privateKey),
                  let payload = try? JSONDecoder().decode(InputHistoryPayload.self, from: plaintext)
            else {
                removed = remove(item) || removed
                continue
            }
            entries.append(
                InputHistoryEntry(
                    id: item.identity,
                    createdAt: date(item.created),
                    expiresAt: item.expiry.map(date),
                    payload: payload
                )
            )
        }
        if removed {
            _ = settle(removed: true)
        }
        return entries
    }

    // MARK: - Removing

    func delete(_ id: String) throws -> InputHistoryStatus {
        try requireWritable()
        var removed = false
        for item in settle() where item.identity == id {
            removed = remove(item) || removed
        }
        return status(settle(removed: removed))
    }

    /// Deletes every entry and both keys.
    func clear() throws -> InputHistoryStatus {
        try requireWritable()
        try wipe()
        return InputHistoryStatus(count: 0, nextExpiry: nil)
    }

    /// `clear` for a profile that is being removed: also allowed in a second copy of the app.
    func erase() throws {
        try wipe()
    }

    /// Moves every entry to the expiry the new retention gives it, measured from its creation, then purges.
    func applyRetention(_ retention: InputHistoryRetention) throws -> InputHistoryStatus {
        try requireWritable()
        var failure: (any Error)?
        for item in settle() {
            let expiry = retention.milliseconds.map { String(item.created + $0) } ?? "never"
            let target = directory.appendingPathComponent("\(expiry)-\(item.identity).\(Self.fileExtension)")
            guard target != item.url else { continue }
            do {
                try FileManager.default.moveItem(at: item.url, to: target)
            } catch {
                failure = failure ?? error
            }
        }
        let result = status(settle())
        if let failure {
            throw failure
        }
        return result
    }

    // MARK: - Keys

    /// The public key, made on the first call. It checks that the private key still exists but never reads it.
    private func keyForRecording() throws -> Curve25519.KeyAgreement.PublicKey {
        let context = LAContext()
        context.interactionNotAllowed = true
        let stored = try publicKeys.read(service: service, context: context)
        let privateExists = try privateKeys.exists(service: service)
        if let stored, privateExists, let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: stored) {
            return key
        }
        if stored != nil || privateExists {
            // Half a pair, or one that cannot be read: whatever was sealed to it can never be opened again.
            try wipe()
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        try privateKeys.write(privateKey.rawRepresentation, service: service, context: LAContext())
        try publicKeys.write(privateKey.publicKey.rawRepresentation, service: service, context: LAContext())
        return privateKey.publicKey
    }

    private func resetUnusableKeys() -> InputHistoryError {
        if ownsSession {
            try? wipe()
        }
        return .keysUnusable
    }

    /// Destroys the keys without a thought for errors: the entries they opened are already gone.
    private func destroyKeys() {
        try? privateKeys.erase(service: service)
        try? publicKeys.erase(service: service)
    }

    // MARK: - Encryption

    /// `0x01 | encapsulated key (32 bytes) | ciphertext`. The identity is authenticated, so a body moved to another name does not open.
    private func seal(_ plaintext: Data, to key: Curve25519.KeyAgreement.PublicKey, identity: String) throws -> Data {
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: Self.suite, info: info)
        let ciphertext = try sender.seal(plaintext, authenticating: Data(identity.utf8))
        return Data([Self.version]) + sender.encapsulatedKey + ciphertext
    }

    private func open(_ body: Data, identity: String, with key: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        let header = 1 + Self.encapsulatedKeyLength
        guard body.count > header, body.first == Self.version else { throw InputHistoryError.invalid }
        var recipient = try HPKE.Recipient(
            privateKey: key,
            ciphersuite: Self.suite,
            info: info,
            encapsulatedKey: body.dropFirst().prefix(Self.encapsulatedKeyLength)
        )
        return try recipient.open(body.dropFirst(header), authenticating: Data(identity.utf8))
    }

    // MARK: - Files

    private func requireWritable() throws {
        guard profileID != Profile.privateID else { throw InputHistoryError.privateBrowsing }
        guard ownsSession else { throw InputHistoryError.unavailable }
    }

    /// 0700, outside backups. The private profile never gets here: its directory would be a temporary one.
    private func prepareDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = directory
            try url.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func write(_ body: Data, to url: URL) throws {
        try body.write(to: url, options: .atomic)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Deletes the file. A second copy of the app deletes nothing.
    private func remove(_ item: Item) -> Bool {
        guard ownsSession else { return false }
        return (try? FileManager.default.removeItem(at: item.url)) != nil
    }

    /// The entries that have not expired. As a side effect: deletes what has, forgets coalescing keys whose entry is gone, and,
    /// when that leaves nothing, destroys the keys. `removed` says the caller deleted a file just before.
    private func settle(removed already: Bool = false) -> [Item] {
        // ponytail: the keys are destroyed only when the store empties; per-day key epochs if one deleted entry must be unreadable too
        guard profileID != Profile.privateID,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        let current = millis(now())
        var live: [Item] = []
        var removed = already
        for name in names where name.hasSuffix(".\(Self.fileExtension)") {
            let url = directory.appendingPathComponent(name)
            // A name the store never writes is deleted too: it can be neither opened nor expired.
            if let item = Item(url: url), !item.isExpired(at: current) {
                live.append(item)
            } else if ownsSession, (try? FileManager.default.removeItem(at: url)) != nil {
                removed = true
            }
        }
        let remaining = Set(live.map(\.identity))
        identities = identities.filter { remaining.contains($0.value) }
        if live.isEmpty, removed, ownsSession {
            destroyKeys()
        }
        return live
    }

    private func wipe() throws {
        identities = [:]
        guard profileID != Profile.privateID else { return }
        var failure: (any Error)?
        do {
            try privateKeys.erase(service: service)
        } catch {
            failure = error
        }
        do {
            try publicKeys.erase(service: service)
        } catch {
            failure = failure ?? error
        }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            failure = failure ?? error
        }
        if let failure {
            throw failure
        }
    }

    // MARK: - Time

    private func status(_ live: [Item]) -> InputHistoryStatus {
        InputHistoryStatus(count: live.count, nextExpiry: live.compactMap(\.expiry).min().map(date))
    }

    private func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private nonisolated func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}
