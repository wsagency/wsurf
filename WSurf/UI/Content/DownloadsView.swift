// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
    let browser: BrowserModel

    @State private var confirmingClear = false
    @State private var selection: UUID?
    @FocusState private var listFocused: Bool

    private var downloads: DownloadManager {
        browser.downloads
    }

    private var finishedCount: Int {
        downloads.items.count { !$0.isRunning }
    }

    var body: some View {
        DestinationPage {
            toolbar
        } content: {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 2) {
                    if downloads.items.isEmpty {
                        Text("No recent downloads.")
                            .font(Theme.Font.row)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 28)
                    } else {
                        ForEach(downloads.items) { item in
                            DownloadFileRow(
                                item: item,
                                downloads: downloads,
                                browser: browser,
                                isSelected: selection == item.id,
                                onSelect: {
                                    selection = item.id
                                    listFocused = true
                                },
                                onPreview: {
                                    selection = item.id
                                    preview(item, toggling: false)
                                }
                            )
                            .equatable()
                        }
                    }
                }
                // Arrow keys move the selection and Space previews it, as in the Finder.
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(-1, proxy) }
                .onKeyPress(.downArrow) { move(1, proxy) }
                .onKeyPress(.space) {
                    guard let item = downloads.items.first(where: { $0.id == selection }),
                          item.availableFile != nil
                    else { return .ignored }
                    preview(item, toggling: true)
                    return .handled
                }
            }
        }
    }

    private func move(_ offset: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = downloads.items
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : items.count)
        let next = min(max(current + offset, 0), items.count - 1)
        selection = items[next].id
        proxy.scrollTo(items[next].id)
        return .handled
    }

    /// Quick Look lets the arrow keys step through every finished download that is still on disk, starting here.
    private func preview(_ item: DownloadManager.Item, toggling: Bool) {
        guard let file = item.availableFile else { return }
        let files = downloads.items.compactMap(\.availableFile)
        if toggling {
            DownloadPreview.shared.toggle(files, current: file)
        } else {
            DownloadPreview.shared.show(files, current: file)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            DestinationTitle(title: "Downloads") {
                browser.dismissInternalPage(.downloads)
            }

            if !downloads.items.isEmpty {
                DestinationCount(count: downloads.items.count)
            }

            Spacer(minLength: 12)

            ToolbarChip(symbol: "folder", label: "Open in Finder") {
                NSWorkspace.shared.open(BrowserSettings.application.downloadFolder)
            }

            ToolbarChip(symbol: "trash", label: "Clear", isDestructive: true) {
                confirmingClear = true
            }
            .disabled(finishedCount == 0)
            .confirmationDialog(
                "Clear the download list?",
                isPresented: $confirmingClear
            ) {
                Button("Clear List", role: .destructive) { downloads.clearFinished() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(finishedCount) downloads will be removed from the list. The files stay in your Downloads folder.")
            }
        }
    }
}

/// Equatable on what the row shows, not on its two actions: they act on the item, so while the item is unchanged they cannot differ.
/// One download's progress then redraws that row, not every row of the list.
private struct DownloadFileRow: View, Equatable {
    let item: DownloadManager.Item
    let downloads: DownloadManager
    let browser: BrowserModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void

    static func == (lhs: DownloadFileRow, rhs: DownloadFileRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
            && lhs.downloads === rhs.downloads && lhs.browser === rhs.browser
    }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: hovering && item.state == .finished ? "arrow.up.forward.app" : item.listSymbol)
                .font(.system(size: 14))
                .foregroundStyle(item.state == .finished ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .transaction { $0.animation = nil }
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.filename)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                subtitle
                    .font(Theme.Font.label)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isRunning {
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 90)
                } else {
                    Spinner(size: 12)
                        .foregroundStyle(.secondary)
                }
                ChromeIcon.rowControl(symbol: "xmark", help: String(localized: "Stop")) {
                    downloads.cancel(item)
                }
            } else {
                if downloads.canResume(item) {
                    ChromeIcon.rowControl(
                        symbol: "arrow.clockwise",
                        help: String(localized: "Resume")
                    ) {
                        downloads.resume(item)
                    }
                }

                if hovering {
                    if item.state == .finished {
                        if item.availableFile != nil {
                            ChromeIcon.rowControl(
                                symbol: "eye",
                                help: String(localized: "Preview File"),
                                action: onPreview
                            )
                            .accessibilityLabel("Preview File")
                        }
                        ChromeIcon.rowControl(
                            symbol: "folder",
                            help: String(localized: "Show in Finder")
                        ) {
                            downloads.revealInFinder(item)
                        }
                        .accessibilityLabel("Show in Finder")
                    }

                    CloseButton(help: String(localized: "Remove from List")) {
                        downloads.remove(item)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverBackground(
            isActive: hovering || isSelected,
            in: RoundedRectangle(cornerRadius: Theme.Radius.hover, style: .continuous)
        )
        .contentShape(Rectangle())
        .help(item.stoppedReason ?? "")
        .onHover { hovering = $0 }
        .animation(Theme.Motion.quick, value: hovering)
        .onTapGesture {
            onSelect()
            guard item.state == .finished else { return }
            downloads.open(item)
        }
        .contextMenu {
            DownloadRowMenu(item: item, downloads: downloads, browser: browser, onPreview: onPreview)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            if item.state == .finished {
                Button("Preview File", action: onPreview)
                Button("Open") { downloads.open(item) }
                if let destination = item.destination, DownloadWorkspace.rendersInBrowser(destination) {
                    Button("Open in WSurf") { browser.openDownloadInTab(item) }
                }
                Button("Show in Finder") { downloads.revealInFinder(item) }
            }
        }
    }

    private var subtitle: Text {
        switch item.state {
        case .failed(let why):
            Text(verbatim: why)
        case .cancelled:
            Text("Canceled")
        case .running, .finished, .interrupted:
            if item.source.isEmpty {
                Text(verbatim: item.sizeSummary)
            } else {
                Text("\(item.sizeSummary) · from \(item.source)")
            }
        }
    }
}

extension DownloadManager.Item {
    /// The symbol a download wears in a list: what it is doing, or once finished, what kind of file it is.
    var listSymbol: String {
        switch state {
        case .running:
            "arrow.down"
        case .finished:
            Self.symbol(forFilename: filename)
        case .interrupted:
            "pause.circle"
        case .failed:
            "exclamationmark.triangle"
        case .cancelled:
            "slash.circle"
        }
    }

    /// The first entry the file's type conforms to wins, so specific types come before the general ones they refine.
    private static let fileKindSymbols: [(UTType, String)] = [
        (.pdf, "doc.richtext"),
        (.image, "photo"),
        (.movie, "film"),
        (.audio, "music.note"),
        (.diskImage, "externaldrive"),
        (.archive, "doc.zipper"),
        (.application, "app"),
        (.applicationBundle, "app"),
        (.presentation, "rectangle.on.rectangle"),
        (.spreadsheet, "tablecells"),
        (.font, "textformat"),
        (.sourceCode, "chevron.left.forwardslash.chevron.right"),
        (.html, "globe"),
        (.text, "doc.text"),
    ]

    static func symbol(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return "doc" }
        return fileKindSymbols.first { type.conforms(to: $0.0) }?.1 ?? "doc"
    }
}

/// The right-click menu of a finished download. The file and the apps that can open it are looked up when the
/// menu is drawn, not while the list is, so a long list does no work until a row is clicked.
private struct DownloadRowMenu: View {
    let item: DownloadManager.Item
    let downloads: DownloadManager
    let browser: BrowserModel
    let onPreview: () -> Void

    var workspace = DownloadWorkspace.system

    var body: some View {
        if let file = item.availableFile {
            Button("Preview File", action: onPreview)
            Button("Open") { downloads.open(item) }
            let apps = workspace.applications(toOpen: file)
            if !apps.isEmpty {
                Menu("Open With") {
                    ForEach(apps) { app in
                        Button {
                            workspace.open(file, app.url)
                        } label: {
                            if app.isDefault {
                                Text("\(app.name) (default)")
                            } else {
                                Text(verbatim: app.name)
                            }
                        }
                    }
                }
            }
            if item.browserFile != nil {
                Button("Open in WSurf") { browser.openDownloadInTab(item) }
            }
            Divider()
            Button("Show in Finder") { downloads.revealInFinder(item) }
        }
    }
}
