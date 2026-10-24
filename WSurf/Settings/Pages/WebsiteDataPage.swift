// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

struct WebsiteDataPage: View {
    let context: BrowserProfileContext
    let onBack: () -> Void

    @State private var snapshot: WebsiteData.Snapshot?
    /// The ids of the sites whose data is being removed: their rows show a spinner in place of the button.
    @State private var removing: Set<String> = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var removingEntry: WebsiteData.Entry?
    @State private var confirmingRemoveAll = false
    @State private var error: String?
    @State private var activeContextID: UUID?
    @FocusState private var searchFocused: Bool

    private var entries: [WebsiteData.Entry] {
        snapshot?.entries ?? []
    }

    private var shown: [WebsiteData.Entry] {
        entries.filter { WebsiteData.matches($0, query: query) }
    }

    var body: some View {
        SubPageHeader(backTitle: "Privacy", onBack: onBack) {
            if !entries.isEmpty {
                SettingsButton(title: "Remove all…", isDestructive: true) {
                    confirmingRemoveAll = true
                }
                .confirmationDialog(
                    "Remove the data stored by every website?",
                    isPresented: $confirmingRemoveAll
                ) {
                    Button("Remove all", role: .destructive) {
                        Task { await removeAll() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You’re signed out of \(entries.count) websites, and their preferences are removed. Your history and downloads stay.")
                }
            }
        }

        SettingsPageHeader(
            title: "Website data",
            caption: "Websites use this data to keep you signed in and remember your preferences."
        )

        SettingsSection(title: "Stored on this Mac", symbol: "internaldrive", isLongList: true, accessory: {
            if !entries.isEmpty {
                searchField
            }
        }, content: {
            if isLoading {
                loading
            } else if entries.isEmpty {
                SettingsEmptyState(
                    symbol: "internaldrive",
                    title: "No website data",
                    caption: "No website stores data on this Mac."
                )
            } else if shown.isEmpty {
                SettingsEmptyState(
                    symbol: "magnifyingglass",
                    title: "No matches",
                    caption: "No website matches what you typed."
                )
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    SiteRow(host: entry.displayName, summary: entry.summary) {
                        if removing.contains(entry.id) {
                            Spinner(size: 12)
                                .foregroundStyle(.secondary)
                        } else {
                            SettingsButton(title: "Remove…", isDestructive: true) {
                                removingEntry = entry
                            }
                        }
                    }
                    .separated(above: index > 0)
                }
            }
        })
        .task(id: context.contextID) {
            activeContextID = context.contextID
            isLoading = true
            snapshot = nil
            removing = []
            await reload()
        }
        .confirmationDialog(
            removingEntry.map {
                Text("Remove the data stored by \"\($0.displayName)\" in \(String(localized: $0.engine.label))?")
            } ?? Text(verbatim: ""),
            isPresented: Binding(get: { removingEntry != nil }, set: { if !$0 { removingEntry = nil } })
        ) {
            Button("Remove", role: .destructive) {
                guard let entry = removingEntry else { return }
                Task { await remove([entry]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’re signed out of this website, and its preferences are removed.")
        }
        .alert(
            "Couldn’t update website data",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? String(localized: "Try again."))
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            Spinner(size: 12)
                .foregroundStyle(.secondary)
            Text("Counting…")
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, SettingsMetrics.rowPaddingV)
    }

    private var searchField: some View {
        SearchFieldChrome(height: 24) {
            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.label)
                .fieldPlaceholder("Search websites", isShowing: query.isEmpty)
                .focused($searchFocused)
                .frame(width: 130)
        }
    }

    private func reload() async {
        let contextID = context.contextID
        do {
            let loaded = try await WebsiteData.snapshot(context: context)
            guard activeContextID == contextID else { return }
            snapshot = loaded
        } catch {
            guard activeContextID == contextID else { return }
            self.error = error.localizedDescription
        }
        if activeContextID == contextID {
            isLoading = false
        }
    }

    /// Removes what the list already knows about the chosen sites and drops their rows, without counting every site again.
    private func remove(_ selected: Set<WebsiteData.Entry>) async {
        guard let counted = snapshot else { return }
        let contextID = context.contextID
        let ids = Set(selected.map(\.id))
        removing.formUnion(ids)
        do {
            try await WebsiteData.remove(selected, of: counted, context: context)
            guard activeContextID == contextID else { return }
            removingEntry = nil
            snapshot = snapshot?.removing(selected)
            removing.subtract(ids)
        } catch {
            guard activeContextID == contextID else { return }
            self.error = error.localizedDescription
            removing.subtract(ids)
            // Part of the data may have gone: count again so the list says what is left.
            await reload()
        }
    }

    private func removeAll() async {
        let contextID = context.contextID
        do {
            try await WebsiteData.removeAll(context: context)
            guard activeContextID == contextID else { return }
            await reload()
        } catch {
            guard activeContextID == contextID else { return }
            self.error = error.localizedDescription
        }
    }
}
