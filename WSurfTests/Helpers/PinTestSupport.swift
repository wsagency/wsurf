// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import WSurf

extension BrowserModel {
    /// An unloaded page, like a tab restored from a session: it shows `address` and loads nothing.
    @discardableResult
    func addPage(_ address: String) -> BrowserTab {
        let url = URL(string: address)
        let tab = makeTab(for: url, restoring: true)
        tab.urlString = address
        tab.pageTitle = address
        tab.deferRestore(state: nil, url: url)
        tabs.append(tab)
        sidebarDidChange()
        return tab
    }

    @discardableResult
    func pinned(_ address: String) -> BrowserTab {
        let tab = addPage(address)
        pin(tab)
        return tab
    }

    func page(for pinID: UUID?) -> BrowserTab? {
        pinID.flatMap { id in tabs.first { $0.pinID == id } }
    }

    func page(at address: String) -> BrowserTab? {
        tabs.first { $0.urlString == address }
    }

    /// The kept items of the sidebar as text: Favorites marked, folders as `Name[children]`.
    var pinOutline: String {
        outline(in: nil)
    }

    private func outline(in parent: UUID?) -> String {
        sidebarTree.rows(in: parent)
            .filter { parent != nil || isKept($0) }
            .map { item -> String in
                switch item {
                case .tab(let id):
                    let page = tab(id: id)
                    return (page?.isFavorite == true ? "★" : "") + (page?.urlString ?? "?")
                case .folder(let id):
                    return "\(folder(id: id)?.name ?? "?")[\(outline(in: id))]"
                }
            }
            .joined(separator: " ")
    }
}
