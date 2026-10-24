// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

struct UpdateBanner: View {
    let coordinator: AppCoordinator

    @Environment(\.sidebarStyle) private var sidebarStyle

    /// The banner's accent tint on an opaque ground, for Reduce Transparency and Increase Contrast.
    private static var solidFill: Color {
        Theme.windowBackground.mix(with: Theme.accent, by: 0.38)
    }

    private var updates: UpdateController {
        coordinator.updates
    }

    private var model: UpdateModel {
        updates.model
    }

    /// What the sidebar says about updates. An update on offer outranks the news that one was installed.
    enum Presence {
        case hidden, update, updated

        static func of(isBannerVisible: Bool, updatedVersion: String?) -> Presence {
            if isBannerVisible {
                return .update
            }
            return updatedVersion == nil ? .hidden : .updated
        }
    }

    private var presence: Presence {
        Presence.of(isBannerVisible: model.isBannerVisible, updatedVersion: coordinator.releaseNotes.updatedVersion)
    }

    static func isVisible(for coordinator: AppCoordinator) -> Bool {
        isVisible(model: coordinator.updates.model, notes: coordinator.releaseNotes)
    }

    static func isVisible(model: UpdateModel, notes: ReleaseNotesModel) -> Bool {
        Presence.of(isBannerVisible: model.isBannerVisible, updatedVersion: notes.updatedVersion) != .hidden
    }

    var body: some View {
        Group {
            switch presence {
            case .update:
                if sidebarStyle == .icons {
                    badge
                } else {
                    card
                }
            case .updated:
                if sidebarStyle == .icons {
                    updatedBadge
                } else {
                    updatedCard
                }
            case .hidden:
                EmptyView()
            }
        }
        .animation(Theme.Motion.drift, value: presence)
    }

    // MARK: - The card

    private var card: some View {
        cardShell {
            Text(bannerTitle)
                .font(Theme.Font.control.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            cardAccessory
        }
    }

    /// "Updated to 0.1.12" with a button to the notes, for the first launch of an installed build.
    private var updatedCard: some View {
        cardShell {
            Text(updatedTitle)
                .font(Theme.Font.control.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            SettingsButton(title: "What’s New", isProminent: true, action: readNotes)
        }
        .help(Text(updatedHelp))
    }

    private func cardShell(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8, content: content)
            .frame(minHeight: SettingsMetrics.controlHeight)
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .chromeGlass(
                .regular.tint(Theme.accent.opacity(0.38)),
                fill: Self.solidFill,
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .transition(.opacity)
    }

    @ViewBuilder
    private var cardAccessory: some View {
        switch model.phase {
        case .available, .readyToInstall:
            SettingsButton(
                title: LocalizedStringResource("update.banner.install", defaultValue: "Install"),
                isProminent: true,
                action: act
            )
        case .failed:
            SettingsButton(title: "Try Again", action: act)
        case .checking, .downloading, .extracting, .installing:
            Spinner(size: 13)
                .frame(width: SettingsMetrics.controlHeight, height: SettingsMetrics.controlHeight)
        case .idle, .upToDate:
            EmptyView()
        }
    }

    private var badge: some View {
        Button(action: act) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .chromeGlass(.regular.tint(Theme.accent.opacity(0.38)), fill: Self.solidFill, in: Circle())
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .help(Text(bannerTitle))
        .transition(.opacity)
    }

    private var updatedBadge: some View {
        Button(action: readNotes) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .chromeGlass(.regular.tint(Theme.accent.opacity(0.38)), fill: Self.solidFill, in: Circle())
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(updatedTitle))
        .help(Text(updatedHelp))
        .transition(.opacity)
    }

    private var updatedVersion: String {
        coordinator.releaseNotes.updatedVersion ?? UpdateFeed.currentVersion
    }

    private var updatedTitle: LocalizedStringResource {
        "Updated to \(updatedVersion)"
    }

    private var updatedHelp: String {
        Self.updatedHelp(version: updatedVersion, candidateLine: BuildIdentity.candidateLine())
    }

    /// The tooltip adds which candidate this is, when the build says: the same line About shows.
    static func updatedHelp(version: String, candidateLine: String?) -> String {
        [String(localized: "Updated to \(version)"), candidateLine].compactMap { $0 }.joined(separator: " · ")
    }

    private func readNotes() {
        coordinator.releaseNotes.acknowledgeUpdate()
        coordinator.showReleaseNotes()
    }

    private func act() {
        if model.phase == .available || model.phase == .readyToInstall {
            updates.proceed()
        } else {
            updates.checkNow()
        }
    }

    // MARK: - Wording

    private var isActionable: Bool {
        switch model.phase {
        case .downloading, .extracting, .installing:
            false
        default:
            true
        }
    }

    private var glyph: String {
        switch model.phase {
        case .readyToInstall, .installing:
            "arrow.up"
        case .upToDate:
            "checkmark"
        case .failed:
            "exclamationmark"
        default:
            "arrow.down"
        }
    }

    private var bannerTitle: LocalizedStringResource {
        UpdatePhrasing.title(for: model.phase)
    }
}

nonisolated enum UpdatePhrasing {
    static func title(for phase: UpdateModel.Phase) -> LocalizedStringResource {
        switch phase {
        case .available, .readyToInstall:
            "Update Available"
        case .downloading:
            "Downloading update"
        case .extracting:
            "Preparing update"
        case .installing:
            "Installing update"
        case .upToDate:
            "Up to date"
        case .failed:
            "Couldn’t check for updates"
        case .checking, .idle:
            "Checking for updates…"
        }
    }
}

// MARK: - The same state, in Settings

struct UpdateRow: View {
    let updates: UpdateController

    private var model: UpdateModel {
        updates.model
    }

    private var isFailure: Bool {
        if case .failed = model.phase {
            return true
        }
        return false
    }

    private var statusColor: AnyShapeStyle {
        if isFailure {
            return AnyShapeStyle(Theme.warning)
        }
        if model.phase == .available || model.phase == .readyToInstall {
            return AnyShapeStyle(Theme.accent)
        }
        return AnyShapeStyle(.tertiary)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Software Update")
                    .font(Theme.Font.title)

                Text(statusTitle)
                    .font(Theme.Font.secondary)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            UpdateActionButton(model: model, action: act)
        }
        .padding(.horizontal, SettingsMetrics.rowPaddingH)
        .padding(.vertical, SettingsMetrics.rowPaddingV)
        .animation(Theme.Motion.settle, value: model.phase)
    }

    private var statusTitle: LocalizedStringResource {
        switch model.phase {
        case .available:
            "Version \(model.version) is available. Installing restarts WSurf."
        case .downloading:
            "Downloading update"
        case .extracting:
            "Preparing update"
        case .readyToInstall:
            "Ready to install"
        case .installing:
            "Installing update"
        case .upToDate:
            "Up to date"
        case .failed:
            "Couldn’t check for updates"
        case .checking:
            "Checking for updates"
        case .idle:
            "Installed version \(UpdateFeed.currentVersion)"
        }
    }

    private func act() {
        if model.phase == .available || model.phase == .readyToInstall {
            updates.proceed()
        } else {
            updates.checkNow()
        }
    }
}

private struct UpdateActionButton: View {
    let model: UpdateModel
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                widthReservation

                Text(title)
                    .font(.system(size: 12, weight: isProminent ? .semibold : .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: model.progress))
                    .foregroundStyle(label)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: SettingsMetrics.controlHeight)
            .background { background }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .disabled(!isActionable)
        .onHover { hovering = isActionable && $0 }
        .animation(Theme.Motion.quick, value: hovering)
        .animation(Theme.Motion.drift, value: model.progress)
    }

    private var widthReservation: some View {
        ZStack {
            ForEach(Self.everyTitle, id: \.self) { text in
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .hidden()
            }
        }
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
        return ZStack(alignment: .leading) {
            Color.clear
                .settingsSurface(
                    isActive: hovering && isActionable,
                    tint: surfaceTint,
                    in: shape
                )

            if let progress {
                GeometryReader { proxy in
                    tint.opacity(0.3)
                        .frame(width: proxy.size.width * progress)
                }
            } else if isBusy {
                Sweep(tint: tint)
            }
        }
        .clipShape(shape)
    }

    // MARK: - What the phase makes of it

    private var isFailure: Bool {
        if case .failed = model.phase {
            return true
        }
        return false
    }

    private var isBusy: Bool {
        switch model.phase {
        case .checking, .downloading, .extracting, .installing:
            true
        default:
            false
        }
    }

    private var isActionable: Bool {
        !isBusy
    }

    private var isProminent: Bool {
        model.phase == .available || model.phase == .readyToInstall
    }

    private var progress: Double? {
        guard model.isProgressKnown else { return nil }
        switch model.phase {
        case .downloading, .extracting:
            return min(1, max(0, model.progress))
        default:
            return nil
        }
    }

    private var share: String {
        Self.share(of: progress ?? 0)
    }

    private static func share(of value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private var tint: Color {
        isFailure ? .orange : Theme.accent
    }

    private var surfaceTint: Color? {
        if isFailure {
            return Theme.warning
        }
        if isProminent {
            return Theme.accent
        }
        return nil
    }

    private var label: AnyShapeStyle {
        if isFailure {
            return AnyShapeStyle(Theme.warning)
        }
        if isBusy {
            return AnyShapeStyle(.secondary)
        }
        return AnyShapeStyle(.primary)
    }

    private var title: String {
        switch model.phase {
        case .checking:
            String(localized: "Checking…")
        case .available:
            String(localized: "update.banner.install", defaultValue: "Install")
        case .downloading:
            if model.isProgressKnown {
                String(localized: "update.banner.downloadingShare", defaultValue: "Downloading \(share)")
            } else {
                String(localized: "Downloading…")
            }
        case .extracting:
            if model.isProgressKnown {
                String(localized: "update.banner.preparingShare", defaultValue: "Preparing \(share)")
            } else {
                String(localized: "Preparing…")
            }
        case .readyToInstall:
            String(localized: "update.banner.install", defaultValue: "Install")
        case .installing:
            String(localized: "Installing…")
        case .failed:
            String(localized: "Try Again")
        case .idle, .upToDate:
            String(localized: "Check for Updates")
        }
    }

    private static var everyTitle: [String] {
        [
            String(localized: "Check for Updates"),
            String(localized: "Checking…"),
            String(localized: "update.banner.install", defaultValue: "Install"),
            String(localized: "update.banner.downloadingShare", defaultValue: "Downloading \(share(of: 1))"),
            String(localized: "Downloading…"),
            String(localized: "update.banner.preparingShare", defaultValue: "Preparing \(share(of: 1))"),
            String(localized: "Preparing…"),
            String(localized: "Installing…"),
            String(localized: "Try Again"),
        ]
    }
}

private struct Sweep: View {
    let tint: Color

    @State private var slide = false

    var body: some View {
        GeometryReader { proxy in
            tint.opacity(0.22)
                .frame(width: proxy.size.width * 0.4)
                .offset(x: slide ? proxy.size.width * 0.6 : 0)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                slide = true
            }
        }
    }
}
