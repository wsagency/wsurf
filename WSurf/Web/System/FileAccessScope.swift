// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a page loaded from a `file:` URL may read: that file and nothing next to it, so an HTML or SVG file opened by hand,
/// by drag or from the Downloads page cannot read, or send out, its neighbours. A folder the person opened (its listing) is
/// the one exception, and then the scope is that folder only.
///
/// WebKit takes this as `allowingReadAccessTo`. Chromium has no such parameter, so `ChromiumClient` asks `allows` for every
/// `file:` subresource of a `file:` page.
nonisolated enum FileAccessScope {
    /// The file or folder `url` names, without its query and fragment and with `.` and `..` resolved.
    static func readAccess(for url: URL) -> URL {
        URL(fileURLWithPath: url.path(percentEncoded: false), isDirectory: url.hasDirectoryPath).standardizedFileURL
    }

    /// Whether the page at `document` may load `resource`. Anything that is not a `file:` URL on a `file:` page is Chromium's
    /// own business and is left alone.
    static func allows(_ resource: URL, from document: URL?) -> Bool {
        guard resource.isFileURL, let document, document.isFileURL else { return true }
        let scope = readAccess(for: document)
        let base = path(scope), target = path(readAccess(for: resource))
        return target == base || (scope.hasDirectoryPath && target.hasPrefix(base + "/"))
    }

    /// The path without a trailing slash, so `/a/site` and `/a/site/` compare equal and `/a/site-2` is not inside `/a/site`.
    private static func path(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
