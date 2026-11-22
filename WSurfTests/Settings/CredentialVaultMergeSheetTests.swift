// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfVault

@testable import WSurf

@MainActor
struct CredentialVaultMergeSheetTests {
    @Test func theReviewCountsEveryChoiceAndRequiresEachConflictToBeResolved() throws {
        let added = VaultFixtures.account(username: "new")
        let identical = VaultFixtures.account(username: "same")
        let changed = VaultFixtures.account(username: "changed", password: "source")
        let rows = try CredentialVaultMergePlan.rows(
            source: [added, identical, changed],
            destination: [VaultFixtures.account(username: "same"), VaultFixtures.account(username: "changed", password: "destination")]
        )
        var selection = VaultMergeSelection(rows: rows)
        #expect(selection.choices[added.id] == .copy)
        #expect(selection.choices[identical.id] == .skip)
        #expect(selection.choices[changed.id] == nil)
        #expect(!selection.isComplete)

        selection.choices[changed.id] = .replace
        #expect(selection.isComplete)
        #expect(selection.count(.copy) == 1 && selection.count(.replace) == 1 && selection.count(.skip) == 1)
        selection.choices[added.id] = .skip
        selection.choices[changed.id] = .skip
        #expect(selection.isComplete && selection.count(.skip) == rows.count)
        selection.choices[identical.id] = .copy
        #expect(!selection.isComplete)
    }

    @Test func twoRowsCannotReplaceOneSharedEntry() throws {
        let first = VaultFixtures.account(password: "first")
        let second = VaultFixtures.account(password: "second")
        let target = VaultFixtures.account(password: "saved")
        let rows = try CredentialVaultMergePlan.rows(source: [first, second], destination: [target])
        var selection = VaultMergeSelection(rows: rows)
        #expect(Set(rows.map { selection.title(of: $0) }).count == 2)
        selection.choices = [first.id: .replace, second.id: .replace]
        #expect(!selection.isComplete)
        selection.choices[second.id] = .skip
        #expect(selection.isComplete)
    }

    @Test func evenASkipOnlyConflictNeedsAChoice() throws {
        let local = try VaultFixtures.account(passkeys: [VaultFixtures.passkey()])
        var shared = try VaultFixtures.account(passkeys: [VaultFixtures.passkey()])
        shared.passkeys[0].credentialID = local.passkeys[0].credentialID
        let rows = try CredentialVaultMergePlan.rows(source: [local], destination: [shared])
        #expect(rows.first?.choices == [.skip])
        var selection = VaultMergeSelection(rows: rows)
        #expect(!selection.isComplete)
        selection.choices[local.id] = .skip
        #expect(selection.isComplete)
    }
}
