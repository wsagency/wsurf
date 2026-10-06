// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

struct SidebarLinkMenuItems: View {
    let tabs: [BrowserTab]
    let coordinator: AppCoordinator

    private var linkable: [BrowserTab] {
        tabs.filter { coordinator.linkURL(for: $0) != nil }
    }

    var body: some View {
        if !linkable.isEmpty {
            Button {
                coordinator.copyLinks(for: linkable)
            } label: {
                if linkable.count == 1 {
                    Label("Copy Link", systemImage: "doc.on.doc")
                } else {
                    Label("Copy Links", systemImage: "doc.on.doc")
                }
            }
            Divider()
        }
    }
}

struct SidebarPinMenuItems: View {
    let tab: BrowserTab
    let browser: BrowserModel

    var body: some View {
        if tab.pinnedURL == nil {
            Button {
                browser.pin(tab)
            } label: {
                Label("Pin This Page", systemImage: "pin")
            }
            .disabled(tab.urlString.isEmpty)
        } else {
            if tab.isAwayFromPin {
                Button {
                    browser.returnToPin(tab)
                } label: {
                    Label("Back to Pinned Page", systemImage: "arrow.uturn.backward")
                }
            }
            Menu {
                Button {
                    browser.pin(tab)
                } label: {
                    Label("Move Pin to This Page", systemImage: "pin")
                }
                .disabled(!tab.isAwayFromPin)

                Button {
                    PinEditor.edit(tab, in: browser)
                } label: {
                    Label("Edit…", systemImage: "pencil")
                }
            } label: {
                Label("Edit Pinned Page", systemImage: "pin.circle")
            }
        }
        Divider()
    }
}

struct SidebarFavoriteMenuItems: View {
    let tabs: [BrowserTab]
    let browser: BrowserModel

    var body: some View {
        if tabs.contains(where: { !$0.isFavorite }) {
            Button {
                for tab in tabs where !tab.isFavorite {
                    browser.addFavorite(tab)
                }
            } label: {
                Label("Add Favorite", systemImage: "star")
            }
            .disabled(tabs.allSatisfy { $0.urlString.isEmpty && $0.pinnedURL == nil })
        }
        if tabs.contains(where: \.isFavorite) {
            Button {
                for tab in tabs where tab.isFavorite {
                    browser.removeFavorite(tab)
                }
            } label: {
                Label("Remove Favorite", systemImage: "star.slash")
            }
        }
        Divider()
    }
}

struct SidebarUnpinButton: View {
    let tab: BrowserTab
    let browser: BrowserModel

    var body: some View {
        Button {
            browser.unpin(tab)
        } label: {
            Label("Unpin Tab", systemImage: "pin.slash")
        }
    }
}

struct SidebarAudioMenuItems: View {
    let tab: BrowserTab
    let coordinator: AppCoordinator

    var body: some View {
        Button {
            coordinator.toggleMute(tab: tab)
        } label: {
            if tab.isMuted {
                Label("Unmute Tab", systemImage: "speaker.wave.2")
            } else {
                Label("Mute Tab", systemImage: "speaker.slash")
            }
        }
        Divider()
    }
}

struct SidebarFolderMenuItems: View {
    let items: [SidebarItem]
    let browser: BrowserModel

    private var isFiled: Bool {
        items.contains { browser.sidebarTree.parent(of: $0) != nil }
    }

    static func targets(in parent: TabFolder?, for items: [SidebarItem], browser: BrowserModel) -> [TabFolder] {
        browser.rows(in: parent).compactMap { item in
            guard case .folder(let id) = item, browser.sidebarTree.canHold(id, items) else { return nil }
            return browser.folder(id: id)
        }
    }

    var body: some View {
        let targets = Self.targets(in: nil, for: items, browser: browser)
        Menu {
            SidebarFolderTargetMenuItems(targets: targets, items: items, browser: browser)
            if !targets.isEmpty {
                Divider()
            }
            Button {
                browser.createFolderForRenaming(containing: items)
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
        if isFiled {
            Button {
                browser.moveOut(items)
            } label: {
                Label("Remove from Folder", systemImage: "folder.badge.minus")
            }
        }
        Divider()
    }
}

private struct SidebarFolderTargetMenuItems: View {
    let targets: [TabFolder]
    let items: [SidebarItem]
    let browser: BrowserModel

    var body: some View {
        ForEach(targets) { folder in
            let children = SidebarFolderMenuItems.targets(in: folder, for: items, browser: browser)
            if children.isEmpty {
                Button {
                    browser.move(items, into: folder)
                } label: {
                    Text(verbatim: folder.name)
                }
            } else {
                Menu {
                    Button {
                        browser.move(items, into: folder)
                    } label: {
                        Label("Move Here", systemImage: "folder")
                    }
                    Divider()
                    AnyView(SidebarFolderTargetMenuItems(targets: children, items: items, browser: browser))
                } label: {
                    Text(verbatim: folder.name)
                }
            }
        }
    }
}

struct SidebarSelectionMenuItems: View {
    let items: [SidebarItem]
    let browser: BrowserModel
    let coordinator: AppCoordinator

    private var tabs: [BrowserTab] {
        browser.tabs(under: items)
    }

    var body: some View {
        SidebarLinkMenuItems(tabs: tabs, coordinator: coordinator)
        SidebarFavoriteMenuItems(tabs: tabs, browser: browser)
        SidebarFolderMenuItems(items: items, browser: browser)
        SidebarTabActions(items: items, browser: browser, coordinator: coordinator)
    }
}

struct SidebarTabActions: View {
    let items: [SidebarItem]
    let browser: BrowserModel
    let coordinator: AppCoordinator

    private var tabs: [BrowserTab] {
        browser.tabs(under: items)
    }

    var body: some View {
        let count = tabs.count
        let loadedCount = tabs.filter { !$0.isDeferred }.count
        let unloadLabel = count == 1 ? String(localized: "Unload Tab") : String(localized: "Unload \(count) Tabs")
        let removeLabel = count == 1 ? String(localized: "Remove Tab") : String(localized: "Remove \(count) Tabs")
        Button {
            let selected = tabs
            browser.unload(items)
            for tab in selected where tab.isMaterialised {
                coordinator.unloadTab(tab)
            }
        } label: {
            Label(unloadLabel, systemImage: "arrow.uturn.down")
        }
        .disabled(loadedCount == 0)

        Button(role: .destructive) {
            Task {
                guard await ConfirmAlert.destructive(
                    "Remove \(count) tabs?",
                    verb: "Remove Tabs"
                ) else { return }
                browser.close(items)
            }
        } label: {
            Label(removeLabel, systemImage: "xmark")
        }
        .disabled(count == 0)
    }
}
