// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

/// The speaker. It shows while a tab of this profile plays sound, and while WSurf is muted. Pointing at it lists the tabs that
/// play, each with its icon, title, site and a mute of its own, and choosing one takes you to it, in whichever window and
/// space it is. Pressing it mutes WSurf, every tab of every window; pressing it again gives each tab its own mute back.
/// Right-clicking it, and VoiceOver's actions, offer the same tabs for people who do not point.
struct AudioIndicatorButton: View {
    enum Style {
        /// The sidebar's foot: a quiet round button like Settings and Downloads.
        case sidebar
        /// A bar's button: the Minimal bar and the micro bar.
        case bar
    }

    let coordinator: AppCoordinator
    var style: Style = .sidebar
    /// The side of the speaker the list opens to.
    var listEdge: Edge = .trailing

    @State private var showsList = false
    @State private var overButton = false
    @State private var overList = false
    @State private var pending: Task<Void, Never>?

    private static let openDelay: Duration = .milliseconds(350)
    private static let closeDelay: Duration = .milliseconds(220)

    var body: some View {
        let tabs = coordinator.audibleTabs
        let isMuted = coordinator.isWSurfMuted
        let isShown = AudioIndicator.isVisible(audibleCount: tabs.count, isMuted: isMuted)
        Group {
            if isShown {
                speaker(tabs: tabs, isMuted: isMuted)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.settle, value: isShown)
    }

    @ViewBuilder
    private func button(isMuted: Bool) -> some View {
        let symbol = AudioIndicator.symbol(isMuted: isMuted)
        // No tooltip: the list that opens on hover says what pressing does.
        switch style {
        case .sidebar:
            QuietIconButton(
                symbol: symbol,
                isOn: false,
                tint: isMuted ? nil : Theme.systemAccent,
                help: ""
            ) { coordinator.toggleWSurfMute() }
        case .bar:
            ToolbarButton(symbol: symbol, enabled: true, help: "") { coordinator.toggleWSurfMute() }
        }
    }

    private func speaker(tabs: [AudibleTab], isMuted: Bool) -> some View {
        let hint: LocalizedStringResource = isMuted
            ? "Unmutes WSurf and gives each tab its own setting back."
            : "Mutes every tab in every window."
        return button(isMuted: isMuted)
            .accessibilityLabel(Text(verbatim: AudioIndicator.label(audibleCount: tabs.count, isMuted: isMuted)))
            .accessibilityHint(Text(hint))
            .accessibilityActions {
                ForEach(tabs) { audible in
                    Button(String(localized: "Show “\(audible.tab.title)”")) {
                        coordinator.audioScope.show(audible)
                    }
                }
            }
            .contextMenu {
                ForEach(tabs) { audible in
                    Button {
                        coordinator.audioScope.show(audible)
                    } label: {
                        Text(verbatim: String(localized: "Show “\(audible.tab.title)”"))
                    }
                }
                if !tabs.isEmpty {
                    Divider()
                }
                Button {
                    coordinator.toggleWSurfMute()
                } label: {
                    Label(AudioIndicator.help(isMuted: isMuted), systemImage: AudioIndicator.symbol(isMuted: isMuted))
                }
            }
            .onHover { inside in
                overButton = inside
                settle()
            }
            .popover(isPresented: $showsList, arrowEdge: listEdge) {
                AudioTabsList(coordinator: coordinator) { showsList = false }
                    .onHover { inside in
                        overList = inside
                        settle()
                    }
            }
            .onChange(of: showsList) { _, isOpen in
                coordinator.isAudioListOpen = isOpen
            }
            .onDisappear {
                pending?.cancel()
                showsList = false
                coordinator.isAudioListOpen = false
            }
    }

    /// Opens the list a moment after the pointer arrives and closes it a moment after the pointer has left both the speaker
    /// and the list, so the way from one to the other does not close it.
    private func settle() {
        pending?.cancel()
        let wanted = overButton || overList
        guard wanted != showsList else { return }
        pending = Task {
            try? await Task.sleep(for: wanted ? Self.openDelay : Self.closeDelay)
            guard !Task.isCancelled else { return }
            showsList = wanted
        }
    }
}

/// The speaker in the Standard window's toolbar, for a window whose sidebar is not on screen: the sidebar carries it otherwise, and
/// there is never one in each. Shown by the same rule as the sidebar's: while a tab plays or WSurf is muted, with the same list on
/// hover and the same mute on a press.
struct ToolbarAudioIndicator: View {
    let coordinator: AppCoordinator

    /// Whether the toolbar carries the speaker now. The toolbar makes room for it by this.
    static func isShown(in coordinator: AppCoordinator) -> Bool {
        AudioIndicator.place(
            audibleCount: coordinator.audibleTabs.count,
            isMuted: coordinator.isWSurfMuted,
            isSidebarShowing: coordinator.sidebar.isShowing
        ) == .toolbar
    }

    var body: some View {
        if Self.isShown(in: coordinator) {
            AudioIndicatorButton(coordinator: coordinator, style: .bar, listEdge: .bottom)
        }
    }
}

/// What the speaker lists: the tabs playing now, then the switch for all of WSurf.
struct AudioTabsList: View {
    let coordinator: AppCoordinator
    let dismiss: () -> Void

    @Environment(\.windowColorScheme) private var windowColorScheme

    var body: some View {
        let tabs = coordinator.audibleTabs
        let isMuted = coordinator.isWSurfMuted
        let header: LocalizedStringResource = tabs.isEmpty ? "No tab is playing audio" : "Playing Audio"
        VStack(alignment: .leading, spacing: 6) {
            Text(header)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 2) {
                ForEach(tabs) { audible in
                    AudioTabRow(audible: audible, dismiss: dismiss)
                }
            }

            Divider().opacity(0.5)

            Button {
                coordinator.toggleWSurfMute()
                dismiss()
            } label: {
                Label(AudioIndicator.help(isMuted: isMuted), systemImage: AudioIndicator.symbol(isMuted: isMuted))
                    .font(Theme.Font.control)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 300)
        .background(.ultraThickMaterial)
        .environment(\.colorScheme, windowColorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Playing Audio"))
    }
}

private struct AudioTabRow: View {
    let audible: AudibleTab
    let dismiss: () -> Void

    @State private var hovering = false

    private var tab: BrowserTab {
        audible.tab
    }

    /// The tab's website, without the `www.` every address of it starts with.
    private var site: String {
        guard tab.internalPage == nil, let host = URL(string: tab.urlString)?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Which other window it plays in, so two tabs of one site in two windows can be told apart.
    private var windowMark: String? {
        guard !audible.isHere else { return nil }
        return audible.window.isMicro ? String(localized: "Micro Window") : String(localized: "Another Window")
    }

    private var caption: String {
        [site, windowMark].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        let muteTitle: LocalizedStringResource = tab.isMuted ? "Unmute Tab" : "Mute Tab"
        HStack(spacing: 4) {
            Button {
                dismiss()
                audible.window.audioScope.show(audible)
            } label: {
                HStack(spacing: 8) {
                    TabFaviconMark(tab: tab)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: tab.title)
                            .font(Theme.Font.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !caption.isEmpty {
                            Text(verbatim: caption)
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show “\(tab.title)”"))
            .accessibilityValue(Text(verbatim: caption))

            Button {
                audible.window.toggleMute(tab: tab)
            } label: {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tab.isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.systemAccent))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(muteTitle))
            .accessibilityLabel(Text(muteTitle))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? Theme.Wash.hairline : Color.clear)
        )
        .onHover { hovering = $0 }
    }
}
