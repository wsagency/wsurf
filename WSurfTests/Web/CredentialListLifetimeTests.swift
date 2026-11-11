// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import XCTest

@testable import WSurf
@testable import WSurfVault

/// What the Credential Manager list leaves behind when it goes away: nothing. A list that keeps itself alive keeps the page's model, its
/// summaries and the selection with it, for the life of the app. All accounts are synthetic.
nonisolated final class CredentialListLifetimeTests: XCTestCase, @unchecked Sendable {
    private struct Weak {
        weak var model: CredentialSettingsModel?
        weak var list: CredentialListState?
        weak var selection: CredentialSelection?
    }

    @MainActor
    private func withSmallVault(_ body: (_ profile: Profile, _ vault: FixtureVault) async throws -> Void) async throws {
        let accounts = (0..<12).map {
            VaultFixtures.account(username: "user\($0)@example.test", password: "password-\($0)", origin: "https://site\($0).example.test")
        }
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let vault = try XCTUnwrap(vaults.first)
            try await VaultManagerFixture.save(accounts, in: vault)
            try await body(profile, vault)
        }
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

    /// Shows the page over a loaded model, runs `during` with it showing, closes it, and returns what is left holding the page's objects.
    @MainActor
    private func showAndClose(
        _ profile: Profile, _ vault: FixtureVault, during: (CredentialSettingsModel, CredentialListState, NSView) async throws -> Void
    ) async throws -> Weak {
        let model = CredentialSettingsModel(profile: profile, manager: vault.manager)
        await model.load()
        let list = CredentialListState()
        let selection = CredentialSelection()
        let page = ScrollView {
            VStack(alignment: .leading) {
                CredentialSettings(model: model, list: list, selection: selection)
            }
        }
        let (host, window) = Self.mount(page)
        Self.settle(host)
        let counted = await waitUntil { list.counts != nil }
        XCTAssertTrue(counted, "the list counts the kinds when it appears")
        try await during(model, list, host)
        window.contentView = nil
        window.close()
        return Weak(model: model, list: list, selection: selection)
    }

    @MainActor
    private static func anchorViews(in view: NSView) -> [CredentialWindowAnchorNSView] {
        let own = (view as? CredentialWindowAnchorNSView).map { [$0] } ?? []
        return own + view.subviews.flatMap { anchorViews(in: $0) }
    }

    /// The Passwords window hides the page header. The window anchor, which every passkey or file prompt of the page (Unlock
    /// included) reads its window from, must stay in the window either way, or each of those actions finds no window and does nothing.
    @MainActor
    func testThePageKeepsItsWindowAnchorWithoutItsHeader() async throws {
        try await withSmallVault { profile, vault in
            let standard = CredentialSettings(model: CredentialSettingsModel(profile: profile, manager: vault.manager))
            XCTAssertTrue(standard.showsHeader, "the page keeps its header by default")
            for showsHeader in [true, false] {
                let model = CredentialSettingsModel(profile: profile, manager: vault.manager)
                await model.load()
                let page = CredentialSettings(model: model, showsHeader: showsHeader)
                XCTAssertEqual(page.showsHeader, showsHeader)
                let (host, window) = Self.mount(ScrollView { VStack(alignment: .leading) { page } })
                Self.settle(host)
                let anchors = Self.anchorViews(in: host)
                XCTAssertEqual(anchors.count, 1, "one window anchor with showsHeader \(showsHeader)")
                XCTAssertTrue(anchors.first?.window === window, "the anchor resolves to the window hosting the page (showsHeader \(showsHeader))")
                window.contentView = nil
                window.close()
            }
        }
    }

    /// Closing the page releases the model, the list state and the selection.
    @MainActor
    func testClosingThePageReleasesItsObjects() async throws {
        try await withSmallVault { profile, vault in
            let left = try await showAndClose(profile, vault) { _, _, _ in }
            let released = await waitUntil(timeout: .seconds(10)) {
                return left.model == nil && left.list == nil && left.selection == nil
            }
            XCTAssertTrue(released, "model \(left.model != nil), list \(left.list != nil), selection \(left.selection != nil) still alive")
        }
    }

    /// A lock removes the list from a page that stays open: the list's own state goes with it.
    @MainActor
    func testLockingRemovesTheListAndItsActions() async throws {
        try await withSmallVault { profile, vault in
            let before = CredentialRowActions.live
            let left = try await showAndClose(profile, vault) { model, _, host in
                XCTAssertGreaterThan(CredentialRowActions.live, before, "an actions object exists while the list shows")
                model.lock()
                let gone = await waitUntil(timeout: .seconds(10)) {
                    Self.settle(host)
                    return CredentialRowActions.live == before
                }
                XCTAssertTrue(gone, "the actions of the list that a lock removed are still alive")
            }
            _ = left
        }
    }
}
