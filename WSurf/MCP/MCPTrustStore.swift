// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import Security

/// An MCP client the user paired with WSurf. It holds the hash of the client's token, never the token.
nonisolated struct PairedClient: Codable, Identifiable, Sendable, Equatable {
    /// How much a paired client may do without asking. Only the trust store changes it.
    nonisolated enum Standing: String, Codable, Sendable {
        case off, development, developer
    }

    let id: UUID
    var name: String
    /// `MCPClientKind.rawValue`, or nil for a client set up with Copy Configuration.
    var kindID: String?
    var tokenHash: Data
    var created: Date
    var lastUsed: Date?
    var standing = Standing.off
    var paused = false

    var kind: MCPClientKind? {
        kindID.flatMap(MCPClientKind.init(rawValue:))
    }
}

/// Where the trust document is kept. Production uses the data-protection keychain; tests inject memory.
nonisolated protocol MCPTrustStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

nonisolated struct MCPKeychainTrustStorage: MCPTrustStorage {
    nonisolated struct Failure: Error {
        let status: OSStatus
    }

    static var service: String {
        var service = "io.wsagency.wsurf.mcp-trust"
        #if DEBUG
        if StageMode.isActive { service += ".stage" }
        #endif
        return service
    }

    /// A data-protection keychain item of WSurf's own access group: other processes cannot rewrite it, unlike a
    /// UserDefaults key an agent with a shell could set.
    static func query(service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "pairing",
         kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func read() throws -> Data? {
        var query = Self.query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    func write(_ data: Data) throws {
        let status = SecItemUpdate(Self.query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var item = Self.query()
        item[kSecValueData as String] = data
        // Unattended runs need the document while the screen is locked, but never on another device.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }
}

/// The paired clients, kept in the keychain so a process with a shell cannot add one.
///
/// Unavailable means the document could not be read (an unsigned build has no keychain access group, or the stored
/// document is damaged or newer). It then fails closed: nothing authenticates, nothing is written, and the stored
/// document is never replaced. Unpaired connections still work through the consent sheet.
@MainActor
@Observable
final class MCPTrustStore {
    nonisolated enum Failure: Error {
        case unavailable, storage
    }

    private struct Document: Codable {
        var version = 1
        var clients: [PairedClient] = []
        /// Reserved for the Developer tier; preserved so a newer build does not lose them.
        var developerSites: [String] = []
        var developerProfileID: UUID?
    }

    static let shared: MCPTrustStore = {
        // Tests never reach the real keychain; they inject their own storage.
        let storage: (any MCPTrustStorage)? = AppDatabase.isRunningTests ? nil : MCPKeychainTrustStorage()
        return MCPTrustStore(storage: storage)
    }()
    /// A client seen again within this interval is not written to the keychain again.
    static let lastUsedInterval: TimeInterval = 60

    private(set) var clients: [PairedClient] = []
    private(set) var isAvailable = false
    @ObservationIgnored private let storage: (any MCPTrustStorage)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var document = Document()

    /// `nil` storage is a store that is never available.
    init(storage: (any MCPTrustStorage)?, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
    }

    /// Loads the document, and tries again while it is unavailable, so a keychain that was locked a moment ago does
    /// not leave unattended runs unpaired for the rest of the session.
    func loadIfNeeded() {
        if !isAvailable {
            reload()
        }
    }

    func reload() {
        var loaded = Document()
        var available = false
        if let storage {
            do {
                if let data = try storage.read() {
                    let decoded = try Self.decoder.decode(Document.self, from: data)
                    guard decoded.version == 1 else { throw Failure.unavailable }
                    loaded = decoded
                }
                available = true
            } catch {
                // Unreadable, damaged or newer: stay unavailable and never overwrite it.
            }
        }
        document = loaded
        // Observers re-render on every assignment, so only assign a change.
        if isAvailable != available {
            isAvailable = available
        }
        if clients != loaded.clients {
            clients = loaded.clients
        }
    }

    func client(id: UUID) -> PairedClient? {
        clients.first { $0.id == id }
    }

    /// The client that owns this token, if any. Compares against every record so timing does not reveal which.
    /// Reads what is loaded; call `loadIfNeeded()` first.
    func client(forToken token: String) -> PairedClient? {
        guard isAvailable, MCPPairing.isWellFormed(token) else { return nil }
        let hash = MCPPairing.hash(token)
        var match: PairedClient?
        for client in clients where MCPPairing.constantTimeEquals(client.tokenHash, hash) {
            match = client
        }
        return match
    }

    /// Identifies the client behind a presented token and notes that it is in use.
    func authenticate(token: String) -> PairedClient? {
        loadIfNeeded()
        guard let client = client(forToken: token) else { return nil }
        touch(client.id)
        return self.client(id: client.id)
    }

    /// Records a use, at most once per `lastUsedInterval`.
    func touch(_ id: UUID) {
        guard let index = document.clients.firstIndex(where: { $0.id == id }) else { return }
        let current = now()
        if let last = document.clients[index].lastUsed, current.timeIntervalSince(last) < Self.lastUsedInterval {
            return
        }
        var updated = document
        updated.clients[index].lastUsed = current
        // Only the "last used" label depends on this write; a failure must not interrupt a working connection.
        try? commit(updated)
    }

    /// Stores the hash of `token`. With `replacing`, that client gets the new token and keeps its identity and
    /// settings; the old token stops working at once.
    @discardableResult
    func pair(token: String, name: String, kind: MCPClientKind?, replacing id: UUID? = nil) throws -> PairedClient {
        loadIfNeeded()
        guard isAvailable, MCPPairing.isWellFormed(token) else { throw Failure.unavailable }
        var updated = document
        let hash = MCPPairing.hash(token)
        let client: PairedClient
        if let id, let index = updated.clients.firstIndex(where: { $0.id == id }) {
            updated.clients[index].tokenHash = hash
            client = updated.clients[index]
        } else {
            let taken = Set(updated.clients.map(\.name))
            let base = Self.cleaned(name)
            var unique = base
            var number = 2
            while taken.contains(unique) {
                unique = "\(base) \(number)"
                number += 1
            }
            client = PairedClient(id: UUID(), name: unique, kindID: kind?.rawValue, tokenHash: hash, created: now())
            updated.clients.append(client)
        }
        try commit(updated)
        return client
    }

    /// Forgets the client. Its token stops working immediately; callers disconnect its live sessions.
    func revoke(_ id: UUID) throws {
        loadIfNeeded()
        guard isAvailable else { throw Failure.unavailable }
        guard document.clients.contains(where: { $0.id == id }) else { return }
        var updated = document
        updated.clients.removeAll { $0.id == id }
        try commit(updated)
    }

    private func commit(_ updated: Document) throws {
        guard let storage, isAvailable else { throw Failure.unavailable }
        do {
            try storage.write(try Self.encoder.encode(updated))
        } catch {
            throw Failure.storage
        }
        document = updated
        clients = updated.clients
    }

    private static func cleaned(_ name: String) -> String {
        let visible = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "External app") : String(trimmed.prefix(60))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
