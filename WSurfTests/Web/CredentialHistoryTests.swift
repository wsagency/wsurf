// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The whole-credential versions the History panel rebuilds from a credential and its revision values. Pure: no store, no clock.

struct CredentialHistoryTests {
    private static let site = "https://example.test"
    private static let other = "https://other.example"

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
    }

    private func revision(_ subject: RecordSubject, _ typed: some Encodable, at seconds: TimeInterval, cause: String? = nil) throws -> RevisionValue {
        let item = RevisionItem(id: UUID(), subject: subject, version: 1, recordedAt: time(seconds), cause: cause)
        return RevisionValue(item: item, value: try CredentialContent.canonicalJSON(typed))
    }

    private func login(_ password: String) -> PasswordValue {
        PasswordValue(username: "ada", password: password, basicAuthenticationMetadata: nil)
    }

    private func sites(_ origins: [String]) -> MetadataProjection {
        MetadataProjection(
            displayName: nil, origins: origins, loginURLs: origins.map { URL(string: $0 + "/login")! }, exchange: nil,
            exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func note(_ text: String) -> [CredentialNote] {
        [CredentialNote(text: text, field: nil)]
    }

    /// The credential after a password change, then a website change, then a notes change.
    private func current() -> CredentialAccount {
        var account = VaultFixtures.account(username: "ada", password: "pw-new", origin: Self.site)
        account.origins = [Self.site, Self.other]
        account.loginURLs = [URL(string: Self.site + "/login")!, URL(string: Self.other + "/login")!]
        account.notes = note("notes-new")
        return account
    }

    private func timeline() throws -> [RevisionValue] {
        [
            try revision(.note, note("notes-old"), at: 3),
            try revision(.metadata, sites([Self.site]), at: 2),
            try revision(.password, login("pw-old"), at: 1),
        ]
    }

    @Test func versionsRebuildTheWholeCredentialNewestFirst() throws {
        let now = current()
        let versions = try CredentialHistory.versions(current: now, revisions: try timeline())
        #expect(versions.count == 4)
        #expect(versions[0].account == now && versions[0].isCurrent)

        // Replaced by the notes change: only the notes are old.
        #expect(versions[1].account.notes == note("notes-old"))
        #expect(versions[1].account.password == "pw-new")
        #expect(versions[1].account.origins == [Self.site, Self.other])
        // Replaced by the website change: the websites are old too.
        #expect(versions[2].account.origins == [Self.site])
        #expect(versions[2].account.password == "pw-new")
        #expect(versions[2].account.notes == note("notes-old"))
        // Replaced by the password change: every part is old.
        #expect(versions[3].account.password == "pw-old")
        #expect(versions[3].account.origins == [Self.site])
        #expect(versions[3].account.notes == note("notes-old"))
        #expect(versions.map(\.changed) == [[], [.note], [.metadata], [.password]])
    }

    @Test func eachVersionIsDatedByWhenItWasReplaced() throws {
        let revisions = try timeline()
        let versions = try CredentialHistory.versions(current: current(), revisions: revisions)
        #expect(versions[0].replacedAt == nil)
        #expect(versions.dropFirst().map(\.replacedAt) == [time(3), time(2), time(1)])
        #expect(versions.dropFirst().map(\.id) == revisions.map(\.item.id))
    }

    @Test func partsReplacedByOneCommitAreOneVersion() throws {
        let revisions = [
            try revision(.password, login("pw-old"), at: 5, cause: "x"),
            try revision(.note, note("notes-old"), at: 5, cause: "x"),
            // Same time and part as the row above: another commit, not the same one.
            try revision(.password, login("pw-older"), at: 5, cause: "x"),
        ]
        let versions = try CredentialHistory.versions(current: current(), revisions: revisions)
        #expect(versions.count == 3)
        #expect(versions[1].changed == [.password, .note])
        #expect(versions[1].account.password == "pw-old" && versions[1].account.notes == note("notes-old"))
        #expect(versions[2].changed == [.password] && versions[2].account.password == "pw-older")
    }

    @Test func passkeysAreShownOnlyAsTheyAreNow() throws {
        var now = current()
        now.passkeys = [try VaultFixtures.passkey()]
        let versions = try CredentialHistory.versions(current: now, revisions: try timeline())
        #expect(versions.count == 4)
        #expect(versions.allSatisfy { $0.account.passkeys == now.passkeys })
    }

    @Test func importChangesAreLabelledAsImports() throws {
        let revisions = [
            try revision(.password, login("pw-old"), at: 2, cause: CredentialChangeCause.import),
            try revision(.metadata, sites([Self.site]), at: 1, cause: "rotated by hand"),
        ]
        let versions = try CredentialHistory.versions(current: current(), revisions: revisions)
        #expect(versions.map(\.cause) == [nil, "import", "rotated by hand"])
        #expect(CredentialChangeCause.text(for: versions[1].cause) == String(localized: "Changed by an import"))
        #expect(CredentialChangeCause.text(for: CredentialChangeCause.merge) == String(localized: "Changed by a merge"))
        // A writer's own words are shown as written; no cause says nothing.
        #expect(CredentialChangeCause.text(for: versions[2].cause) == "rotated by hand")
        #expect(CredentialChangeCause.text(for: nil) == nil && CredentialChangeCause.text(for: "") == nil)
    }

    @Test func aValueThatIsNotTheCanonicalJSONOfItsPartIsRefused() throws {
        // A whole account decodes leniently as a password value but is not one: the strict decode refuses it.
        let wrong = RevisionValue(
            item: RevisionItem(id: UUID(), subject: .password, version: 1, recordedAt: time(1), cause: nil),
            value: try CredentialContent.canonicalJSON(current())
        )
        #expect(throws: CredentialVaultError.invalidData) {
            _ = try CredentialHistory.versions(current: current(), revisions: [wrong])
        }
    }

    @Test func websiteLinesListLoginAddressesThenOtherOrigins() {
        var account = current()
        account.origins.append("https://third.example")
        let lines = CredentialHistory.websites(of: account)
        #expect(lines.map(\.text) == [Self.site + "/login", Self.other + "/login", "https://third.example"])
        #expect(lines.map(\.isOtherOrigin) == [false, false, true])
        #expect(lines.last?.field == .origin("https://third.example"))
        #expect(lines.first?.field == .website(URL(string: Self.site + "/login")!))
    }
}
