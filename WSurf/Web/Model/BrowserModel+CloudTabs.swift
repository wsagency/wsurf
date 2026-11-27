// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension BrowserModel {
    /// A regular window changed. A private or agent micro window publishes nothing, not even that it changed.
    func noteCloudTabsChange() {
        guard !opensPrivately, !isAgentMicro else { return }
        CloudTabs.shared?.noteChange()
    }

    /// The window's own folders and tabs, for its iCloud session: no pins (the profile publishes those), no private or extension
    /// pages and no page state. It walks the items the way `snapshot()` does, without its side effects: `snapshot()` bumps
    /// `sessionRevision` and must not be called from here.
    /// `includingSpaceRows` false leaves out the shared Space rows, which another window of the profile reports.
    func cloudTabsNodes(includingSpaceRows: Bool = true) -> [SessionNode] {
        guard !opensPrivately, !isAgentMicro, sessionClosedAt == nil else { return [] }
        let tree = reconciledTree()
        let liveTabs = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func nodes(_ parent: UUID?) -> [SessionNode] {
            tree.rows(in: parent).compactMap { item in
                switch item {
                case .tab(let id):
                    // A row standing for a page in a micro window is not a page here; the micro window reports the page.
                    guard let tab = liveTabs[id], tab.pinID == nil, tab.microTabID == nil, !tab.isPrivate, tab.extensionBaseURL == nil,
                          !tab.isProvisionalDownloadPopup,
                          includingSpaceRows || tab.spaceTabID == nil
                    else { return nil }
                    return SessionNode.tab(id: tab.id, title: tab.title, url: tab.urlString)
                case .folder(let id):
                    guard !profileFolderIDs.contains(id), let folder = liveFolders[id] else { return nil }
                    guard includingSpaceRows || !spaceFolderIDs.contains(id) else { return nil }
                    return SessionNode(id: id, title: folder.name, children: nodes(id))
                }
            }
        }
        return nodes(nil)
    }
}
