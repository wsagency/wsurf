// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
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
            opensNextPDFDownload = opening
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

    /// Whether the Chromium download that has just been decided is the one Open in Preview asked for: the next PDF this tab's page
    /// downloads after the request. A download of anything else leaves the request for the PDF that follows.
    func takesPDFOpening(forDownloadNamed name: String) -> Bool {
        guard opensNextPDFDownload, name.lowercased().hasSuffix(".pdf") else { return false }
        opensNextPDFDownload = false
        return true
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
