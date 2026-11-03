// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import WSurfVault

/// The one-time move of the payment cards, contacts and addresses that autofill kept in this Mac's Keychain, outside the vault, into a
/// vault the person has unlocked. This type holds the rules; `AutofillMigrationCard` drives them and shows every step.
///
/// Nothing is read until the person chooses Review. One commit (cause `autofill-migration`) writes an entry for every card whose
/// number and every contact whose values the vault does not hold yet; the ids it wrote are kept in the profile's defaults (ids only,
/// before the write, so a crash after it still finds them). Every entry is then mapped back and compared with its old copy. Until the
/// person confirms, the old copies stay untouched and Undo moves the written entries to Trash. The confirmation names the counts; only
/// then are the card list, the contact list and the card and contact rows of the save index erased, and the erasure checked.
///
/// The state moves forward (`pending`, `imported`, `done`) except through Undo, which puts it back to `pending`. Private browsing never
/// had a list, so it never reads, prompts or stores anything here.
@MainActor
struct AutofillVaultMigration {
    enum State: String, Sendable {
        case pending, imported, done

        fileprivate var rank: Int {
            switch self {
            case .pending:
                0
            case .imported:
                1
            case .done:
                2
            }
        }
    }

    /// Why `erase` refused, or found something left. When it refused, nothing was erased.
    enum Failure: Error, Equatable {
        /// Nothing has been moved yet, so the old lists are still the only copy.
        case notImported
        /// The old lists or the vault are not what the confirmation described.
        case changed
        /// An old list, or a row of the save index, is still there after the erasure.
        case notErased
    }

    /// The old copies, read for one operation.
    struct Sources: Codable, Sendable {
        var cards: [PaymentCard]
        var contacts: [AutofillContact]
    }

    /// Where every old card and address is now, as the review and the confirmation state it.
    struct Report: Equatable, Sendable {
        /// Held by an entry the move wrote, which maps back to exactly the old copy.
        var moved = 0
        /// Held by another entry: a card with that number, or a contact with those values.
        var alreadyThere = 0
        /// In no entry of the vault: erasing the old lists deletes it.
        var missing = 0
        /// The old copies the report was made from, so a confirmation never covers lists that changed since.
        fileprivate var digest = Data()

        var total: Int {
            moved + alreadyThere + missing
        }
    }

    static let stateKey = "autofill.vaultItems.state"
    /// Vault id -> the ids of the entries the move wrote into it.
    static let movedKey = "autofill.vaultItems.moved"

    let profile: Profile
    /// The old lists, read and erased only: nothing in WSurf writes them any more.
    var cards: PaymentCardVault
    var contacts: SecureAutofillVault<AutofillContact>
    var indexStorage: any AutofillSecureStorage = AutofillSaveIndex.keychain
    private let injectedDefaults: UserDefaults?

    init(
        profile: Profile, cards: PaymentCardVault? = nil, contacts: SecureAutofillVault<AutofillContact>? = nil, defaults: UserDefaults? = nil
    ) {
        self.profile = profile
        self.cards = cards ?? AutofillVaults.cards(for: profile.id)
        self.contacts = contacts ?? AutofillVaults.contacts(for: profile.id)
        injectedDefaults = defaults
    }

    /// The profile's own settings. Resolved only for a profile that can have a list: a private context has no settings domain.
    private var defaults: UserDefaults {
        injectedDefaults ?? ProfileSettingsStore.defaults(for: profile)
    }

    // MARK: State

    var storedState: State? {
        guard !profile.isPrivate else { return .done }
        return defaults.string(forKey: Self.stateKey).flatMap(State.init(rawValue:))
    }

    /// Where the move stands. Asks the Keychain whether the old lists exist, which reads nothing and never prompts, so it is safe when
    /// the page opens. With both lists gone there is nothing to move: rows of the save index that would fill from them are dropped and
    /// the move is done. A Keychain error says nothing about the lists: it answers what is stored and persists nothing.
    func state() async -> State {
        guard !profile.isPrivate else { return .done }
        let stored = storedState
        if stored == .done {
            return .done
        }
        switch try? await hasOldLists() {
        case false?:
            try? AutofillSaveIndex.eraseRows(of: [.card, .contact], profileID: profile.id, storage: indexStorage)
            finish()
            return .done
        case true?, nil:
            return stored ?? .pending
        }
    }

    private func hasOldLists() async throws -> Bool {
        if try await cards.hasStoredCards() {
            return true
        }
        return try await contacts.hasStoredRecords()
    }

    private func advance(to next: State) {
        guard !profile.isPrivate, (storedState?.rank ?? -1) < next.rank else { return }
        defaults.set(next.rawValue, forKey: Self.stateKey)
    }

    private func finish() {
        advance(to: .done)
        defaults.removeObject(forKey: Self.movedKey)
    }

    /// The ids of the entries the move wrote into `vaultID`.
    func movedIDs(in vaultID: UUID) -> Set<UUID> {
        let all = defaults.dictionary(forKey: Self.movedKey) as? [String: [String]] ?? [:]
        return Set((all[vaultID.uuidString] ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func record(_ ids: Set<UUID>, in vaultID: UUID) {
        var all = defaults.dictionary(forKey: Self.movedKey) as? [String: [String]] ?? [:]
        all[vaultID.uuidString] = ids.isEmpty ? nil : ids.map(\.uuidString).sorted()
        if all.isEmpty {
            defaults.removeObject(forKey: Self.movedKey)
        } else {
            defaults.set(all, forKey: Self.movedKey)
        }
    }

    // MARK: Reading

    /// One Touch ID prompt covers every read of the card list under this session; the contact list never prompts.
    func makeSession() async throws -> AutofillAuthenticationSession {
        try await cards.makeAuthenticationSession()
    }

    func sources(using session: AutofillAuthenticationSession) async throws -> Sources {
        guard !profile.isPrivate else { throw AutofillVaultError.privateBrowsing }
        return Sources(cards: try await cards.cards(using: session), contacts: try await contacts.records())
    }

    // MARK: Rules

    /// The entries the move writes into a vault holding `accounts`: one for every old card whose number it does not hold, and one for
    /// every old contact whose values no entry holds, each once.
    static func entries(for sources: Sources, in accounts: [CredentialAccount]) -> [CredentialAccount] {
        var numbers = Set(accounts.flatMap { $0.secureItems ?? [] }.compactMap(VaultItemAutofill.paymentCard).map(\.number))
        var contacts = Set(accounts.compactMap(VaultItemAutofill.contact(of:)).map { AutofillSaveCandidate.contact($0).values })
        var result: [CredentialAccount] = []
        for card in sources.cards where numbers.insert(card.number).inserted {
            result.append(VaultItemAutofill.account(for: card))
        }
        for contact in sources.contacts where contacts.insert(AutofillSaveCandidate.contact(contact).values).inserted {
            result.append(VaultItemAutofill.account(for: contact))
        }
        return result
    }

    /// Maps every entry of `accounts` back and compares it with each old copy: moved (an entry in `moved` maps back to exactly the
    /// old copy), already there (another entry holds that card number, or those contact values), or missing.
    static func report(for sources: Sources, in accounts: [CredentialAccount], moved: Set<UUID>) -> Report {
        var cards: [String: [(id: UUID, card: PaymentCard)]] = [:]
        var contacts: [[String]: [UUID]] = [:]
        for account in accounts {
            for card in (account.secureItems ?? []).compactMap(VaultItemAutofill.paymentCard) {
                cards[card.number, default: []].append((id: account.id, card: card))
            }
            if let contact = VaultItemAutofill.contact(of: account) {
                contacts[AutofillSaveCandidate.contact(contact).values, default: []].append(account.id)
            }
        }
        var report = Report(digest: digest(sources))
        for card in sources.cards {
            let holders = cards[card.number] ?? []
            if holders.contains(where: { moved.contains($0.id) && VaultItemAutofill.sameCard($0.card, card) }) {
                report.moved += 1
            } else if holders.contains(where: { !moved.contains($0.id) }) {
                report.alreadyThere += 1
            } else {
                report.missing += 1
            }
        }
        for contact in sources.contacts {
            let holders = contacts[AutofillSaveCandidate.contact(contact).values] ?? []
            if holders.contains(where: moved.contains) {
                report.moved += 1
            } else if !holders.isEmpty {
                report.alreadyThere += 1
            } else {
                report.missing += 1
            }
        }
        return report
    }

    /// SHA-256 of a canonical field list of the old copies, in list order: per card its number, name, expiry and security code, per
    /// contact its label and values. The JSON of the structs themselves is never hashed: its key order differs between two encodings of
    /// the same value, so a confirmation would never match the lists read again.
    static func digest(_ sources: Sources) -> Data {
        let cards = sources.cards.map { card in
            [card.number, card.cardholder, card.month.map(String.init) ?? "", card.year.map(String.init) ?? "", card.securityCode ?? ""]
        }
        let contacts = sources.contacts.map { [$0.label] + AutofillSaveCandidate.contact($0).values }
        let fields = [["cards", String(cards.count)]] + cards + [["contacts", String(contacts.count)]] + contacts
        // An array of string arrays encodes the same way every time; it cannot fail to encode.
        return Data(SHA256.hash(data: (try? JSONEncoder().encode(fields)) ?? Data()))
    }

    // MARK: Moving

    /// Writes the entries the vault of `manager` does not hold yet, in one commit under `epoch`, and reports where every old copy is.
    /// The old lists are not touched. Run again (after a quit or a crash), it writes nothing twice.
    func move(_ sources: Sources, into manager: CredentialManager, epoch: UInt64) async throws -> Report {
        guard !profile.isPrivate else { throw AutofillVaultError.privateBrowsing }
        guard storedState != .done else { throw Failure.changed }
        let snapshot = try await manager.snapshot()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let entries = Self.entries(for: sources, in: snapshot.accounts)
        if !entries.isEmpty {
            guard snapshot.accounts.count + entries.count <= CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }
            let previous = movedIDs(in: manager.vaultID)
            record(previous.union(entries.map(\.id)), in: manager.vaultID)
            do {
                _ = try await manager.commitAccounts(
                    entries.map { AccountWrite(accountID: $0.id, expected: .absent, replacement: $0) }, authorizedEpoch: epoch,
                    cause: CredentialChangeCause.autofillMigration
                )
            } catch {
                record(previous, in: manager.vaultID)
                throw error
            }
        }
        advance(to: .imported)
        return try await report(for: sources, in: manager, epoch: epoch)
    }

    func report(for sources: Sources, in manager: CredentialManager, epoch: UInt64) async throws -> Report {
        let snapshot = try await manager.snapshot()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        return Self.report(for: sources, in: snapshot.accounts, moved: movedIDs(in: manager.vaultID))
    }

    /// Before the confirmation: moves the entries the move wrote into this vault to Trash, in one commit, and puts the move back to
    /// `pending`. The old lists were never touched, so nothing is lost.
    func undo(in manager: CredentialManager, epoch: UInt64) async throws {
        guard !profile.isPrivate, storedState != .done else { throw Failure.notImported }
        let snapshot = try await manager.snapshot()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let removing = movedIDs(in: manager.vaultID).reduce(into: [UUID: AccountStamp]()) { result, id in
            result[id] = snapshot.stamps[id]
        }
        if !removing.isEmpty {
            _ = try await manager.commitAccounts([], removing: removing, authorizedEpoch: epoch, cause: CredentialChangeCause.autofillMigration)
        }
        record([], in: manager.vaultID)
        if (defaults.dictionary(forKey: Self.movedKey) ?? [:]).isEmpty {
            defaults.removeObject(forKey: Self.stateKey)
        }
    }

    // MARK: Erasing

    /// Erases the old lists after the person confirmed the dialog that stated `confirmed`. The lists and the vault are read again
    /// first; if the report differs in any way, or nothing was moved yet, nothing is erased. Afterwards the card list, the contact list
    /// and every card and contact row of the save index must be gone, or the move stays unfinished.
    func erase(using session: AutofillAuthenticationSession, confirmed: Report, in manager: CredentialManager, epoch: UInt64) async throws {
        guard !profile.isPrivate else { throw AutofillVaultError.privateBrowsing }
        guard storedState == .imported else { throw Failure.notImported }
        let current = try await report(for: try await sources(using: session), in: manager, epoch: epoch)
        guard current == confirmed else { throw Failure.changed }
        try await cards.erase()
        try await contacts.erase()
        try AutofillSaveIndex.eraseRows(of: [.card, .contact], profileID: profile.id, storage: indexStorage)
        let listsLeft = try await hasOldLists()
        let rowsLeft = try AutofillSaveIndex.hasRows(of: [.card, .contact], profileID: profile.id, storage: indexStorage)
        guard !listsLeft, !rowsLeft else { throw Failure.notErased }
        finish()
    }
}
