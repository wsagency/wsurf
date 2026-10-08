// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
enum PageSaving {
    static let archiveType = UTType("com.apple.webarchive") ?? .data
    private static let mhtmlType = UTType(filenameExtension: "mhtml") ?? UTType(importedAs: "org.ietf.mhtml")

    static func begin(for page: BrowserPage) {
        guard let window = page.window, !(page.superview is WebViewParkingShelf), !page.isClosed else { return }

        let panel = NSSavePanel()
        panel.title = String(localized: "Save Page As")
        panel.allowedContentTypes = [page.engine == .webKit ? archiveType : mhtmlType]
        panel.nameFieldStringValue = filename(for: page)
        panel.directoryURL = page.context.settings.downloadFolder
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            write(page, to: url, in: window)
        }
    }

    private static func write(_ page: BrowserPage, to url: URL, in window: NSWindow) {
        Task {
            do {
                guard !page.isClosed else { throw ChromiumError.closed }
                let data: Data
                if let webKit = page.webKit {
                    data = try await withCheckedThrowingContinuation { continuation in
                        webKit.createWebArchiveData { continuation.resume(with: $0) }
                    }
                } else if let chromium = page.chromium {
                    try await chromium.ensureReady()
                    let result = try await chromium.command("Page.captureSnapshot", params: ["format": "mhtml"])
                    guard let archive = result["data"] as? String else {
                        throw ChromiumError.protocolFailure(String(localized: "Chromium did not return a page archive."))
                    }
                    data = Data(archive.utf8)
                } else { throw ChromiumError.closed }
                try data.write(to: url, options: .atomic)
            } catch {
                report(error, in: window)
            }
        }
    }

    private static func report(_ error: any Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The page couldn’t be saved.")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window)
    }

    static func filename(for page: BrowserPage) -> String {
        let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = page.url?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        let stem = title.isEmpty ? host : title
        let safe = DownloadManager.safeFilename(stem.isEmpty ? String(localized: "Untitled") : stem)
        let ext = page.engine == .webKit ? (archiveType.preferredFilenameExtension ?? "webarchive") : "mhtml"
        return "\(safe).\(ext)"
    }
}
