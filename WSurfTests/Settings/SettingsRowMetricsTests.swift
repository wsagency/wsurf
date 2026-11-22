// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing
import WSurfCore

@testable import WSurf

/// The gap between two settings options is two row paddings and one hairline. A row adds no space of its own, so a
/// page cannot grow back what `SettingsMetrics.rowPaddingV` took out.
@MainActor
struct SettingsRowMetricsTests {
    private func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.frame(width: 500)).fittingSize.height
    }

    private var control: some View {
        Color.clear.frame(width: 40, height: SettingsMetrics.controlHeight)
    }

    private var rowHeight: CGFloat {
        SettingsMetrics.controlHeight + 2 * SettingsMetrics.rowPaddingV
    }

    @Test func aRowIsItsControlAndTwoPaddings() {
        let row = DetailRow(verbatimTitle: "Option") { control }

        #expect(abs(height(row) - rowHeight) < 0.5)
    }

    @Test func twoRowsAreSeparatedByTwoPaddingsAndAHairline() {
        let rows = VStack(alignment: .leading, spacing: 0) {
            DetailRow(verbatimTitle: "First") { control }
            RowSeparator()
            DetailRow(verbatimTitle: "Second") { control }
        }

        #expect(abs(height(rows) - (2 * rowHeight + 1)) < 0.5)
    }

    @Test func savedProviderKeysLeavesRoomForItsAccountNotice() {
        let switchOnly = SettingsSection(title: "Saved provider keys", symbol: "key.icloud") {
            DetailRow(title: "Share saved keys with iCloud Keychain") {
                SettingsToggle(.constant(false))
            }
        }
        let notice = Text("A verified Apple Account is required to share saved keys.").font(Theme.Font.label)
        let actual = height(ProviderKeySyncSection(profile: .original()))
        #expect(actual >= height(switchOnly) + height(notice))
    }

    @Test func sharedPinsHaveOneProfileControlRegardlessOfLibrarySize() async throws {
        let profile = Profile.original()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfilePinStore.store(for: .temporary())
        let spaces = SpaceStore(profile: profile, file: nil)
        var pinStoreReads = 0
        let host = CloudSharedSpaces(
            stateFile: directory.appending(path: "shared.json"), profiles: [profile], windows: { [] }, spaces: { _ in spaces },
            pins: { _ in
                pinStoreReads += 1
                return store
            }
        )
        host.attach(FakeSyncEngine(cloud: FakeSyncCloud(), delegate: host.catalog))
        try await host.enable(.profiles, for: profile)
        host.links[profile.id] = .init(profile: UUID())
        try await host.enable(.spaces, for: profile)
        let legacy = height(SharedProfileLinkSection(profile: profile, host: host))
        try await host.enable(.pins, for: profile)
        host.pause(.pins, for: profile)
        let shared = height(SharedProfileLinkSection(profile: profile, host: host))
        #expect(abs(legacy - shared) < 0.5, "An older link and a paused library each offer the same pin sharing row.")

        let catalog = ProfileStore(file: directory.appending(path: "profiles.json"))
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()), profiles: .selection(profile: profile, catalog: catalog))
        defer { coordinator.browser.closeAllTabs(saving: false) }
        let spaceHeight = height(SharedSpacesSettingsView(profile: profile, host: host, coordinator: coordinator))
        store.publish((0..<30).map { index in
            ProfilePin(id: UUID(), orderKey: String(index), kind: .tab, url: "https://example.test/\(index)", isFavorite: index.isMultiple(of: 2))
        })
        let reads = pinStoreReads
        #expect(abs(height(SharedProfileLinkSection(profile: profile, host: host)) - shared) < 0.5)
        #expect(abs(height(SharedSpacesSettingsView(profile: profile, host: host, coordinator: coordinator)) - spaceHeight) < 0.5)
        #expect(pinStoreReads == reads)
    }

    /// The rows of a disclosure group, such as the colors of a theme, sit as close as the rows of any other card.
    @Test func disclosureContentAddsNoSpaceBetweenItsChildren() {
        let child: CGFloat = 20

        func disclosure(children: Int) -> CGFloat {
            height(
                DisclosureGroup("Header", isExpanded: .constant(true)) {
                    ForEach(0..<children, id: \.self) { _ in
                        Color.clear.frame(width: 40, height: child)
                    }
                }
                .disclosureGroupStyle(ClickableDisclosureStyle())
            )
        }

        #expect(abs(disclosure(children: 3) - disclosure(children: 2) - child) < 0.5)
    }
}
