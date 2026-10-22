// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Copying one part of an earlier version into the editor's draft: only the draft changes.

struct CredentialDraftHistoryTests {
    private static let site = "https://example.test"

    /// The credential as stored now.
    private func current() -> CredentialAccount {
        var account = VaultFixtures.account(username: "ada", password: "pw-new", origin: Self.site)
        account.origins = [Self.site, "https://other.example"]
        account.loginURLs = [URL(string: Self.site + "/login")!, URL(string: "https://other.example/login")!]
        account.notes = [CredentialNote(text: "notes-new", field: nil)]
        return account
    }

    /// An earlier version of it.
    private func version() -> CredentialAccount {
        var old = VaultFixtures.account(username: "ada-old", password: "pw-old", origin: Self.site)
        old.displayName = "Old name"
        old.origins = [Self.site, "https://third.example"]
        old.totp = VaultFixtures.totp()
        old.notes = [CredentialNote(text: "one", field: nil), CredentialNote(text: "two", field: nil)]
        return old
    }

    @Test func copyingTheNameAndTheLoginChangesOnlyThoseDraftFields() throws {
        var draft = CredentialDraft(editing: current(), revision: 1)
        draft.take(.name, from: version())
        draft.take(.login, from: version())
        #expect(draft.displayName == "Old name" && draft.username == "ada-old" && draft.password == "pw-old")
        #expect(draft.websites == CredentialDraft(editing: current(), revision: 1).websites)
        let built = try draft.account()
        #expect(built.password == "pw-old" && built.notes == current().notes)
    }

    @Test func copyingAWebsiteAddsOneLineOnce() {
        var draft = CredentialDraft(editing: current(), revision: 1)
        let before = draft.websites
        let address = URL(string: "https://third.example/login")!
        draft.take(.website(address), from: version())
        draft.take(.website(address), from: version())
        #expect(draft.websites == before + "\n" + address.absoluteString)
        draft.take(.origin("https://third.example"), from: version())
        draft.take(.origin("https://third.example"), from: version())
        #expect(draft.extraOrigins == "https://third.example")
    }

    @Test func copyingTheWebsitesReplacesBothLists() throws {
        var draft = CredentialDraft(editing: current(), revision: 1)
        draft.take(.websites, from: version())
        #expect(draft.websites == Self.site + "/login")
        #expect(draft.extraOrigins == "https://third.example")
        let built = try draft.account()
        #expect(built.origins == [Self.site, "https://third.example"] && built.loginURLs == [URL(string: Self.site + "/login")!])
    }

    @Test func copyingACodeNeedsTheVersionToHaveOne() {
        var draft = CredentialDraft(editing: current(), revision: 1)
        draft.take(.code, from: current())
        #expect(draft.totp == nil)
        draft.take(.code, from: version())
        #expect(draft.totp == VaultFixtures.totp())
    }

    @Test func copyingNotesReplacesThemOrAddsOneUpToTheLimit() {
        var draft = CredentialDraft(editing: current(), revision: 1)
        draft.take(.note(1), from: version())
        #expect(draft.notes.map(\.text) == ["notes-new", "two"])
        draft.take(.note(9), from: version())
        #expect(draft.notes.count == 2)
        draft.take(.notes, from: version())
        #expect(draft.notes.map(\.text) == ["one", "two"])
        draft.take(.notes, from: current().withoutNotes())
        #expect(draft.notes.isEmpty)

        var full = current()
        full.notes = (0..<CredentialAccount.noteLimit).map { CredentialNote(text: "n\($0)", field: nil) }
        var limited = CredentialDraft(editing: full, revision: 1)
        limited.take(.note(0), from: version())
        #expect(limited.notes.count == CredentialAccount.noteLimit)
    }
}

private extension CredentialAccount {
    func withoutNotes() -> CredentialAccount {
        var copy = self
        copy.notes = nil
        return copy
    }
}
