// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WSurfCore

extension BrowserModel {
    /// A regular window changed. A private window publishes nothing, not even that it changed.
    func noteCloudTabsChange() {
        guard !opensPrivately else { return }
        CloudTabs.shared?.noteChange()
    }

    /// The window's own folders and tabs, for its iCloud session: no pins (the profile publishes those), no private or extension
    /// pages and no page state. It walks the items the way `snapshot()` does, without its side effects: `snapshot()` bumps
    /// `sessionRevision` and must not be called from here.
    func cloudTabsNodes() -> [SessionNode] {
        guard !opensPrivately, sessionClosedAt == nil else { return [] }
        let tree = reconciledTree()
        let liveTabs = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func nodes(_ parent: UUID?) -> [SessionNode] {
            tree.rows(in: parent).compactMap { item in
                switch item {
                case .tab(let id):
                    guard let tab = liveTabs[id], tab.pinID == nil, !tab.isPrivate, tab.extensionBaseURL == nil else { return nil }
                    return SessionNode.tab(id: tab.id, title: tab.title, url: tab.urlString)
                case .folder(let id):
                    guard !profileFolderIDs.contains(id), let folder = liveFolders[id] else { return nil }
                    return SessionNode(id: id, title: folder.name, children: nodes(id))
                }
            }
        }
        return nodes(nil)
    }
}
