// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI

struct MediaSidebarCard: View {
    let media: MediaCenter
    let coordinator: AppCoordinator
    @Binding var obscuredHeight: CGFloat

    private var goToSource: (() -> Void)? {
        guard let tabID = media.controlledTabID,
              let tab = coordinator.browser.tabs.first(where: { $0.id == tabID })
        else { return nil }
        return { coordinator.openTab(tab) }
    }

    private var playerVisibilityHelp: LocalizedStringResource {
        isPlayerHidden ? "Show Video" : "Hide Video"
    }

    private var showsLyricsButton: Bool {
        coordinator.showsLyrics && !coordinator.sidePanel.isShowing(.lyrics)
    }

    private var pipHelp: LocalizedStringResource {
        media.nativePiPUnavailableReason
            ?? (media.model.isInNativePiP ? "Exit Picture in Picture" : "Picture in Picture")
    }

    private var titleFont: Font {
        .system(size: 11, weight: .medium)
    }

    @ViewBuilder
    private func pickerRow(_ tab: BrowserTab, isDocked: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { isDocked },
            set: { isOn in
                guard isOn else { return }
                coordinator.dockMedia(tab)
            }
        )) {
            Text(verbatim: tab.title)
        }
    }

    private var hasPicker: Bool {
        coordinator.mediaPickerTabs.count > 1
    }

    private var titleWidth: CGFloat {
        max(40, Self.controlsWidth(panelWidth: panelWidth))
    }

    private var title: some View {
        Text(verbatim: media.model.title)
            .font(titleFont)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.secondary)
            .frame(width: titleWidth, alignment: .leading)
            .mask(alignment: .leading) { titleMask }
    }

    @ViewBuilder private var pickerButton: some View {
        let items = coordinator.mediaPickerTabs
        if items.count > 1 {
            let docked = media.controlledTabID
            let playing = items.filter { $0.isPlayingAudio || $0.id == docked }
            let quiet = items.filter { !($0.isPlayingAudio || $0.id == docked) }
            Menu {
                ForEach(playing) { tab in
                    pickerRow(tab, isDocked: docked == tab.id)
                }
                if !quiet.isEmpty {
                    Divider()
                    ForEach(quiet) { tab in
                        pickerRow(tab, isDocked: docked == tab.id)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 14, height: 14)
            .help("Choose Which Tab to Control")
        }
    }

    @Environment(\.sidebarStyle) private var sidebarStyle
    @Environment(\.sidebarWidth) private var sidebarWidth
    @Environment(\.sidebarIsFloating) private var sidebarIsFloating
    @Environment(\.sidebarIsClipped) private var sidebarIsClipped
    @State private var showsControls = false

    @State private var controlsWidth: CGFloat = 0

    @State private var isPulledOut = false

    @State private var isPlayerHidden = false

    @State private var panelFrame: CGRect = .zero

    @State private var buttonFrame: CGRect = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The panel's own size, so a drop can tell which corner it is nearest.
    @State private var panelSize: CGSize = .zero

    /// How far the pointer has carried the panel since it was picked up, while it is.
    @State private var carried: CGSize?

    private var isStowed: Bool {
        sidebarStyle != .full
    }

    /// The player moves while the video experiment is on. Without it the panel stays docked, and so it does in a sidebar
    /// clipped to its shape (the Minimal window's tab list): there a panel moved over the page is drawn nowhere, yet it
    /// still takes the page's clicks and hover in its corner, because a clip does not limit hit testing.
    private var isMovable: Bool {
        coordinator.settings.showsVideoInPlayer && !sidebarIsClipped
    }

    private var corner: MediaPlayerCorner {
        isMovable ? coordinator.settings.mediaPlayerCorner : .dock
    }

    /// The panel has left the dock and rests over the page. It then neither covers the sidebar nor hides behind the
    /// stowed button, and it stays where it is when the sidebar goes away.
    private var isUndocked: Bool {
        corner != .dock
    }

    private var snap: Animation? {
        reduceMotion ? nil : Theme.Motion.settle
    }

    private var page: CGRect {
        coordinator.sidebarDrag.contentFrameInWindow
    }

    private var window: CGRect {
        coordinator.shellFrameInWindow
    }

    private var hasMeasured: Bool {
        panelSize.width > 0 && buttonFrame.width > 0 && page.width > 0 && window.width > 0
    }

    /// Where the sidebar's layout puts the panel before any offset: against the left of the dock's anchor, resting on its
    /// bottom. The anchor is the stowed button or, in the full sidebar, a point above the profile row.
    private var naturalOrigin: CGPoint {
        CGPoint(x: buttonFrame.minX, y: buttonFrame.maxY - panelSize.height)
    }

    /// The stowed panel stands above its button.
    private var stowedOffset: CGFloat {
        isStowed ? -(Self.buttonHeight + 6) : 0
    }

    /// Where the top left of the panel rests in `corner`, in window coordinates. The dock is where the sidebar puts it.
    private func restingOrigin(of corner: MediaPlayerCorner) -> CGPoint {
        guard corner != .dock else {
            return CGPoint(x: naturalOrigin.x, y: naturalOrigin.y + stowedOffset)
        }
        return MediaPlayerPlacement.origin(of: corner, size: panelSize, page: page, window: window)
    }

    /// How far the panel sits from where the sidebar's layout would put it. Docked and still, that is only the stowed
    /// offset, with no measurement to go wrong.
    private var displacement: CGSize {
        guard isUndocked || carried != nil, hasMeasured else {
            return CGSize(width: 0, height: isUndocked ? 0 : stowedOffset)
        }
        var origin = restingOrigin(of: corner)
        if let carried {
            origin = MediaPlayerPlacement.clamped(
                CGPoint(x: origin.x + carried.width, y: origin.y + carried.height),
                size: panelSize,
                within: window
            )
        }
        return CGSize(width: origin.x - naturalOrigin.x, height: origin.y - naturalOrigin.y)
    }

    private var carry: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { carried = $0.translation }
            .onEnded { drop(after: $0.translation) }
    }

    /// Lets go of the panel in the corner it is nearest, wherever it was left.
    private func drop(after translation: CGSize) {
        let start = restingOrigin(of: corner)
        let released = MediaPlayerPlacement.clamped(
            CGPoint(x: start.x + translation.width, y: start.y + translation.height),
            size: panelSize,
            within: window
        )
        let target = MediaPlayerPlacement.nearestCorner(to: released) { restingOrigin(of: $0) }
        withAnimation(snap) {
            carried = nil
            coordinator.movePlayer(to: target)
        }
    }

    @ViewBuilder private var cornerChoices: some View {
        ForEach(MediaPlayerCorner.allCases, id: \.self) { target in
            Toggle(isOn: Binding(
                get: { corner == target },
                set: { _ in coordinator.movePlayer(to: target) }
            )) {
                Text(target.title)
            }
        }
    }

    private var isCompact: Bool {
        Self.isCompact(panelWidth: panelWidth)
    }

    nonisolated static let widthForRoomyControls: CGFloat = 210

    nonisolated static func isCompact(panelWidth: CGFloat) -> Bool {
        panelWidth < widthForRoomyControls
    }

    nonisolated static func panelWidth(
        sidebarWidth: CGFloat,
        isStowed: Bool,
        isFloating: Bool,
        margin: CGFloat = LoomChrome.canvasInset,
        pageSpacing: CGFloat = LoomChrome.canvasInset
    ) -> CGFloat {
        guard !isStowed else { return floatingWidth }
        let room = SidebarMetrics.contentWidth(
            sidebarWidth, style: .full, isFloating: isFloating, margin: margin, pageSpacing: pageSpacing
        )
        return max(room, 150)
    }

    nonisolated static func controlsWidth(panelWidth: CGFloat) -> CGFloat {
        panelWidth - 2 * controlsInset(panelWidth: panelWidth)
    }

    nonisolated static func controlsInset(panelWidth: CGFloat) -> CGFloat {
        isCompact(panelWidth: panelWidth) ? 8 : 10
    }

    private nonisolated static let controlGap: CGFloat = 4

    private var titleMask: some View {
        let covered = showsControls ? controlsWidth : 0
        return HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: covered > 0 ? 18 : 0)
            Color.clear
                .frame(width: covered)
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: Self.controlGap) {
            pickerButton

            if showsLyricsButton {
                MediaButton(systemName: "quote.bubble", size: 9, help: "Show Lyrics") {
                    coordinator.toggleLyrics()
                }
            }

            if media.model.picturePage != nil, !media.model.isInNativePiP {
                MediaButton(
                    systemName: isPlayerHidden ? "eye.slash" : "eye",
                    size: 9,
                    help: playerVisibilityHelp
                ) {
                    isPlayerHidden.toggle()
                }
            }

            if media.model.hasVideo {
                MediaButton(
                    systemName: media.model.isInNativePiP ? "pip.exit" : "pip.enter",
                    size: 9,
                    help: pipHelp
                ) {
                    media.toggleNativePiP()
                }
                .disabled(!media.canToggleNativePiP)
            }

            if let goToSource {
                MediaButton(
                    systemName: "arrow.up.right",
                    size: 9,
                    help: "Go to the Tab Playing This",
                    action: goToSource
                )
            }

            MediaButton(systemName: "xmark", size: 9, help: "Pause and Close") {
                media.close()
            }
        }
    }

    private var showsPlayer: Bool {
        !isStowed || isPulledOut || isUndocked
    }
    private var showsVideo: Bool {
        showsPlayer && !isPlayerHidden && !media.model.isInNativePiP
    }

    nonisolated static let floatingWidth: CGFloat = 300
    private nonisolated static let buttonHeight: CGFloat = 26

    var body: some View {
        inFlow
            .frame(maxWidth: .infinity, alignment: sidebarStyle == .full ? .leading : .center)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buttonFrame = $0 }
            .overlay(alignment: .bottomLeading) { panel }
            .padding(.top, isUndocked ? 0 : 4)
            .background {
                ClickOutsideCatcher(isActive: isStowed && isPulledOut && !isUndocked, keepingOut: [panelFrame, buttonFrame]) {
                    isPulledOut = false
                }
                .allowsHitTesting(false)
            }
            .onChange(of: isStowed) { _, stowed in
                if !stowed {
                    isPulledOut = false
                }
            }
            .onChange(of: isUndocked) { _, undocked in
                if !undocked, isStowed {
                    isPulledOut = true
                }
            }
            .animation(nil, value: panelWidth)
            .animation(Theme.Motion.settle, value: showsPlayer)
            .animation(Theme.Motion.settle, value: isStowed)
    }

    @ViewBuilder
    private var inFlow: some View {
        if isStowed, !isUndocked {
            stowedButton
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let picture = media.model.picturePage, let crop = media.pictureCrop {
                MediaPlayerSurface(
                    media: media,
                    page: picture,
                    crop: crop,
                    width: panelWidth,
                    cornerRadius: Theme.Radius.control,
                    isStowed: !showsVideo
                )
                .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
                .padding(.bottom, showsVideo ? 6 : 0)
            }

            if showsPlayer {
                VStack(alignment: .leading, spacing: 6) {
                    title
                        .overlay(alignment: .trailing) {
                            controls
                                .onGeometryChange(for: CGFloat.self) { $0.size.width }
                                    action: { controlsWidth = $0 }
                                .opacity(showsControls ? 1 : 0)
                                .allowsHitTesting(showsControls)
                        }
                        .animation(Theme.Motion.quick, value: showsControls)

                    MediaTimeline(media: media, isCompact: true)
                    MediaTransport(media: media, isCompact: isCompact)
                }
                .padding(.horizontal, Self.controlsInset(panelWidth: panelWidth))
                .padding(.vertical, 8)
                .onHover { showsControls = $0 }
                .chromeGlass(in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
                .contentShape(.rect(cornerRadius: Theme.Radius.card, style: .continuous))
                .transition(.opacity)
            }
        }
        .frame(width: panelWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Media player"))
        .accessibilityActions {
            if isMovable {
                ForEach(MediaPlayerCorner.allCases, id: \.self) { target in
                    Button {
                        coordinator.movePlayer(to: target)
                    } label: {
                        Text(target.moveTitle)
                    }
                }
            }
        }
        .contextMenu {
            if isMovable {
                Menu {
                    cornerChoices
                } label: {
                    Text("Move Player to Corner")
                }
            }
        }
        .gesture(carry, including: isMovable ? .all : .subviews)
        // The whole frame, gaps included, takes the pointer: the page below hears neither hover nor clicks there.
        // The controls keep working: parking only unregisters the page's tracking areas.
        .contentShape(.rect)
        .onHover { media.isPointerOverPlayer = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
        .offset(displacement)
        .opacity(isUndocked && !hasMeasured ? 0 : 1)
        .animation(snap, value: corner)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
        .onGeometryChange(for: CGFloat.self) { [isStowed, showsPlayer, isUndocked] proxy in
            guard !isUndocked else { return 0 }
            let panelHeight = proxy.size.height
            if isStowed {
                return showsPlayer
                    ? panelHeight + Self.buttonHeight + 10
                    : Self.buttonHeight + 8
            }
            return panelHeight + 8
        } action: { obscuredHeight = $0 }
        .onDisappear {
            obscuredHeight = 0
            media.isPointerOverPlayer = false
        }
    }

    private var panelWidth: CGFloat {
        let shape = BrowserSettings.application.chromeShape
        return Self.panelWidth(
            sidebarWidth: sidebarWidth, isStowed: isStowed, isFloating: sidebarIsFloating,
            margin: shape.sidebarMargin, pageSpacing: shape.pageSpacing
        )
    }

    private var stowedButton: some View {
        Button {
            isPulledOut.toggle()
        } label: {
            Image(systemName: media.model.isPlaying ? "waveform" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPulledOut ? Theme.accent : Color.secondary)
        .chromeGlass(in: .capsule)
        .help(isPulledOut ? Text("Hide Player") : Text(verbatim: media.model.title))
    }
}

private struct ClickOutsideCatcher: NSViewRepresentable {
    let isActive: Bool
    let keepingOut: [CGRect]
    let onClickOutside: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: Catcher, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: Catcher, coordinator: ()) {
        nsView.stop()
    }

    private func apply(to view: Catcher) {
        view.keepingOut = keepingOut
        view.onClickOutside = onClickOutside
        view.isActive = isActive
    }

    final class Catcher: NSView {
        var keepingOut: [CGRect] = []
        var onClickOutside: (() -> Void)?

        var isActive = false {
            didSet {
                guard isActive != oldValue else { return }
                if isActive {
                    start()
                } else {
                    stop()
                }
            }
        }

        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
                return event
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, let content = window.contentView else { return }
            let inContent = content.convert(event.locationInWindow, from: nil)
            let point = content.isFlipped
                ? inContent
                : CGPoint(x: inContent.x, y: content.bounds.height - inContent.y)
            guard !keepingOut.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) else { return }
            onClickOutside?()
        }
    }
}
