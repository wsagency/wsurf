// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import QuickLookUI

/// The system Quick Look panel for finished downloads: the same window, keys and file types as in the Finder.
/// The panel keeps its data source without owning it, so there is one long-lived presenter.
final class DownloadPreview: NSObject, QLPreviewPanelDataSource {
    static let shared = DownloadPreview()

    private var files: [URL] = []

    /// Shows `current` with the other `files` a swipe or arrow key away. Shows nothing for a file that is not in `files`.
    func show(_ files: [URL], current: URL) {
        guard let index = files.firstIndex(of: current), let panel = QLPreviewPanel.shared() else { return }
        self.files = files
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
    }

    /// Space on the file that is already showing closes the panel, as in the Finder.
    func toggle(_ files: [URL], current: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, panel.dataSource === self, self.files.indices.contains(panel.currentPreviewItemIndex),
           self.files[panel.currentPreviewItemIndex] == current {
            panel.orderOut(nil)
        } else {
            show(files, current: current)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        files.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        files[index] as NSURL
    }
}
