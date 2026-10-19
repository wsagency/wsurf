// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import XCTest

@testable import WSurf

// A vault of 3,000 synthetic credentials (every 10th has a passkey, every 5th a verification code, every 7th notes) behind the real
// Credential Manager page, the real export sheet and the real unlock path. Nothing here is real data. The bounds are far above what a
// healthy build takes and far below what the page took when it built every row at once, so a regression to eager rows fails them.
nonisolated final class CredentialListPerformanceTests: XCTestCase, @unchecked Sendable {
    private static let count = 3_000
    private static let iterations = 5

    // MARK: Fixtures

    private static func accounts() throws -> [CredentialAccount] {
        try (0..<count).map { index in
            let host = "site\(index).example.test"
            let passkeys = try index % 10 == 0
                ? [VaultFixtures.passkey(rpID: host, credentialID: Data(String(format: "cred-%027d", index).utf8))]
                : []
            var account = VaultFixtures.account(
                username: "user\(index)@example.test", password: "password-\(index)", origin: "https://\(host)", passkeys: passkeys
            )
            account.displayName = index % 2 == 0 ? "Site \(index)" : nil
            if index % 5 == 0 {
                account.totp = TOTPGenerator(
                    secret: Data("seed-\(index)".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: "user\(index)"
                )
            }
            if index % 7 == 0 {
                account.notes = [CredentialNote(text: "note \(index)", field: nil)]
            }
            return account
        }
    }

    /// An unlocked vault holding the accounts, closed again whether or not `body` throws.
    @MainActor
    private func withLargeVault(
        _ body: (_ profile: Profile, _ vault: FixtureVault) async throws -> Void
    ) async throws {
        let accounts = try Self.accounts()
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let vault = try XCTUnwrap(vaults.first)
            try await VaultManagerFixture.save(accounts, in: vault)
            try await body(profile, vault)
        }
    }

    @MainActor
    private func loadedModel(_ profile: Profile, _ vault: FixtureVault) async throws -> CredentialSettingsModel {
        let model = CredentialSettingsModel(profile: profile, manager: vault.manager)
        await model.load()
        XCTAssertEqual(model.summaries.count, Self.count)
        return model
    }

    // MARK: Hosting

    /// The page as Settings lays it out: the detail pane's scroll view and column, then the Credential Manager page.
    @MainActor
    private static func page(
        _ model: CredentialSettingsModel, list: CredentialListState = CredentialListState(),
        selection: CredentialSelection = CredentialSelection()
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                CredentialSettings(model: model, list: list, selection: selection)
            }
            .environment(\.settingsDescriptionLineLimit, 1)
            .frame(maxWidth: SettingsMetrics.detailWidth, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.pageInset)
            .padding(.top, 34)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    @MainActor
    private static func mount(_ view: some View) -> (host: NSView, window: NSWindow) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (host, window)
    }

    @MainActor
    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    @MainActor
    private static func seconds(_ work: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure(work)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: Tests

    /// The owner's hang: the unlocked page laid out 2,800 rows at once.
    @MainActor
    func testThePageLaysOutWellUnderASecond() async throws {
        try await withLargeVault { profile, vault in
            let model = try await loadedModel(profile, vault)
            let (host, window) = Self.mount(Self.page(model))
            let elapsed = Self.seconds { Self.settle(host) }
            window.close()
            print("[credential-list] page layout, \(Self.count) credentials: \(elapsed) s")
            XCTAssertLessThan(elapsed, 1.0)
        }
    }

    /// The same layout under XCTest's metrics, which `Tools/check-performance.sh` holds to a budget. Every pass gets its own loaded
    /// model: closing a page forgets what its model showed, as leaving the page does.
    @MainActor
    func testLayingOutThreeThousandCredentials() async throws {
        try await withLargeVault { profile, vault in
            var models: [CredentialSettingsModel] = []
            for _ in 0..<(Self.iterations + 3) {
                try await models.append(loadedModel(profile, vault))
            }
            let options = XCTMeasureOptions()
            options.iterationCount = Self.iterations
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                let (host, window) = Self.mount(Self.page(models.removeLast()))
                Self.settle(host)
                window.close()
            }
        }
    }

    /// One change (a password shown) must not rebuild the page: the cost follows the rows on screen, not the vault. The vault read
    /// behind the change is not part of the page's cost and is left out of the timing.
    @MainActor
    func testShowingOnePasswordDoesNotRebuildThePage() async throws {
        try await withLargeVault { profile, vault in
            let model = try await loadedModel(profile, vault)
            let (host, window) = Self.mount(Self.page(model))
            Self.settle(host)
            let target = try XCTUnwrap(model.summaries.first).id
            try await model.revealPassword(accountID: target)

            // The run loop gets its turn here, which is when SwiftUI applies the change.
            let clock = ContinuousClock()
            let started = clock.now
            try await Task.sleep(for: .milliseconds(20))
            Self.settle(host)
            let elapsed = clock.now - started
            window.close()
            print("[credential-list] page update after showing one password, \(Self.count) credentials: \(elapsed)")
            XCTAssertEqual(model.revealedPassword?.accountID, target)
            XCTAssertLessThan(elapsed, .milliseconds(250))
        }
    }

    /// Typing in the search field narrows a 3,000-credential list: the page finds the matches from the keys built with the summaries and
    /// lays out only the rows it shows. The search is applied by the page's own task, not by the test.
    @MainActor
    func testSearchingThreeThousandCredentialsUpdatesQuickly() async throws {
        try await withLargeVault { profile, vault in
            let model = try await loadedModel(profile, vault)
            let list = CredentialListState()
            let (host, window) = Self.mount(Self.page(model, list: list))
            Self.settle(host)
            let counted = await waitUntil { list.counts != nil }
            XCTAssertTrue(counted, "the page counts the kinds when it appears")

            let clock = ContinuousClock()
            let started = clock.now
            list.query = "site29"
            // site29, site290-site299 and site2900-site2999.
            let found = await waitUntil(tick: .milliseconds(5)) { list.rows(of: model.summaries).count == 111 }
            Self.settle(host)
            let elapsed = clock.now - started
            window.close()
            print("[credential-list] search update, \(Self.count) credentials, 111 matches: \(elapsed)")
            XCTAssertTrue(found)
            XCTAssertEqual(list.counts?[.all], Self.count)
            XCTAssertLessThan(elapsed, .milliseconds(250))
        }
    }

    /// Selecting every credential and moving the cursor along the list changes what each built row reads, not the list: only the rows
    /// on screen are drawn again, so the cost does not follow the vault. The page tells the selection which rows it shows by itself.
    @MainActor
    func testSelectingEveryCredentialAndMovingTheCursorStaysQuick() async throws {
        try await withLargeVault { profile, vault in
            let model = try await loadedModel(profile, vault)
            let selection = CredentialSelection()
            let (host, window) = Self.mount(Self.page(model, selection: selection))
            Self.settle(host)
            let shown = await waitUntil { selection.order.count == Self.count }
            XCTAssertTrue(shown, "the page tells the selection which rows it shows")

            let clock = ContinuousClock()
            let started = clock.now
            selection.takeKeyboard()
            selection.selectAll()
            Self.settle(host)
            for _ in 0..<20 {
                selection.moveCursor(by: 1, extending: false)
                Self.settle(host)
            }
            let elapsed = clock.now - started
            window.close()
            print("[credential-list] select all and 20 cursor moves, \(Self.count) credentials: \(elapsed)")
            XCTAssertEqual(selection.selected.count, Self.count)
            XCTAssertEqual(selection.cursor, selection.order[20])
            XCTAssertLessThan(elapsed, .milliseconds(250))
        }
    }

    /// Switching to "By Site" lists the same 3,000 credentials under a heading per site (here all on one registrable site, the heaviest
    /// group): the page's own task groups them, and only the rows on screen are laid out. Timed from the switch, as a search is, so the
    /// grouping and its layout are both inside the measurement.
    @MainActor
    func testTheSiteGroupsLayOutWellUnderASecond() async throws {
        try await withLargeVault { profile, vault in
            let model = try await loadedModel(profile, vault)
            let list = CredentialListState()
            let (host, window) = Self.mount(Self.page(model, list: list))
            Self.settle(host)
            let counted = await waitUntil { list.counts != nil }
            XCTAssertTrue(counted, "the page counts the kinds when it appears")

            let clock = ContinuousClock()
            let started = clock.now
            list.bySite = true
            let grouped = await waitUntil(tick: .milliseconds(5)) { list.siteGroups != nil }
            Self.settle(host)
            let elapsed = clock.now - started
            window.close()
            print("[credential-list] site groups layout, \(Self.count) credentials: \(elapsed)")
            XCTAssertTrue(grouped, "the page groups the credentials once By Site is on")
            XCTAssertEqual(list.siteGroups?.flatMap(\.ids).count, Self.count)
            XCTAssertLessThan(elapsed, .seconds(1))
        }
    }

    /// Choosing what to export lists every credential too. Both variants, the CSV one filtering to the exportable ones first.
    @MainActor
    func testTheExportSheetsLayOutWellUnderASecond() async throws {
        try await withLargeVault { profile, vault in
            let model = try await loadedModel(profile, vault)
            for csv in [false, true] {
                let (host, window) = Self.mount(CredentialExportSheet(model: model, csv: csv) { _ in })
                let elapsed = Self.seconds { Self.settle(host) }
                window.close()
                print("[credential-list] \(csv ? "CSV " : "")export sheet, \(Self.count) credentials: \(elapsed) s")
                XCTAssertLessThan(elapsed, 1.0)
            }
        }
    }

    /// From the vault being locked to the list being ready: the passkey prompt is the user's, everything after it is WSurf's. The
    /// unlock verifies and decrypts every row; none of that may hold the main actor, which draws the sheet closing meanwhile.
    @MainActor
    func testUnlockToListIsBoundedAndKeepsTheMainActorFree() async throws {
        try await withLargeVault { profile, vault in
            let model = CredentialSettingsModel(profile: profile, manager: vault.manager)
            vault.manager.lock(reason: .manual)
            let clock = ContinuousClock()
            var longestStall = Duration.zero
            let heartbeat = Task { @MainActor in
                var last = clock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                    longestStall = max(longestStall, clock.now - last - .milliseconds(5))
                    last = clock.now
                }
            }
            let started = clock.now
            try await VaultManagerFixture.unlock(vault)
            let unlocked = clock.now - started
            await model.load()
            let listed = clock.now - started
            heartbeat.cancel()
            print("[credential-list] unlock \(unlocked), unlock to list \(listed), longest main-actor stall \(longestStall)")
            XCTAssertEqual(model.summaries.count, Self.count)
            XCTAssertLessThan(listed, .seconds(10))
            XCTAssertLessThan(longestStall, .milliseconds(250))
        }
    }
}
