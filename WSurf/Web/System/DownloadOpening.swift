// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import os
import UniformTypeIdentifiers

/// What the Downloads list asks of the system to open a finished file, as closures so a test can stand in for
/// `NSWorkspace`. Nothing here touches the file's quarantine flag: an app that opens a download goes through
/// Gatekeeper exactly as it does from the Finder.
struct DownloadWorkspace {
    var urlsForApplications: (_ file: URL) -> [URL]
    var urlForApplication: (_ file: URL) -> URL?
    var open: (_ file: URL, _ application: URL) -> Void
    /// WSurf's own bundle. "Open in WSurf" is the way into WSurf, so it is left out of Open With.
    var ownApplication = Bundle.main.bundleURL

    static let system = DownloadWorkspace(
        urlsForApplications: { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
        urlForApplication: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        open: { file, application in
            NSWorkspace.shared.open(
                [file], withApplicationAt: application,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                // The message can quote the file's name, so only the domain and code are logged.
                guard let error = error as NSError? else { return }
                Pipeline.log.error("downloads: open with failed domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
            }
        }
    )

    /// The apps that can open `file`, the default one first and the rest by name.
    func applications(toOpen file: URL) -> [DownloadApp] {
        let preferred = urlForApplication(file)?.path
        return urlsForApplications(file)
            .filter { $0.path != ownApplication.path }
            .map { DownloadApp(url: $0, isDefault: $0.path == preferred) }
            .sorted {
                $0.isDefault != $1.isDefault
                    ? $0.isDefault
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Types WSurf's tabs show instead of handing off. Each is a type both engines render from a `file:` URL and
    /// that runs no script of its own. HTML and SVG are left out on purpose: a downloaded page would run its own
    /// script (it could not read its neighbours: see `FileAccessScope`). A type a tab would only download (a Markdown file,
    /// a code file, a Word document) is left out too, because opening it would make a second copy in Downloads.
    /// Preview and Open With still cover everything.
    static let browserTypes: [UTType] = [
        .pdf, .png, .jpeg, .gif, .webP, .bmp, .ico, .plainText,
    ]

    static func rendersInBrowser(_ file: URL) -> Bool {
        UTType(filenameExtension: file.pathExtension).map { browserTypes.contains($0) } ?? false
    }
}

struct DownloadApp: Identifiable, Equatable {
    let url: URL
    let isDefault: Bool

    var id: URL {
        url
    }

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }
}

extension DownloadManager.Item {
    /// The finished file, when it is still on disk. Nil while the download is running or stopped, and once the
    /// file has been moved or deleted, so Preview and Open With are offered only for a file that exists.
    var availableFile: URL? {
        guard state == .finished, let destination,
              FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
        else { return nil }
        return destination
    }

    /// The finished file, when WSurf's own tabs can show it.
    var browserFile: URL? {
        availableFile.flatMap { DownloadWorkspace.rendersInBrowser($0) ? $0 : nil }
    }
}

extension BrowserModel {
    /// "Open in WSurf": a new tab on the downloaded file. Only a PDF, an image or a text file
    /// opens; anything else is refused here, whatever the caller offered. The tab belongs to this window, so a
    /// private window's download opens in a private tab.
    @discardableResult
    func openDownloadInTab(_ item: DownloadManager.Item) -> BrowserTab? {
        guard let file = item.browserFile else { return nil }
        return newTab(url: file, transition: .link)
    }
}
