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
        case unavailable, storage, invalidSite, tooManySites, invalidProfile
    }

    private struct Document: Codable, Equatable {
        var version = 1
        var clients: [PairedClient] = []
        /// Extra developer sites as `host` or `host:port`, normalized by `MCPDeveloperAccess`.
        var developerSites: [String] = []
        /// Whether localhost, 127.0.0.1 and [::1] count as developer sites on any port.
        var includesThisMac = true
        /// The only profile where standing grants and the Developer tier work. Nil: none chosen, so neither applies.
        var developerProfileID: UUID?
        /// The profile WSurf created for developer work. Choosing any other profile needs the owner's confirmation.
        var dedicatedProfileID: UUID?
        /// Whether paired apps open and use new websites under the Website access default. Off until the owner turns it on in
        /// Settings. It lives here, not in the profile's SitePermissions file, which a process with a shell can edit.
        var appsFollowDefault = false
        /// The Website access default the owner approved for apps, as Settings last wrote it. The profile's own file can only
        /// lower what apps get from it.
        var appsDefaultLevel = AssistantAccessPolicy.ask

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            clients = try values.decodeIfPresent([PairedClient].self, forKey: .clients) ?? []
            developerSites = try values.decodeIfPresent([String].self, forKey: .developerSites) ?? []
            includesThisMac = try values.decodeIfPresent(Bool.self, forKey: .includesThisMac) ?? true
            developerProfileID = try values.decodeIfPresent(UUID.self, forKey: .developerProfileID)
            dedicatedProfileID = try values.decodeIfPresent(UUID.self, forKey: .dedicatedProfileID)
            appsFollowDefault = try values.decodeIfPresent(Bool.self, forKey: .appsFollowDefault) ?? false
            // A level this build does not know reads as Ask rather than making the whole document unreadable.
            appsDefaultLevel = Self.defaultLevel(try? values.decodeIfPresent(AssistantAccessPolicy.self, forKey: .appsDefaultLevel))
        }

        /// No Access is a choice for one website, never for the default, so it is stored as Ask.
        static func defaultLevel(_ policy: AssistantAccessPolicy?) -> AssistantAccessPolicy {
            switch policy {
            case .readOnly:
                .readOnly
            case .control:
                .control
            case .ask, .deny, nil:
                .ask
            }
        }
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
    private(set) var developerSites: [String] = []
    private(set) var includesThisMac = true
    private(set) var developerProfileID: UUID?
    private(set) var dedicatedProfileID: UUID?
    private(set) var appsFollowDefault = false
    private(set) var appsDefaultLevel = AssistantAccessPolicy.ask
    @ObservationIgnored private let storage: (any MCPTrustStorage)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var document = Document()
    @ObservationIgnored private var changeObservers: [@MainActor () -> Void] = []

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
        if publish(loaded, available: available) {
            notifyObservers()
        }
    }

    /// Calls `body` after every change to what is stored, so live connections can drop access that no longer holds.
    func onChange(_ body: @escaping @MainActor () -> Void) {
        changeObservers.append(body)
    }

    private func notifyObservers() {
        for observer in changeObservers {
            observer()
        }
    }

    /// Whether anything changed.
    @discardableResult
    private func publish(_ stored: Document, available: Bool) -> Bool {
        let changed = stored != document || available != isAvailable
        document = stored
        // Observers re-render on every assignment, so only assign a change.
        if isAvailable != available {
            isAvailable = available
        }
        if clients != stored.clients {
            clients = stored.clients
        }
        if developerSites != stored.developerSites {
            developerSites = stored.developerSites
        }
        if includesThisMac != stored.includesThisMac {
            includesThisMac = stored.includesThisMac
        }
        if developerProfileID != stored.developerProfileID {
            developerProfileID = stored.developerProfileID
        }
        if dedicatedProfileID != stored.dedicatedProfileID {
            dedicatedProfileID = stored.dedicatedProfileID
        }
        if appsFollowDefault != stored.appsFollowDefault {
            appsFollowDefault = stored.appsFollowDefault
        }
        if appsDefaultLevel != stored.appsDefaultLevel {
            appsDefaultLevel = stored.appsDefaultLevel
        }
        return changed
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
        // Only the "last used" label depends on this write; a failure must not interrupt a working connection, and no
        // access changed, so live connections have nothing to re-check.
        try? commit(updated, notifying: false)
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

    // MARK: Developer access

    /// What a paired client may do without asking. Only this store changes it, and it lives in the keychain with the
    /// pairing, so a process with a shell cannot raise it.
    func setStanding(_ standing: PairedClient.Standing, for id: UUID) throws {
        try edit { draft in
            guard let index = draft.clients.firstIndex(where: { $0.id == id }) else { return }
            draft.clients[index].standing = standing
        }
    }

    /// A paused client keeps its record and token but gets no standing grant until it is resumed.
    func setPaused(_ paused: Bool, for id: UUID) throws {
        try edit { draft in
            guard let index = draft.clients.firstIndex(where: { $0.id == id }) else { return }
            draft.clients[index].paused = paused
        }
    }

    /// Adds a developer site and returns its normalized form. Throws `Failure.invalidSite` for anything that is not an
    /// exact `host` or `host:port`.
    @discardableResult
    func addDeveloperSite(_ text: String) throws -> String {
        guard let site = MCPDeveloperAccess.normalizedSite(text) else { throw Failure.invalidSite }
        try edit { draft in
            guard !draft.developerSites.contains(site) else { return }
            guard draft.developerSites.count < MCPDeveloperAccess.maximumSites else { throw Failure.tooManySites }
            draft.developerSites.append(site)
        }
        return site
    }

    func removeDeveloperSite(_ site: String) throws {
        try edit { $0.developerSites.removeAll { $0 == site } }
    }

    func setIncludesThisMac(_ included: Bool) throws {
        try edit { $0.includesThisMac = included }
    }

    /// Chooses the profile where standing grants and the Developer tier work. `dedicated` marks a profile WSurf just
    /// created for this; any other choice is one the owner confirmed in Settings. Private browsing is never a choice.
    func setDeveloperProfile(_ id: UUID?, dedicated: Bool = false) throws {
        guard id != Profile.privateID else { throw Failure.invalidProfile }
        try edit { draft in
            draft.developerProfileID = id
            if dedicated {
                draft.dedicatedProfileID = id
            }
        }
    }

    // MARK: Website access default

    /// Lets paired apps follow the Website access default, up to `level`: what Settings shows as the default when the owner
    /// turns this on. Only Settings calls it, and the keychain holds it, so a process with a shell cannot turn it on.
    func setAppsFollowDefault(_ follows: Bool, level: AssistantAccessPolicy) throws {
        try edit { draft in
            draft.appsFollowDefault = follows
            draft.appsDefaultLevel = Document.defaultLevel(level)
        }
    }

    /// Records the default Settings now shows, so what apps may follow keeps up with the owner's own change. Settings only.
    /// Does nothing while following is off: the level matters only then, and turning it on writes the level too.
    func setAppsDefaultLevel(_ level: AssistantAccessPolicy) throws {
        loadIfNeeded()
        guard appsFollowDefault else { return }
        try edit { $0.appsDefaultLevel = Document.defaultLevel(level) }
    }

    /// Applies `change` to a copy and stores it, or stores nothing.
    private func edit(_ change: (inout Document) throws -> Void) throws {
        loadIfNeeded()
        guard isAvailable else { throw Failure.unavailable }
        var updated = document
        try change(&updated)
        guard updated != document else { return }
        try commit(updated)
    }

    private func commit(_ updated: Document, notifying: Bool = true) throws {
        guard let storage, isAvailable else { throw Failure.unavailable }
        do {
            try storage.write(try Self.encoder.encode(updated))
        } catch {
            throw Failure.storage
        }
        publish(updated, available: true)
        if notifying {
            notifyObservers()
        }
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
