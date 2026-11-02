// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CefKit
import Foundation
import WebKit

extension BrowserTab {
    /// The address of the PDF this tab shows as its whole document, nil for any other page. Each engine draws it in its own
    /// viewer; the tab knows it by the type of the engine's main-frame response (`noteMainFrameResponse`).
    var shownPDF: URL? {
        guard liveView != nil, let url = URL(string: urlString), documentFilename(for: url) != nil else { return nil }
        return url
    }

    /// Saves the PDF the tab shows as a download: it is listed in Downloads, goes where downloads go (the panel when downloads ask),
    /// is quarantined like any other, and a private window's stays out of the saved list. `opening` then opens the copy in the app
    /// for PDFs.
    ///
    /// WebKit's web process still holds the bytes its viewer was given, so no second request is made. Chromium keeps its viewer's
    /// stream to itself: it downloads the address again in the tab's own session, with the tab's cookies and credentials.
    func savePDF(opening: Bool = false) {
        guard let url = shownPDF, let view = liveView else { return }
        if let webKit = view.webKit {
            let filename = documentFilename(for: url) ?? url.lastPathComponent
            Task {
                guard liveView === view else { return }
                guard let data = await webKit.mainResourceData() else {
                    // A WebKit without the private call: the tab's own session fetches it again.
                    let download = await webKit.startDownload(using: URLRequest(url: url))
                    onDownload?(download, url)
                    return
                }
                guard liveView === view else { return }
                await onSaveDocument?(data, filename, url, opening)
            }
        } else if let chromium = view.chromium {
            if opening {
                awaitPDFOpening(of: url, in: view)
            } else {
                pendingPDFOpening = nil
            }
            chromium.startDownload(of: url)
        }
    }

    /// File › Save Page As…: a PDF is saved as the PDF itself, any other page as a web archive.
    func savePage() {
        guard shownPDF == nil else {
            savePDF()
            return
        }
        PageSaving.begin(for: shownPage)
    }

    /// Open in Preview on a Chromium PDF opens the copy of the one download that `savePDF` started, and of nothing else: the request
    /// belongs to `page`, names the address that was asked for, and ends at its first use, at the tab's next navigation and after
    /// `pdfOpeningLifetime`. A download that was denied, fails or never starts leaves nothing behind that could open a file a page
    /// chose to download.
    func awaitPDFOpening(of url: URL, in page: BrowserPage) {
        let request = PendingPDFOpening(url: url, page: ObjectIdentifier(page))
        pendingPDFOpening = request
        Task {
            try? await Task.sleep(for: pdfOpeningLifetime)
            if pendingPDFOpening?.id == request.id {
                pendingPDFOpening = nil
            }
        }
    }

    /// Whether `download`, which `page` has just made, is the one Open in Preview waits for. True once.
    func takesPDFOpening(for download: CefDownload, in page: BrowserPage) -> Bool {
        guard let pending = pendingPDFOpening, pending.matches(download, in: ObjectIdentifier(page)) else { return false }
        pendingPDFOpening = nil
        return true
    }
}

/// An Open in Preview on a Chromium PDF, waiting for the download it started (`BrowserTab.awaitPDFOpening`).
struct PendingPDFOpening {
    let id = UUID()
    let url: URL
    let page: ObjectIdentifier

    /// A download of the address that was asked for, as it was asked for or as a redirect ended, made by the same page.
    func matches(_ download: CefDownload, in page: ObjectIdentifier) -> Bool {
        guard page == self.page else { return false }
        return [download.originalURL, download.url].contains { $0.map(Self.address) == Self.address(url) }
    }

    private static func address(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}

extension WKWebView {
    /// The bytes of the document the view shows, as the web process holds them. Nil where this WebKit has no such call, or no bytes.
    func mainResourceData() async -> Data? {
        let selector = NSSelectorFromString("_getMainResourceDataWithCompletionHandler:")
        guard responds(to: selector) else { return nil }
        typealias Fetch = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Data?, Error?) -> Void) -> Void
        let fetch = unsafeBitCast(method(for: selector), to: Fetch.self)
        return await withCheckedContinuation { continuation in
            fetch(self, selector) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// Whether the view shows a PDF in WebKit's own viewer.
    var isDisplayingPDF: Bool {
        let selector = NSSelectorFromString("_isDisplayingPDF")
        guard responds(to: selector) else { return false }
        return (value(forKey: "_isDisplayingPDF") as? Bool) == true
    }
}
