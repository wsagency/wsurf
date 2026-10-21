// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// Identities and typed custom fields: the Add menu's templates, the type menu of a custom field, Touch ID for a hidden one, and an
// identity saved, edited, read back from History and taken back with Undo. Touch ID is a counting stub, the vault uses test-only
// in-memory unlock keys and a private pasteboard, and every value is synthetic (the OIB is all zeros).

@MainActor
struct CredentialIdentityTests {
    private static let oib = "00000000001"

    @MainActor
    private final class Verifier {
        private(set) var calls = 0

        func verify(_: String) async throws {
            calls += 1
        }
    }

    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let verifier: Verifier
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Identities", symbol: "person", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            let verifier = Verifier()
            self.verifier = verifier
            model = CredentialSettingsModel(
                profile: profile, pasteboard: pasteboard, manager: vault.manager, verifyUser: { try await verifier.verify($0) }
            )
            await model.load()
        }

        @MainActor func stored(_ id: UUID) async throws -> CredentialAccount {
            try #require(try await vault.manager.snapshot().accounts.first { $0.id == id })
        }

        @MainActor func cleanup() async {
            pasteboard.releaseGlobally()
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    private func newDraft(_ template: CredentialTemplate) -> CredentialDraft {
        var draft = CredentialDraft(editing: nil, revision: 0)
        template.apply(to: &draft)
        return draft
    }

    private func types(_ item: SecureItem?) -> [CredentialEditableFieldType?] {
        item?.fields.map { $0.field?.fieldType } ?? []
    }

    private func custom(_ account: CredentialAccount) -> SecureItem? {
        account.secureItems?.first { $0.kind == .customFields }
    }

    // MARK: - Templates

    @Test func theIdentityTemplateHoldsANameADocumentAndTypedFields() {
        let draft = newDraft(.identity)
        #expect(draft.secureItems.map(\.kind) == [.personName, .identityDocument, .customFields])
        let fields = draft.secureItems[2].fields
        #expect(fields.map { $0.field?.label } == [String(localized: "OIB"), String(localized: "Date of baptism"), String(localized: "Medical")])
        #expect(types(draft.secureItems[2]) == [.concealedString, .date, .string])
        #expect(fields.allSatisfy { $0.value.isEmpty && $0.name.isEmpty })
        #expect(draft.isIdentity, "it opens with only a name and its items")
        #expect(!draft.hasUnsavedChanges, "an untouched template is nothing to lose")
    }

    @Test func everyTemplateStartsUntouchedAndOnlyTheIdentityHidesTheSignIn() {
        for template in CredentialTemplate.allCases {
            let draft = newDraft(template)
            #expect(!draft.hasUnsavedChanges, "\(template)")
            #expect(draft.isIdentity == (template == .identity), "\(template)")
        }
        #expect(newDraft(.card).secureItems.map(\.kind) == [.creditCard])
        #expect(newDraft(.address).secureItems.map(\.kind) == [.address])
        #expect(newDraft(.note).notes.count == 1)
        #expect(newDraft(.login).secureItems.isEmpty && newDraft(.login).notes.isEmpty)
    }

    @Test func aDraftWithASignInIsNoIdentity() {
        var draft = newDraft(.identity)
        draft.username = "ada@example.test"
        #expect(!draft.isIdentity)
        draft = newDraft(.identity)
        draft.websites = "https://example.test"
        #expect(!draft.isIdentity)
        draft = newDraft(.identity)
        draft.secureItems.removeAll { $0.kind.isIdentity }
        #expect(!draft.isIdentity, "custom fields alone are not an identity")
    }

    // MARK: - The type menu

    @Test func aCustomFieldTypeChangesOnlyItsType() {
        var draft = newDraft(.identity)
        let id = Data([0xF0, 0x01])
        draft.secureItems[2].fields[0].field?.id = id
        draft.secureItems[2].fields[0].value = Self.oib
        for type in CredentialEditableFieldType.customFieldChoices {
            draft.setCustomFieldType(type, item: 2, field: 0)
            let field = draft.secureItems[2].fields[0]
            #expect(field.field == CredentialEditableFieldMetadata(id: id, label: String(localized: "OIB"), fieldType: type))
            #expect(field.value == Self.oib)
        }

        // A member of any other kind keeps the Credential Exchange's type, and a position that is not there changes nothing.
        let before = draft.secureItems
        draft.setCustomFieldType(.concealedString, item: 0, field: 0)
        draft.setCustomFieldType(.date, item: 2, field: 9)
        draft.setCustomFieldType(.date, item: 9, field: 0)
        #expect(draft.secureItems == before)

        // A custom field without a description gets one.
        draft.secureItems[2].fields[1].field = nil
        draft.setCustomFieldType(.number, item: 2, field: 1)
        #expect(draft.secureItems[2].fields[1].field == CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .number))
    }

    @Test func theMenuOffersTextHiddenDateNumberAndEmailWithLabels() {
        #expect(CredentialEditableFieldType.customFieldChoices == [.string, .concealedString, .date, .number, .email])
        let all: [CredentialEditableFieldType] = [
            .string, .concealedString, .email, .number, .boolean, .date, .yearMonth, .wifiNetworkSecurityType, .countryCode, .subdivisionCode,
        ]
        #expect(Set(all.map(\.label)).count == all.count, "every type has its own name")
    }

    // MARK: - Touch ID for a hidden custom field

    @Test func aHiddenCustomFieldMakesItsItemSensitive() {
        let hidden = SecureItemFixtures.custom(values: [("OIB", Self.oib, true)])
        let plain = SecureItemFixtures.custom(values: [("Medical", "synthetic note", false)])
        #expect(hidden.isSensitive && !plain.isSensitive)
        #expect(SecureItemFixtures.card().isSensitive)
        #expect(!SecureItemFixtures.wifi().isSensitive, "a Wi-Fi password still opens with the vault's unlock alone")

        #expect(CredentialSummary(SecureItemFixtures.account([hidden])).hasSensitiveItems)
        #expect(!CredentialSummary(SecureItemFixtures.account([plain])).hasSensitiveItems)

        let parts = CredentialCopyParts(SecureItemFixtures.account([plain, hidden]), allowsCode: false)
        #expect(!parts.isSensitive(.secureField(item: 0, field: 0)))
        #expect(parts.isSensitive(.secureField(item: 1, field: 0)))
    }

    // MARK: - Save, History and Undo

    @Test func anIdentityKeepsItsTypesThroughSaveHistoryAndUndo() async throws {
        try await withFixture { f in
            try await f.model.beginEditing(accountID: nil, template: .identity)
            #expect(f.verifier.calls == 0, "a new identity asks for nothing")
            f.model.draft?.displayName = "Synthetic Child"
            let given = try #require(f.model.draft?.secureItems[0].fields.firstIndex { $0.name == "given" })
            f.model.draft?.secureItems[0].fields[given].value = "Ada"
            f.model.draft?.secureItems[2].fields[0].value = Self.oib
            f.model.draft?.secureItems[2].fields[1].value = "2020-05-17"
            f.model.draft?.secureItems[2].fields[2].value = "Synthetic allergy note"
            _ = try await f.model.commitDraft()

            // Saved: the empty document and the empty name members are dropped, the custom fields keep their types.
            let id = try #require(f.model.summaries.first { $0.displayName == "Synthetic Child" }).id
            let saved = try await f.stored(id)
            #expect(saved.secureItems?.map(\.kind) == [.personName, .customFields])
            #expect(types(custom(saved)) == [.concealedString, .date, .string])
            #expect(custom(saved)?.fields.map(\.value) == [Self.oib, "2020-05-17", "Synthetic allergy note"])
            #expect(saved.username.isEmpty && saved.password == nil && saved.origins.isEmpty)
            let summary = try #require(f.model.summaries.first { $0.id == id })
            #expect(summary.hasSensitiveItems && summary.hiddenItemFields.map(\.label) == ["OIB"])

            // Opening it asks for Touch ID because of the hidden OIB; the type menu then shows the OIB and moves the date.
            try await f.model.beginEditing(accountID: id)
            #expect(f.verifier.calls == 1)
            #expect(f.model.draft?.isIdentity == true)
            f.model.draft?.setCustomFieldType(.string, item: 1, field: 0)
            f.model.draft?.secureItems[1].fields[1].value = "2020-05-18"
            _ = try await f.model.commitDraft()
            let edited = try await f.stored(id)
            #expect(types(custom(edited)) == [.string, .date, .string])
            let shownNow = try #require(f.model.summaries.first { $0.id == id })
            #expect(!shownNow.hasSensitiveItems, "a shown OIB no longer asks")

            // History keeps the earlier version with the OIB still hidden and the first date.
            try await f.model.openHistory(accountID: id)
            let earlier = try #require(f.model.history?.versions.first { !$0.isCurrent })
            #expect(types(custom(earlier.account)) == [.concealedString, .date, .string])
            #expect(custom(earlier.account)?.fields[1].value == "2020-05-17")
            f.model.cancelEditing()

            // Undo puts the identity back as it was saved first.
            await f.model.undo()
            #expect(f.model.error == nil)
            let undone = try await f.stored(id)
            #expect(undone.secureItems == saved.secureItems)
            #expect(types(custom(undone)) == [.concealedString, .date, .string])
        }
    }
}
