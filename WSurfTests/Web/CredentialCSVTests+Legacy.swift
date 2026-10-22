// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The passwords saved before Credential Manager go through the CSV stager as numbered rows, so every rule that protects a CSV
// import (exact matching, duplicates, conflicts, limits) protects them too. Synthetic entries only.
extension CredentialCSVTests {
    private func legacy(_ username: String, _ password: String, website: String = "https://example.test") throws -> SavedPassword {
        try SavedPassword(website: website, username: username, password: password)
    }

    private func vault(_ accounts: [CredentialAccount]) -> StoreSnapshot {
        StoreSnapshot(vaultID: UUID(), revision: 1, accounts: accounts, blockedPasswordOrigins: [], stamps: [:])
    }

    @Test func legacyRecordsStageWithEntryNumbers() throws {
        let saved = base.account(username: "grace", password: "same")
        let stored = base.account(username: "ada", password: "stored")
        let list = try [legacy("ada", "from-the-list"), legacy("grace", "same"), legacy("heidi", "fresh")]
        let staged = try CredentialCSVImport.stage(legacy: list, against: vault([stored, saved]))

        // Entry 1 differs from the saved login, entry 2 is already saved, entry 3 is new.
        #expect(staged.report.rowsRead == 3 && staged.report.alreadySaved == 1 && staged.report.issues.isEmpty)
        #expect(staged.preview.candidates.map(\.username).sorted() == ["ada", "heidi"])
        #expect(staged.preview.conflicts.count == 1)
        #expect(Set(staged.lines.values) == [1, 3])
        #expect(staged.needsChoice.isEmpty)
        // Passwords are only in the candidates: the report and the numbers carry no value of the list.
        #expect(!String(describing: staged.report).contains("from-the-list"))
    }

    @Test func legacyDuplicatesNeedAChoiceAndIdenticalOnesAreDropped() throws {
        let list = try [legacy("ada", "p1"), legacy("ada", "p1"), legacy("ada", "p2")]
        let staged = try CredentialCSVImport.stage(legacy: list, against: vault([]))

        #expect(staged.report.issues.map(\.line) == [2, 3])
        #expect(staged.report.issues.map(\.reason) == [.duplicateInFile(firstLine: 1), .conflictsWithEarlierRow(line: 1)])
        #expect(staged.report.omittedRows == 1)
        #expect(staged.preview.candidates.compactMap(\.password).sorted() == ["p1", "p2"])
        // Neither password is imported by default: the user picks, with entry numbers in the wording.
        #expect(staged.needsChoice.count == 2)
        #expect(staged.report.issues.allSatisfy { $0.reason.entryText != $0.reason.text })
    }

    @Test func legacyPasswordOverVaultLimitIsReportedNotImported() throws {
        // 2,049 two-byte characters: within the old list's character limit, over the vault's 4,096-byte one.
        let long = String(repeating: "\u{00E9}", count: 2_049)
        let list = try [legacy("ada", long), legacy("grace", "short")]
        let staged = try CredentialCSVImport.stage(legacy: list, against: vault([]))

        #expect(staged.report.issues == [.init(line: 1, reason: .passwordTooLong)])
        #expect(staged.report.omittedRows == 1)
        #expect(staged.preview.candidates.map(\.username) == ["grace"])
    }

    @Test func emptyLegacyListStagesNothing() throws {
        let staged = try CredentialCSVImport.stage(legacy: [], against: vault([base.account(username: "ada", password: "pw")]))
        #expect(staged.preview.candidates.isEmpty && staged.preview.conflicts.isEmpty)
        #expect(staged.report.rowsRead == 0 && staged.report.alreadySaved == 0 && staged.report.issues.isEmpty)
    }

    @Test func aLegacyListThatWouldOverfillTheVaultIsRefusedWholly() throws {
        let full = (0..<CredentialVaultLimits.accounts).map { base.account(username: "full-\($0)", password: "pw-\($0)") }
        #expect(throws: CredentialCSVError.tooManyAccounts) {
            try CredentialCSVImport.stage(legacy: [legacy("ada", "pw-1")], against: vault(full))
        }
        // A list that only matches saved logins needs no room.
        let same = try CredentialCSVImport.stage(legacy: [legacy("full-1", "pw-1")], against: vault(full))
        #expect(same.report.alreadySaved == 1 && same.preview.candidates.isEmpty)
    }
}
