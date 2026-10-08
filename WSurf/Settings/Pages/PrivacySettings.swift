// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

struct PrivacySettings: View {
    let coordinator: AppCoordinator

    @Bindable var settings: BrowserSettings

    @State private var isClearing = false
    @State private var cleared = false
    @State private var siteCount: Int?
    @State private var showingWebsiteData = false
    @State private var error: String?

    private var pageCount: Int {
        coordinator.browser.history.count
    }

    var body: some View {
        if showingWebsiteData {
            WebsiteDataPage(
                context: coordinator.context,
                onBack: { showingWebsiteData = false }
            )
        } else {
            page
        }
    }

    @ViewBuilder
    private var page: some View {
        SettingsPageHeader(title: "Privacy")

        SettingsCard {
            DetailRow(title: "Block known trackers") {
                SettingsToggle($settings.blocksTrackers)
            }
            .settingsAnchor("privacy.trackers")

            RowSeparator()

            DetailRow(
                title: "Clear browsing data",
                caption: "Choose a time range to clear history, cookies, and cached files."
            ) {
                HStack(spacing: 10) {
                    if isClearing {
                        Spinner(size: 12)
                            .foregroundStyle(.secondary)
                    } else if cleared {
                        HStack(spacing: 6) {
                            StatusDot(.ready, haloed: false)
                            Text("Done")
                        }
                        .font(Theme.Font.label)
                        .foregroundStyle(.tertiary)
                    }

                    SettingsButton(title: "Clear…", isDestructive: true, symbol: "trash") {
                        Task { await clear() }
                    }
                    .disabled(isClearing)
                }
            }
            .settingsAnchor("privacy.clear")

            RowSeparator()

            DetailRow(
                title: "Clear on quit",
                caption: "Clear cookies, site data, and cached files when you quit WSurf."
            ) {
                SettingsToggle($settings.clearsDataOnQuit)
            }
            .settingsAnchor("privacy.quit")
        }

        SettingsSection(title: "History and website data", symbol: "clock") {
            DetailRow(
                title: "Keep history for",
                caption: retentionCaption
            ) {
                SettingsMenu(
                    options: HistoryRetention.allCases.map { .init(value: $0, label: String(localized: $0.label)) },
                    selection: Binding(
                        get: { settings.historyRetention },
                        set: { retention in
                            settings.historyRetention = retention
                            coordinator.browser.history.prune(retention: retention)
                        }
                    )
                )
            }
            .settingsAnchor("privacy.history")

            RowSeparator()

            DrillInRow(title: "Website data", caption: siteSummary) {
                showingWebsiteData = true
            }
            .disabled((siteCount ?? 0) == 0)
            .settingsAnchor("privacy.storage")
        }
        .task(id: coordinator.context.contextID) {
            siteCount = nil
            let context = coordinator.context
            do {
                let count = try await BrowsingData.siteCount(context: context)
                guard coordinator.context.contextID == context.contextID else { return }
                siteCount = count
            } catch {
                guard coordinator.context.contextID == context.contextID else { return }
                siteCount = nil
                self.error = error.localizedDescription
            }
        }
        .alert(
            "Couldn’t clear browsing data",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? String(localized: "Try again."))
        }
    }

    private var siteSummary: LocalizedStringResource {
        switch siteCount {
        case nil:
            "Counting…"
        case 0:
            "No website stores data."
        case let count?:
            "\(count) websites are storing data."
        }
    }

    private var retentionCaption: LocalizedStringResource {
        pageCount == 0
            ? "No pages recorded yet."
            : "\(pageCount) pages kept. Older pages are removed."
    }

    private func clear() async {
        let context = coordinator.context
        let tabs = coordinator.browser.tabs
        guard let owner = context.extensions.adapter(for: coordinator.browser),
              let window = owner.nativeWindow, context.isRegistered(coordinator.browser),
              let choice = await ConfirmAlert.clear(.privacy(), in: window),
              coordinator.context === context, context.isRegistered(coordinator.browser),
              context.extensions.adapter(for: coordinator.browser) === owner,
              owner.nativeWindow === window else { return }
        isClearing = true
        cleared = false
        defer { isClearing = false }
        do {
            try await BrowsingData.clear(
                choice.kinds,
                range: choice.range,
                history: context.history,
                tabs: tabs,
                context: context
            )
            guard coordinator.context.contextID == context.contextID else { return }
            siteCount = try await BrowsingData.siteCount(context: context)
            cleared = true
        } catch {
            guard coordinator.context.contextID == context.contextID else { return }
            self.error = error.localizedDescription
        }
    }
}
