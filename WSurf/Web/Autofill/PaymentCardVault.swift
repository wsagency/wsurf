// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import LocalAuthentication

/// The payment cards saved in this Mac's Keychain before cards moved into the vault. Read (Touch ID on every read) and erased only,
/// by `AutofillVaultMigration`, by filling one before the move is confirmed, and by erasing a profile: nothing writes this list any
/// more. The item's format is unchanged, so the list an earlier build saved is the one read here.
actor PaymentCardVault {
    let profileID: UUID
    private let storage: any AutofillSecureStorage

    init(profileID: UUID, storage: any AutofillSecureStorage = AutofillKeychainStorage(access: .userPresence, account: "cards")) {
        self.profileID = profileID
        self.storage = storage
    }

    func makeAuthenticationSession() throws -> AutofillAuthenticationSession {
        AutofillAuthenticationSession(service: try service(), reason: Self.reason)
    }

    func cards(using session: AutofillAuthenticationSession? = nil) throws -> [PaymentCard] {
        let service = try service()
        let context: LAContext
        if let session {
            context = try session.context(for: service)
        } else {
            context = LAContext()
            context.localizedReason = Self.reason
        }
        guard let data = try storage.read(service: service, context: context) else { return [] }
        guard data.count <= 4_000_000 else { throw AutofillVaultError.invalidData }
        let cards = try JSONDecoder().decode([PaymentCard].self, from: data)
        guard cards.count <= 500 else { throw AutofillVaultError.invalidData }
        return cards
    }

    /// Whether the list exists, answered without reading it or prompting. Private browsing never had one.
    func hasStoredCards() throws -> Bool {
        guard profileID != Profile.privateID else { return false }
        return try storage.exists(service: service())
    }

    func erase() throws {
        try storage.erase(service: service())
    }

    private static let reason = String(localized: "Access your saved payment cards in WSurf.")

    /// The list's Keychain service, which tests and stage runs keep apart from the installed app's.
    func service() throws -> String {
        guard profileID != Profile.privateID else { throw PaymentCardError.privateBrowsing }
        var namespace = "io.wsagency.wsurf.payment-cards"
        if AppDatabase.isRunningTests {
            namespace += ".tests.\(ProcessInfo.processInfo.processIdentifier)"
        }
        #if DEBUG
        if StageMode.isActive {
            namespace += ".stage"
        }
        #endif
        return "\(namespace).\(profileID.uuidString)"
    }
}
