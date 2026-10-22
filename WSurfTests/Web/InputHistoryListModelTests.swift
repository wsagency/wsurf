// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Security
import Testing

@testable import WSurf

/// The list on top of the decrypted entries. Values are synthetic, the clipboard is a private pasteboard, and the clock is the
/// test's. Nothing here reaches the real Keychain.
@MainActor
struct InputHistoryListModelTests {
    @MainActor
    final class Rig {
        let harness: InputHistoryHarness
        let profile: Profile
        let settings: BrowserSettings
        let pasteboard: NSPasteboard
        let clock: TestClock
        let model: InputHistoryListModel
        private let defaultsName: String

        init() {
            let harness = InputHistoryHarness()
            let profile = harness.makeProfile()
            let name = "InputHistoryListModelTests.\(UUID().uuidString)"
            // A suite of its own: the tests never touch the app's settings.
            let settings = BrowserSettings(defaults: UserDefaults(suiteName: AppDatabase.defaultsSuite(name)) ?? UserDefaults())
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
            let clock = TestClock()
            self.harness = harness
            self.profile = profile
            self.settings = settings
            self.pasteboard = pasteboard
            self.clock = clock
            defaultsName = AppDatabase.defaultsSuite(name)
            model = InputHistoryListModel(profile: profile, settings: settings, history: harness.history, pasteboard: pasteboard, clock: clock)
        }

        func tearDown() {
            model.listDidClose()
            pasteboard.releaseGlobally()
            UserDefaults().removePersistentDomain(forName: defaultsName)
            harness.cleanUp()
        }
    }

    private static func entry(
        _ value: String,
        kind: InputHistoryPayload.Kind = .text,
        at seconds: TimeInterval,
        url: String = "https://example.test/login",
        label: String = "Message",
        title: String = "Example",
        username: String? = nil
    ) -> InputHistoryEntry {
        let created = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        return InputHistoryEntry(
            id: "\(Int64(created.timeIntervalSince1970 * 1000))-\(UUID().uuidString)",
            createdAt: created,
            expiresAt: nil,
            payload: InputHistoryPayload(url: url, frameOrigin: nil, title: title, label: label, kind: kind, value: value, username: username)
        )
    }

    // MARK: - Order and search

    @Test func newestEntryIsFirst() {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.model.show([Self.entry("older", at: 1), Self.entry("newest", at: 3), Self.entry("middle", at: 2)])
        #expect(rig.model.visible.map(\.value) == ["newest", "middle", "older"])
    }

    @Test func searchMatchesWhereAndWhatButNeverAPassword() {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.model.show([
            Self.entry(
                "dummy-secret-123", kind: .password, at: 1, url: "https://bank.example.test/signin", label: "Password", title: "Bank",
                username: "ada@example.test"
            ),
            Self.entry("Grüße aus Zürich", kind: .multiline, at: 2, url: "https://mail.example.test/compose", label: "Message", title: "Compose"),
        ])
        func found(_ query: String) -> [String] {
            rig.model.query = query
            return rig.model.visible.map(\.value)
        }

        #expect(found("dummy-secret").isEmpty, "a password value is never searchable")
        #expect(found("secret-123").isEmpty)
        #expect(found("bank.example") == ["dummy-secret-123"])
        #expect(found("/signin") == ["dummy-secret-123"])
        #expect(found("ADA@EXAMPLE") == ["dummy-secret-123"], "the username next to a password is plain text")
        #expect(found("compose") == ["Grüße aus Zürich"])
        #expect(found("zurich") == ["Grüße aus Zürich"], "case and diacritics do not matter")
        #expect(found("  ").count == 2)
    }

    @Test func theListDrawsAtMostFiveHundredRows() {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.model.show((0...InputHistoryListModel.visibleLimit).map { Self.entry("value \($0)", at: TimeInterval($0)) })
        #expect(rig.model.rows.count == InputHistoryListModel.visibleLimit + 1)
        #expect(rig.model.visible.count == InputHistoryListModel.visibleLimit)
        #expect(rig.model.visible.first?.value == "value \(InputHistoryListModel.visibleLimit)")
    }

    @Test func upAndDownMoveTheSelectionWithinTheVisibleRows() {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.model.show([Self.entry("a", at: 1), Self.entry("b", at: 2), Self.entry("c", at: 3)])
        let ids = rig.model.visible.map(\.id)

        rig.model.moveSelection(by: 1)
        #expect(rig.model.selection == ids[0])
        rig.model.moveSelection(by: 1)
        #expect(rig.model.selection == ids[1])
        rig.model.moveSelection(by: 5)
        #expect(rig.model.selection == ids[2])
        rig.model.moveSelection(by: -1)
        #expect(rig.model.selection == ids[1])

        // A row the search hides is no longer selected. Up then starts from the end of what is shown.
        rig.model.query = "c"
        #expect(rig.model.selection == nil)
        rig.model.moveSelection(by: -1)
        #expect(rig.model.selection == ids[0])
    }

    // MARK: - Masking

    @Test func passwordsStayMaskedUntilRevealedOneRowAtATime() {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.model.show([
            Self.entry("dummy-secret-1", kind: .password, at: 1),
            Self.entry("dummy-secret-2", kind: .password, at: 2),
            Self.entry("plain text", at: 3),
        ])
        let (plain, second, first) = (rig.model.visible[0], rig.model.visible[1], rig.model.visible[2])

        #expect(rig.model.text(for: plain) == "plain text")
        #expect(rig.model.text(for: first) == InputHistoryListModel.mask)
        #expect(rig.model.text(for: second) == InputHistoryListModel.mask)
        // VoiceOver hears that a password is there, never the value and never a row of bullets.
        #expect(rig.model.spokenValue(for: first) == String(localized: "Password, hidden"))
        #expect(rig.model.spokenValue(for: plain) == "plain text")

        rig.model.toggleReveal(first)
        #expect(rig.model.text(for: first) == "dummy-secret-1")
        #expect(rig.model.spokenValue(for: first) == "dummy-secret-1")
        rig.model.toggleReveal(second)
        #expect(rig.model.text(for: first) == InputHistoryListModel.mask)
        #expect(rig.model.text(for: second) == "dummy-secret-2")
        rig.model.toggleReveal(second)
        #expect(rig.model.text(for: second) == InputHistoryListModel.mask)
    }

    // MARK: - Copying

    @Test func copyMarksTheClipboardConcealedAndClearsItAfterAMinute() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.model.show([Self.entry("dummy-secret-123", kind: .password, at: 1)])
        let row = try #require(rig.model.visible.first)

        rig.model.copy(row)
        #expect(rig.pasteboard.string(forType: .string) == "dummy-secret-123")
        #expect(rig.pasteboard.types?.contains(.concealed) == true)
        #expect(rig.model.notice != nil)
        #expect(await waitUntil { rig.clock.pendingCount == 1 })

        rig.clock.advance(by: InputHistoryListModel.clipboardLifetime - .seconds(1))
        #expect(rig.pasteboard.string(forType: .string) == "dummy-secret-123")
        rig.clock.advance(by: .seconds(1))
        await rig.model.clipboardClearing?.value
        #expect(rig.pasteboard.string(forType: .string) == nil)
    }

    @Test func copyLeavesWhateverWasCopiedLaterAlone() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.model.show([Self.entry("dummy-secret-123", kind: .password, at: 1)])
        let row = try #require(rig.model.visible.first)

        rig.model.copy(row)
        #expect(await waitUntil { rig.clock.pendingCount == 1 })
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("copied later", forType: .string)
        rig.clock.advance(by: InputHistoryListModel.clipboardLifetime)
        await rig.model.clipboardClearing?.value
        #expect(rig.pasteboard.string(forType: .string) == "copied later")
    }

    // MARK: - Locking

    @Test func lockingDropsTheRowsTheRevealAndTheSearch() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try await rig.harness.seed(rig.profile, ["dummy-one", "dummy-two"])
        rig.model.listDidOpen()
        #expect(rig.model.isLocked)
        #expect(rig.model.rows.isEmpty, "nothing is shown before the person unlocks")

        await rig.model.unlock()
        #expect(rig.model.error == nil)
        #expect(rig.model.visible.map(\.value) == ["dummy-two", "dummy-one"])
        let row = try #require(rig.model.visible.first)
        rig.model.toggleReveal(row)
        rig.model.query = "example"

        // A vault lock event, a sleep or the relock timer: the list empties on its next sync.
        rig.harness.history.lock(profileID: rig.profile.id)
        #expect(rig.model.isLocked)
        rig.model.sync()
        #expect(rig.model.rows.isEmpty && rig.model.visible.isEmpty)
        #expect(!rig.model.isRevealed(row))
        #expect(rig.model.query.isEmpty)
    }

    @Test func lockButtonLocksAtOnce() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try await rig.harness.seed(rig.profile, ["dummy-one"])
        await rig.model.unlock()
        #expect(!rig.model.isLocked)
        rig.model.lock()
        #expect(rig.model.isLocked)
        #expect(rig.model.rows.isEmpty)
    }

    @Test func aCancelledPromptIsNotAnError() {
        #expect(InputHistoryListModel.message(for: AutofillVaultError.keychain(errSecUserCanceled)) == nil)
        #expect(InputHistoryListModel.message(for: AutofillVaultError.keychain(errSecAuthFailed)) == nil)
        #expect(InputHistoryListModel.message(for: InputHistoryError.keysUnusable) != nil)
        #expect(InputHistoryListModel.message(for: InputHistoryError.unavailable) != nil)
    }

    @Test func aPrivateProfileNeverOpens() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let model = InputHistoryListModel(profile: .privateBrowsing(), settings: rig.settings, history: rig.harness.history)
        await model.unlock()
        #expect(model.isLocked)
        #expect(model.error != nil)
        #expect(rig.harness.history.store(for: .privateBrowsing()) == nil)
    }

    // MARK: - Changing

    @Test func deleteRemovesTheEntryAndSelectsTheNextRow() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try await rig.harness.seed(rig.profile, ["dummy-one", "dummy-two", "dummy-three"])
        await rig.model.unlock()
        let rows = rig.model.visible
        #expect(rows.map(\.value) == ["dummy-three", "dummy-two", "dummy-one"])

        rig.model.selection = rows[1].id
        rig.model.delete(rows[1])
        #expect(rig.model.visible.map(\.value) == ["dummy-three", "dummy-one"])
        #expect(rig.model.selection == rows[2].id)

        await rig.harness.history.drain(profileID: rig.profile.id)
        rig.harness.history.lock(profileID: rig.profile.id)
        await rig.model.unlock()
        #expect(rig.model.visible.map(\.value) == ["dummy-three", "dummy-one"], "the file is gone, not only the row")
    }

    @Test func dontRecordThisSiteAddsTheHostOnce() {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.model.show([Self.entry("x", at: 1, url: "https://example.test/a"), Self.entry("y", at: 2, url: "https://www.example.test/b")])
        let (subdomain, site) = (rig.model.visible[0], rig.model.visible[1])

        rig.model.excludeSite(of: site)
        rig.model.excludeSite(of: site)
        #expect(rig.settings.inputHistoryExcludedSites == ["example.test"])
        // The subdomain is already covered.
        rig.model.excludeSite(of: subdomain)
        #expect(rig.settings.inputHistoryExcludedSites == ["example.test"])
        #expect(rig.model.notice != nil)
    }

    @Test func turningOffDeletesEverythingAndTheKeys() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.settings.recordsInputHistory = true
        try await rig.harness.seed(rig.profile, ["dummy-one", "dummy-two"])
        #expect(try rig.harness.hasKeys(rig.profile))

        rig.model.turnOffAndDelete()
        #expect(!rig.settings.recordsInputHistory)
        await rig.harness.history.drain(profileID: rig.profile.id)
        #expect(try !rig.harness.hasKeys(rig.profile), "both keys go, so a copy of the old files can never be opened")
        await rig.model.unlock()
        #expect(rig.model.rows.isEmpty)
    }

    // MARK: - Performance

    /// The store's largest case: 500 entries of 10,000 characters. The rows are built once and a search only compares folded text.
    /// The bound is a guard against a gross regression (such as folding on every keystroke), not a tight budget.
    @Test func fiveHundredLongEntriesBuildAndSearchQuickly() {
        let rig = Rig()
        defer { rig.tearDown() }
        let text = String(String(repeating: "Lorem ipsum dolor sit amet ", count: 400).prefix(InputHistoryLimits.value))
        let entries = (0..<InputHistoryLimits.entries).map {
            Self.entry(text, kind: .multiline, at: TimeInterval($0), url: "https://site\($0).example.test/form")
        }

        let elapsed = ContinuousClock().measure {
            rig.model.show(entries)
            for query in ["site42.", "dolor", "nothing-matches-this", ""] {
                rig.model.query = query
            }
        }
        #expect(rig.model.visible.count == InputHistoryLimits.entries)
        #expect(elapsed < .seconds(3), "building and searching took \(elapsed)")
    }
}
