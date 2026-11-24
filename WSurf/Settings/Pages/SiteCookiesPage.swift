// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

/// Settings → Websites → a website: its cookie count, Manage… and Delete Cookies….
struct SiteCookiesSettingsSection: View {
    let model: SiteCookiesModel
    let onManage: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        SettingsSection(title: "Cookies", symbol: "list.bullet.rectangle") {
            DrillInRow(
                title: "Manage cookies",
                caption: "Inspect, copy, or delete the cookies of this website in WebKit and Chromium.",
                detail: model.countLabel,
                action: onManage
            )

            RowSeparator()

            DetailRow(
                title: "Delete cookies",
                caption: "Signs you out of this website and clears its cached icon."
            ) {
                SettingsButton(title: "Delete Cookies…", isDestructive: true) {
                    confirmingDelete = true
                }
                .disabled(model.cookies?.isEmpty != false || model.deleting.contains(SiteCookiesModel.allID))
                .confirmationDialog(
                    Text("Delete the cookies of \"\(model.host)\"?"),
                    isPresented: $confirmingDelete
                ) {
                    Button("Delete Cookies", role: .destructive) {
                        Task { await model.deleteAll() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Cookies in WebKit and Chromium and the cached icon are removed. You’re signed out of this website.")
                }
            }
        }
        .alert(
            "Couldn’t update cookies",
            isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? String(localized: "Try again."))
        }
    }
}

/// Every cookie of one website, to inspect, copy and delete.
struct SiteCookiesDetailPage: View {
    let model: SiteCookiesModel
    let onBack: () -> Void

    @State private var query = ""
    @State private var engine: BrowserEngine?
    @State private var confirmingDeleteAll = false

    private var cookies: [SiteCookie] {
        model.cookies ?? []
    }

    private var shown: [SiteCookie] {
        SiteCookieFilter.apply(cookies, query: query, engine: engine)
    }

    private var engineItems: [SegmentedControl<BrowserEngine?>.Item] {
        [.init(value: nil, label: "All")] + BrowserEngine.allCases.map { .init(value: $0, label: $0.label) }
    }

    var body: some View {
        SubPageHeader(verbatimBackTitle: model.host, onBack: onBack) {
            SettingsButton(
                title: model.clearedFavicon ? "Cached Favicon Cleared" : "Clear Cached Favicon",
                symbol: "photo"
            ) {
                model.clearFavicon()
            }
            .disabled(model.clearedFavicon)

            if !cookies.isEmpty {
                SettingsButton(title: "Delete all…", isDestructive: true) {
                    confirmingDeleteAll = true
                }
                .disabled(model.deleting.contains(SiteCookiesModel.allID))
                .confirmationDialog(
                    Text("Delete every cookie of \"\(model.host)\"?"),
                    isPresented: $confirmingDeleteAll
                ) {
                    Button("Delete all", role: .destructive) {
                        Task { await model.deleteAll() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Cookies in WebKit and Chromium and the cached icon are removed. You’re signed out of this website.")
                }
            }
        }

        SettingsPageHeader(
            title: "Cookies",
            caption: "Cookies keep you signed in and remember your choices on this website."
        )

        if model.hasBothEngines {
            SegmentedControl(
                items: engineItems,
                selection: engine,
                onSelect: { engine = $0 }
            )
            .frame(maxWidth: 280)
        }

        SettingsSection(title: "Stored on this Mac", symbol: "internaldrive", isLongList: true, accessory: {
            if !cookies.isEmpty {
                SearchFieldChrome(height: 24) {
                    TextField("", text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.label)
                        .fieldPlaceholder("Search cookies", isShowing: query.isEmpty)
                        .frame(width: 130)
                }
            }
        }, content: {
            if model.cookies == nil {
                HStack(spacing: 8) {
                    Spinner(size: 12)
                        .foregroundStyle(.secondary)
                    Text("Counting…")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, SettingsMetrics.rowPaddingV)
            } else if cookies.isEmpty {
                SettingsEmptyState(symbol: "list.bullet.rectangle", title: "No cookies", caption: "This website has no cookies on this Mac.")
            } else if shown.isEmpty {
                SettingsEmptyState(symbol: "magnifyingglass", title: "No matches", caption: "No cookie matches what you typed.")
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, cookie in
                    SiteCookieRow(cookie: cookie, isDeleting: model.deleting.contains(cookie.id)) {
                        Task { await model.delete(cookie) }
                    }
                    .separated(above: index > 0)
                }
            }
        })

        if model.chromiumUnavailable {
            Footnote("Chromium cookies aren’t shown. Open this website in a Chromium tab to see them.")
        }
    }
}
