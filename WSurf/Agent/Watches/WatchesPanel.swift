// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import SwiftUI

/// One row of the Watches tab: the watch and what the site's settings say about how it is read.
struct PageWatchRow: Identifiable, Equatable {
    enum Status: Equatable {
        case watching
        case paused
        case unreachable
    }

    let watch: PageWatch
    let readsWithWebKitInstead: Bool

    var id: UUID {
        watch.id
    }

    var title: String {
        watch.title.isEmpty ? watch.place : watch.title
    }

    var status: Status {
        if watch.isPausedByPerson {
            return .paused
        }
        return watch.isUnreachable ? .unreachable : .watching
    }

    var usesSignIns: Bool {
        watch.access == .signedIn
    }

    static func rows(_ center: PageWatchCenter, permissions: SitePermissions) -> [PageWatchRow] {
        center.watches.map {
            PageWatchRow(watch: $0, readsWithWebKitInstead: PageWatchReader.readsWithWebKitInstead($0.url, permissions: permissions))
        }
    }

    /// The count on the Watches tab: notices WSurf could not show while its notifications were off, and the person has not dismissed.
    static func badge(for center: PageWatchCenter?) -> Int {
        center?.missed.count ?? 0
    }
}

struct WatchesPanelSurface: View {
    let coordinator: AppCoordinator

    var body: some View {
        if let center = coordinator.context.pageWatches {
            WatchesList(center: center, permissions: coordinator.context.sitePermissions) { url in
                _ = coordinator.openNewTab(url: url)
            }
        } else {
            PanelNotice(symbol: "eye.slash", title: "Not available in private windows", caption: "A private window watches no pages.")
        }
    }
}

private struct WatchesList: View {
    let center: PageWatchCenter
    let permissions: SitePermissions
    let open: (URL) -> Void

    var body: some View {
        let rows = PageWatchRow.rows(center, permissions: permissions)
        if rows.isEmpty, center.missed.isEmpty {
            PanelNotice(
                symbol: "eye",
                title: "No pages watched",
                caption: "Choose View › Watch This Page…, or ask the assistant to watch a page."
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if !center.missed.isEmpty {
                        MissedNotices(center: center, open: open)
                        Divider().overlay(Theme.Wash.hairline)
                            .padding(.horizontal, 12)
                    }
                    ForEach(rows) { row in
                        WatchRow(
                            row: row,
                            onOpen: { open(row.watch.url) },
                            onCheck: { Task { await center.check(row.id) } },
                            onPause: { center.setPaused(row.id, row.status != .paused) },
                            onStop: { center.stop(row.id) }
                        )
                        if row.id != rows.last?.id {
                            Divider().overlay(Theme.Wash.hairline)
                                .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
        }
    }
}

private struct MissedNotices: View {
    let center: PageWatchCenter
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("While notifications were off")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Clear") { center.dismissMissed() }
                    .buttonStyle(.plain)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.accentText)
            }
            ForEach(center.missed) { missed in
                MissedRow(
                    missed: missed,
                    onOpen: { open(missed.url) },
                    onDismiss: { center.dismissMissed(missed.id) }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct MissedRow: View {
    let missed: PageWatchCenter.Missed
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: missed.place)
                        .font(Theme.Font.rowTitle)
                    Text(verbatim: NotificationBridge.body(condition: missed.condition, missed.notice))
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(verbatim: missed.date.formatted(.relative(presentation: .named)))
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Open Page"))

            QuietIconButton(symbol: "xmark", isOn: false, help: String(localized: "Dismiss"), action: onDismiss)
                .accessibilityLabel(Text("Dismiss"))
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open Page", action: onOpen)
            Button("Dismiss", action: onDismiss)
        }
    }
}

private struct WatchRow: View {
    let row: PageWatchRow
    let onOpen: () -> Void
    let onCheck: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void

    @State private var hovering = false

    private var interval: String {
        Duration.seconds(row.watch.period).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private var pauseTitle: LocalizedStringResource {
        row.status == .paused ? "Resume Watching" : "Pause Watching"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onOpen) {
                details
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Open Page"))

            HStack(spacing: 2) {
                QuietIconButton(
                    symbol: row.status == .paused ? "play" : "pause",
                    isOn: false,
                    help: String(localized: pauseTitle),
                    action: onPause
                )
                .accessibilityLabel(Text(pauseTitle))
                QuietIconButton(symbol: "xmark", isOn: false, help: String(localized: "Stop Watching"), action: onStop)
                    .accessibilityLabel(Text("Stop Watching"))
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open Page", action: onOpen)
            Button("Check Now", action: onCheck)
            Button(String(localized: pauseTitle), action: onPause)
            Divider()
            Button("Stop Watching", action: onStop)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.title)
                .font(Theme.Font.rowTitle)
                .lineLimit(1)
            Text(verbatim: row.watch.place)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Group {
                if row.watch.condition.isEmpty {
                    Text("Waiting for any change")
                } else {
                    Text("Waiting for \(row.watch.condition)")
                }
            }
            .font(Theme.Font.body)
            .padding(.top, 3)
            if let state = row.watch.state, !state.isEmpty {
                Text(verbatim: state)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
            labels
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                if let checked = row.watch.lastChecked {
                    Text("Every \(interval) · Checked \(checked.formatted(.relative(presentation: .named)))")
                } else {
                    Text("Every \(interval)")
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var labels: some View {
        switch row.status {
        case .paused:
            Label("Paused", systemImage: "pause.circle")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        case .unreachable:
            Label("Can’t be read, so it’s paused. Check Now tries again.", systemImage: "exclamationmark.triangle")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.warning)
        case .watching:
            EmptyView()
        }
        if row.usesSignIns {
            Label("Uses your sign-ins", systemImage: "lock")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
        if row.readsWithWebKitInstead {
            Label("Reads with WebKit", systemImage: "safari")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .help(Text(PageWatchReader.webKitNote))
        }
    }
}

/// Settings › Assistant: how many pages are watched, a switch that pauses them all, and the way to the Watches tab.
struct PageWatchesSettingsSection: View {
    let center: PageWatchCenter?
    let open: () -> Void

    static func summary(for center: PageWatchCenter?) -> LocalizedStringResource {
        guard let center else { return "Not in private windows" }
        return center.watches.isEmpty ? "None" : "\(center.watches.count) pages"
    }

    var body: some View {
        SettingsSection(title: "Page Watches", symbol: "eye") {
            DrillInRow(
                title: "Watched pages",
                caption: "Pages WSurf reads in the background to tell you when they change. Checked on this Mac only.",
                detail: Self.summary(for: center),
                action: open
            )
            if let center, !center.watches.isEmpty {
                RowSeparator()

                DetailRow(title: "Pause all watches", caption: "Paused watches keep their place and still end after 30 days.") {
                    SettingsToggle(Binding(
                        get: { center.watches.allSatisfy(\.isPausedByPerson) },
                        set: { center.setAllPaused($0) }
                    ))
                }
            }
        }
        .settingsAnchor("assistant.watches")
    }
}
