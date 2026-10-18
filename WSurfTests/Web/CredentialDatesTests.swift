// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The dates a credential shows come only from what the vault recorded (spec §12.1): pure values, no vault or manager.
struct CredentialDatesTests {
    private let first = VaultFixtures.reference(800_000_000)
    private let later = VaultFixtures.reference(800_100_000)

    private func list(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    @Test func createdIsShownOnlyWhenWSurfCreatedTheCredential() {
        let account = VaultFixtures.account().stampingCreation(at: first)
        let dates = CredentialDates(account)
        #expect(dates.added?.origin == .created)
        #expect(dates.added?.date == first)
        #expect(dates.updated == nil)
        #expect(dates.caption(style: .list) == String(localized: "Created \(list(first))"))
        #expect(CredentialSummary(account).dates == dates)

        var moved = VaultFixtures.account()
        moved.migratedAt = first
        moved.modifiedAt = first
        #expect(CredentialDates(moved).added?.origin != .created)
    }

    @Test func aMovedOrImportedCredentialSaysSoInsteadOfCreated() {
        var moved = VaultFixtures.account()
        moved.migratedAt = first
        moved.passwordEvents = CredentialEvents(lastImportedAt: later)
        let movedDates = CredentialDates(moved)
        #expect(movedDates.added?.origin == .movedToWSurf)
        #expect(movedDates.added?.date == first)
        #expect(movedDates.caption(style: .list) == String(localized: "Moved to WSurf \(list(first))"))

        var imported = VaultFixtures.account()
        imported.passwordEvents = CredentialEvents(lastImportedAt: first)
        imported.totpEvents = CredentialEvents(lastImportedAt: later)
        let importedDates = CredentialDates(imported)
        #expect(importedDates.added?.origin == .imported)
        #expect(importedDates.added?.date == first)
        #expect(importedDates.caption(style: .list) == String(localized: "Imported \(list(first))"))

        var codeOnly = VaultFixtures.account()
        codeOnly.totpEvents = CredentialEvents(lastImportedAt: later)
        #expect(CredentialDates(codeOnly).added?.date == later)
    }

    @Test func updatedIsOmittedWhenItEqualsTheAddedDate() {
        var account = VaultFixtures.account().stampingCreation(at: first)
        #expect(CredentialDates(account).updated == nil)

        account.modifiedAt = later
        let dates = CredentialDates(account)
        #expect(dates.updated == later)
        let created = String(localized: "Created \(list(first))")
        let updated = String(localized: "Updated \(list(later))")
        #expect(dates.caption(style: .list) == "\(created) · \(updated)")
        #expect(dates.caption(style: .editor).contains(later.formatted(date: .abbreviated, time: .shortened)))
    }

    @Test func datesNeverMakeTwoOtherwiseEqualSummariesDifferent() {
        let account = VaultFixtures.account().stampingCreation(at: first)
        var edited = account
        edited.modifiedAt = later
        #expect(CredentialSummary(account).dates != CredentialSummary(edited).dates)
        #expect(CredentialSummary(account) == CredentialSummary(edited))

        edited.displayName = "Renamed"
        #expect(CredentialSummary(account) != CredentialSummary(edited))
    }

    @Test func noDateIsInventedForAnUnknownOne() {
        var account = VaultFixtures.account()
        let none = CredentialDates(account)
        #expect(none.added == nil && none.updated == nil)
        #expect(none.caption(style: .list).isEmpty)

        account.passwordEvents = CredentialEvents()
        #expect(CredentialDates(account).added == nil)

        // A change date alone is not an added date: the credential is not claimed to have been created then.
        account.modifiedAt = later
        let changedOnly = CredentialDates(account)
        #expect(changedOnly.added == nil)
        #expect(changedOnly.updated == later)
        #expect(changedOnly.caption(style: .list) == String(localized: "Updated \(list(later))"))
    }
}
