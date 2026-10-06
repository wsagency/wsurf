// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct FolderSection: View {
    let folder: TabFolder
    let depth: Int
    let context: SidebarRowContext

    @State private var isRenaming = false
    @State private var draftName = ""

    @Environment(\.sidebarStyle) private var sidebarStyle
    @Environment(\.windowColorScheme) private var windowColorScheme
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    @State private var windowFrame: CGRect = .zero

    private var browser: BrowserModel {
        context.browser
    }
    private var item: SidebarItem {
        .folder(folder.id)
    }
    private var isSelected: Bool {
        context.isSelected(item)
    }

    static let outlineInset: CGFloat = 2
    static let fillOpacity: Double = 0.08
    static let edgeOpacity: Double = 0.14

    static func outlineRadius(depth: Int) -> CGFloat {
        var radius = Theme.Radius.control
        for _ in 0..<max(depth, 0) {
            radius = Theme.Radius.nested(in: radius, inset: outlineInset)
        }
        return radius
    }

    static func rowRadius(depth: Int) -> CGFloat {
        Theme.Radius.nested(in: outlineRadius(depth: depth), inset: outlineInset)
    }

    private var outlineRadius: CGFloat {
        Self.outlineRadius(depth: depth)
    }

    private var audibleTab: BrowserTab? {
        guard !folder.isExpanded else { return nil }
        return browser.allTabs(in: folder).first { $0.isPlayingAudio }
    }

    @ViewBuilder
    private func countBadge(_ count: Int) -> some View {
        if count == 0 {
            Text("empty")
        } else {
            Text(count, format: .number)
        }
    }

    var body: some View {
        let rows = browser.rows(in: folder)
        let audible = audibleTab
        let showsOutline = folder.isExpanded && !rows.isEmpty
        VStack(spacing: SidebarMetrics.rowVerticalSpacing(settings: context.coordinator.settings)) {
            HStack(spacing: 7) {
                Image(systemName: audible == nil
                    ? (folder.isExpanded ? "folder" : "folder.fill")
                    : "speaker.wave.2.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(folder.color.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(Theme.Motion.settle, value: audible?.id)
                    .help(audible.map { Text("“\($0.title)” is playing") } ?? Text(verbatim: ""))

                if isRenaming && sidebarStyle == .full {
                    renameField
                } else if sidebarStyle == .full {
                    Text(verbatim: folder.name)
                        .font(context.coordinator.settings.sidebarFont)
                        .foregroundStyle(context.coordinator.settings.sidebarTextColor(scheme: colorScheme))
                        .lineLimit(1)
                }

                if sidebarStyle == .full {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 0)

                    if hovering, context.coordinator.linkModifiers.contains(.command), !isRenaming {
                        ChromeIcon.rowControl(
                            symbol: "arrow.uturn.down",
                            help: String(localized: "Unload Folder Tabs"),
                            action: unloadFolderTabs
                        )
                        .frame(width: SidebarMetrics.rowControlExtent)
                        .accessibilityLabel(Text("Unload Folder Tabs"))
                    }

                    countBadge(rows.count)
                        .font(context.coordinator.settings.sidebarFont)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Theme.Wash.hairline, in: Capsule())
                }
            }
            .padding(.horizontal, SidebarMetrics.rowContentPadding(style: sidebarStyle))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SidebarMetrics.rowHeight(settings: context.coordinator.settings))
            .sidebarRowSelectionEffect(
                isSelected: isSelected,
                isHovering: hovering,
                hoverTint: folder.color.tint,
                radius: showsOutline ? Self.rowRadius(depth: depth) : Theme.Radius.hover
            )
            .contentShape(Rectangle())
            .onHover { over in
                hovering = over
                if over {
                    context.coordinator.tabPreview.hover(
                        .folder(folder, browser.tabs(in: folder)),
                        anchor: windowFrame
                    )
                } else {
                    context.coordinator.tabPreview.unhover(folder.id)
                }
            }
            .onDisappear { context.coordinator.tabPreview.unhover(folder.id) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(context.space)) } action: {
                context.frames.record(item, at: $0)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                windowFrame = frame
                context.coordinator.tabPreview.moved(folder.id, anchor: frame)
            }
            .onTapGesture { tapped() }
            .id(item)
            .help(sidebarStyle == .icons ? Text(verbatim: folder.name) : Text(verbatim: ""))
            .popover(isPresented: Binding(
                get: { isRenaming && sidebarStyle == .icons },
                set: { if !$0 { commitRename() } }
            )) {
                renameField
                    .frame(width: 200, height: 24)
                    .padding(12)
            }
            .overlay {
                FolderContextMenuCatcher {
                    FolderContextMenu.make(
                        folder: folder,
                        browser: browser,
                        coordinator: context.coordinator,
                        selected: context.selection.count > 1 && isSelected
                            ? Array(context.selection.items)
                            : [],
                        onRename: beginRename
                    )
                }
            }

            if folder.isExpanded {
                contents
            }
        }
        .padding(showsOutline ? Self.outlineInset : 0)
        .background {
            if showsOutline {
                let shape = RoundedRectangle(cornerRadius: outlineRadius, style: .continuous)
                shape
                    .fill(folder.color.tint.opacity(
                        Self.fillOpacity * context.coordinator.settings.sidebarFolderTint
                    ))
                    .overlay {
                        shape.strokeBorder(
                            folder.color.tint.opacity(
                                Self.edgeOpacity * context.coordinator.settings.sidebarFolderTint
                            ),
                            lineWidth: 1
                        )
                    }
                .environment(\.colorScheme, windowColorScheme)
            }
        }
        .opacity(context.isLifted(item) ? 0 : 1)
        .onChange(of: browser.folderRenameID, initial: true) { _, id in
            if id == folder.id && !isRenaming {
                beginRename()
            }
        }
    }

    private var renameField: some View {
        SidebarFolderNameField(
            text: $draftName,
            fontSize: context.coordinator.settings.sidebarFontSize,
            onCommit: commitRename,
            onCancel: cancelRename
        )
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityLabel(Text("Folder name"))
    }

    private var contents: AnyView {
        AnyView(SidebarRows(items: browser.rows(in: folder), depth: depth + 1, context: context))
    }

    private func unloadFolderTabs() {
        context.coordinator.tabPreview.dismiss()
        FolderContextMenu.unloadTabs(
            [.folder(folder.id)],
            coordinator: context.coordinator,
            browser: browser
        )
    }

    private func tapped() {
        guard !isRenaming else { return }
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) {
            context.selection.hold(context.activeItem)
            context.selection.extend(to: item, in: browser.sidebarTree) {
                browser.folder(id: $0)?.isExpanded ?? false
            }
        } else if modifiers.contains(.command) {
            context.selection.hold(context.activeItem)
            context.selection.toggle(item)
        } else {
            context.selection.anchor(on: item)
            withAnimation(Theme.Motion.settle) {
                folder.isExpanded.toggle()
            }
        }
        context.selection.excludeFavorites(browser.favorites)
    }

    private func beginRename() {
        context.coordinator.tabPreview.dismiss()
        context.selection.clear()
        browser.folderRenameID = folder.id
        draftName = folder.name
        isRenaming = true
    }

    private func cancelRename() {
        guard isRenaming else { return }
        isRenaming = false
        browser.finishFolderRename(folder.id)
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        browser.renameFolder(folder, to: draftName)
        browser.finishFolderRename(folder.id)
    }
}

private struct SidebarFolderNameField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = String(localized: "Folder name")
        field.setAccessibilityLabel(String(localized: "Folder name"))
        field.font = .systemFont(ofSize: fontSize)
        field.stringValue = text
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
    }

    final class Field: NSTextField {
        private var requestedFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !requestedFocus else { return }
            requestedFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarFolderNameField

        init(_ parent: SidebarFolderNameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                parent.onCommit()
                return true
            }
            return false
        }
    }
}

@MainActor
enum FolderContextMenu {
    static func make(
        folder: TabFolder,
        browser: BrowserModel,
        coordinator: AppCoordinator,
        selected: [SidebarItem],
        onRename: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if !selected.isEmpty {
            addSelectionItems(selected, to: menu, browser: browser, coordinator: coordinator)
            return menu
        }

        menu.addItem(actionItem(
            title: String(localized: "Rename"),
            symbol: "pencil",
            action: onRename
        ))
        let pinTitle: LocalizedStringResource = folder.isPinned ? "Unpin" : "Pin"
        menu.addItem(actionItem(
            title: String(localized: pinTitle),
            symbol: folder.isPinned ? "pin.slash" : "pin",
            action: { [weak browser, weak folder] in
                guard let browser, let folder else { return }
                if folder.isPinned {
                    browser.unpin(folder)
                } else {
                    browser.pin(folder)
                }
            }
        ))
        menu.addItem(.separator())

        let colors = NSMenuItem()
        colors.view = FolderColorMenuItemView(selected: folder.color) { [weak browser, weak folder] color in
            guard let browser, let folder else { return }
            browser.setFolderColor(color, for: folder)
        }
        menu.addItem(colors)
        menu.addItem(.separator())

        addFolderItems([.folder(folder.id)], to: menu, browser: browser)
        menu.addItem(.separator())

        let kept = browser.allTabs(in: folder).count
        if kept > 0 {
            menu.addItem(removeTabsItem([.folder(folder.id)], count: kept, browser: browser))
            menu.addItem(unloadTabsItem([.folder(folder.id)], count: kept, coordinator: coordinator, browser: browser))
        }
        menu.addItem(actionItem(
            title: String(localized: "Delete Folder…"),
            symbol: "trash",
            action: { [weak browser, weak folder] in
                guard let browser, let folder else { return }
                let kept = browser.allTabs(in: folder).count
                let detail: LocalizedStringResource = switch kept {
                case 0:
                    "The folder is empty."
                default:
                    "Its \(kept) tabs stay in the sidebar."
                }
                Task {
                    guard await ConfirmAlert.destructive(
                        "Delete “\(folder.name)”?",
                        detail: detail,
                        verb: "Delete Folder"
                    ) else { return }
                    browser.deleteFolder(folder)
                }
            }
        ))
        return menu
    }

    private static func addSelectionItems(
        _ selected: [SidebarItem],
        to menu: NSMenu,
        browser: BrowserModel,
        coordinator: AppCoordinator
    ) {
        let linkable = browser.tabs(under: selected).filter { coordinator.linkURL(for: $0) != nil }
        if !linkable.isEmpty {
            let title: LocalizedStringResource = linkable.count == 1 ? "Copy Link" : "Copy Links"
            menu.addItem(actionItem(
                title: String(localized: title),
                symbol: "doc.on.doc",
                action: { [weak coordinator] in coordinator?.copyLinks(for: linkable) }
            ))
            menu.addItem(.separator())
        }

        addFolderItems(selected, to: menu, browser: browser)
        menu.addItem(.separator())

        let count = browser.tabCount(in: selected)
        if count > 0 {
            menu.addItem(removeTabsItem(selected, count: count, browser: browser))
            menu.addItem(unloadTabsItem(selected, count: count, coordinator: coordinator, browser: browser))
        }
    }

    private static func addFolderItems(
        _ items: [SidebarItem],
        to menu: NSMenu,
        browser: BrowserModel
    ) {
        let move = moveMenu(items, browser: browser)
        let moveItem = NSMenuItem(title: String(localized: "Move to Folder"), action: nil, keyEquivalent: "")
        moveItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        moveItem.submenu = move
        menu.addItem(moveItem)

        if items.contains(where: { browser.sidebarTree.parent(of: $0) != nil }) {
            menu.addItem(actionItem(
                title: String(localized: "Remove from Folder"),
                symbol: "folder.badge.minus",
                action: { [weak browser] in browser?.moveOut(items) }
            ))
        }
    }

    static func moveMenu(_ items: [SidebarItem], browser: BrowserModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let targets = SidebarFolderMenuItems.targets(in: nil, for: items, browser: browser)
        addFolderTargets(targets, items: items, to: menu, browser: browser)
        if !targets.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(actionItem(
            title: String(localized: "New Folder…"),
            symbol: "folder.badge.plus",
            action: { [weak browser] in browser?.createFolderForRenaming(containing: items) }
        ))
        return menu
    }

    private static func addFolderTargets(
        _ targets: [TabFolder],
        items: [SidebarItem],
        to menu: NSMenu,
        browser: BrowserModel
    ) {
        for folder in targets {
            let children = SidebarFolderMenuItems.targets(in: folder, for: items, browser: browser)
            let destination = actionItem(
                title: children.isEmpty ? folder.name : String(localized: "Move Here"),
                symbol: "folder",
                action: { [weak browser, weak folder] in
                    guard let browser, let folder else { return }
                    browser.move(items, into: folder)
                }
            )
            if children.isEmpty {
                menu.addItem(destination)
            } else {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                submenu.addItem(destination)
                submenu.addItem(.separator())
                addFolderTargets(children, items: items, to: submenu, browser: browser)
                let branch = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
                branch.image = NSImage(systemSymbolName: "folder", accessibilityDescription: folder.name)
                branch.submenu = submenu
                menu.addItem(branch)
            }
        }
    }

    static func unloadTabs(
        _ items: [SidebarItem],
        coordinator: AppCoordinator,
        browser: BrowserModel
    ) {
        browser.unload(items)
        for tab in browser.tabs(under: items) where tab.isMaterialised {
            coordinator.unloadTab(tab)
        }
    }

    private static func removeTabsItem(
        _ items: [SidebarItem],
        count: Int,
        browser: BrowserModel
    ) -> NSMenuItem {
        actionItem(
            title: String(localized: "Remove \(count) Tabs"),
            symbol: "trash",
            action: { [weak browser] in
                guard let browser else { return }
                Task {
                    guard await ConfirmAlert.destructive(
                        "Remove \(count) tabs?",
                        verb: "Remove Tabs"
                    ) else { return }
                    browser.close(items)
                }
            }
        )
    }

    private static func unloadTabsItem(
        _ items: [SidebarItem],
        count: Int,
        coordinator: AppCoordinator,
        browser: BrowserModel
    ) -> NSMenuItem {
        let item = actionItem(
            title: String(localized: "Unload \(count) Tabs"),
            symbol: "arrow.uturn.down",
            action: { [weak coordinator, weak browser] in
                guard let coordinator, let browser else { return }
                unloadTabs(items, coordinator: coordinator, browser: browser)
            }
        )
        item.isEnabled = browser.tabs(under: items).contains { !$0.isDeferred }
        return item
    }

    private static func actionItem(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let target = FolderMenuAction(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(FolderMenuAction.runFolderMenuAction),
            keyEquivalent: ""
        )
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = target
        item.representedObject = target
        item.isEnabled = true
        return item
    }
}

private final class FolderMenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func runFolderMenuAction() {
        action()
    }
}

struct FolderContextMenuCatcher: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.menuProvider = menu
    }

    final class CatcherView: NSView {
        var menuProvider: (() -> NSMenu)?

        override var mouseDownCanMoveWindow: Bool {
            false
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(convert(point, from: superview)),
                  let event = window?.currentEvent ?? NSApp.currentEvent
            else { return nil }

            if event.type == .rightMouseDown {
                return self
            }
            if event.type == .leftMouseDown, event.modifierFlags.contains(.control) {
                return self
            }
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            presentMenu(for: event)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else { return }
            presentMenu(for: event)
        }

        private func presentMenu(for event: NSEvent) {
            guard let menu = menuProvider?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

private final class FolderColorMenuItemView: NSView {
    private let choose: (TabFolderColor) -> Void

    init(selected: TabFolderColor, choose: @escaping (TabFolderColor) -> Void) {
        self.choose = choose
        super.init(frame: NSRect(x: 0, y: 0, width: 176, height: 30))

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, color) in TabFolderColor.finderPalette.enumerated() {
            let button = NSButton(
                image: color.menuSwatch(isSelected: color == selected),
                target: self,
                action: #selector(selectColor(_:))
            )
            button.tag = index
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.setButtonType(.momentaryChange)
            button.toolTip = String(localized: color.title)
            button.setAccessibilityLabel(String(localized: color.title))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            stack.addArrangedSubview(button)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 176, height: 30)
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard TabFolderColor.finderPalette.indices.contains(sender.tag) else { return }
        choose(TabFolderColor.finderPalette[sender.tag])
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

extension TabFolderColor {
    static let finderPalette: [Self] = [
        .green, .yellow, .red, .blue, .orange, .purple, .gray,
    ]

    var nsTint: NSColor {
        switch self {
        case .gray:
            .systemGray
        case .blue:
            .systemBlue
        case .purple:
            .systemPurple
        case .pink:
            .systemPink
        case .red:
            .systemRed
        case .orange:
            .systemOrange
        case .yellow:
            .systemYellow
        case .green:
            .systemGreen
        case .teal:
            .systemTeal
        }
    }

    var tint: Color {
        Color(nsTint)
    }

    func menuSwatch(isSelected: Bool) -> NSImage {
        let solid = nsTint.usingColorSpace(.sRGB) ?? nsTint
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            solid.withAlphaComponent(0.9).setFill()
            circle.fill()
            solid.withAlphaComponent(0.55).setStroke()
            circle.lineWidth = 1
            circle.stroke()

            if isSelected {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: 3.5, y: 7))
                check.line(to: NSPoint(x: 6, y: 4.5))
                check.line(to: NSPoint(x: 10.5, y: 9.5))
                check.lineWidth = 1.35
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    var title: LocalizedStringResource {
        switch self {
        case .gray:
            "Gray"
        case .blue:
            "Blue"
        case .purple:
            "Purple"
        case .pink:
            "Pink"
        case .red:
            "Red"
        case .orange:
            "Orange"
        case .yellow:
            "Yellow"
        case .green:
            "Green"
        case .teal:
            "Teal"
        }
    }
}
