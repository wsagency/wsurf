// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a page loaded from a `file:` URL may read, which depends on whether the file can be trusted with its neighbours.
///
/// - A file that carries the `com.apple.quarantine` attribute came from outside (a browser, mail, chat) and reads only itself, so an
///   HTML or SVG file someone sent cannot read, or send out, what lies next to it.
/// - A file without it is the person's own, a saved page or a page of a project they are working on, and reads its folder, so its
///   stylesheets, scripts and images load.
/// - A folder the person opens (its listing) reads that folder.
/// - A file that cannot be inspected (it is gone, or the attribute cannot be read) is treated as quarantined.
///
/// WebKit takes the scope as `allowingReadAccessTo`. Chromium has no such parameter, so `ChromiumFileScope` applies it to every
/// `file:` subresource. Quarantine is only read here, never changed.
///
/// Known gap, measured with a standalone WKWebView outside the temporary directory: given a single file, WebKit holds a PDF, an
/// image, a text file, an SVG and an XHTML document to it, but it still lets an `.html` document load the files in its folder.
/// So on WebKit a quarantined HTML file is not confined yet (`FileAccessScopeTests` records it as a known issue); Chromium is.
nonisolated enum FileAccessScope {
    static let quarantineAttribute = "com.apple.quarantine"

    /// The file or folder `url` may read, without its query and fragment and with `.` and `..` resolved.
    static func readAccess(for url: URL) -> URL {
        // Built without saying whether it is a folder, so the file system answers for a folder given without its trailing slash.
        let item = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL
        return item.hasDirectoryPath || isQuarantined(item) ? item : item.deletingLastPathComponent()
    }

    /// Whether the file carries the quarantine attribute. An answer other than "it has none" counts as yes.
    static func isQuarantined(_ file: URL) -> Bool {
        file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return true }
            return getxattr(path, quarantineAttribute, nil, 0, 0, 0) >= 0 || errno != ENOATTR
        }
    }

    /// Whether the document at `document` may load `resource`. A resource that is not a `file:` URL is not a file read and is
    /// left to the engine; a `file:` resource is allowed only inside the scope of a `file:` document.
    static func allows(_ resource: URL, from document: URL) -> Bool {
        guard resource.isFileURL else { return true }
        guard document.isFileURL else { return false }
        let scope = readAccess(for: document)
        let base = path(scope), target = path(URL(fileURLWithPath: resource.path(percentEncoded: false), isDirectory: false).standardizedFileURL)
        let inside = base.hasSuffix("/") ? base : base + "/"
        return target == base || (scope.hasDirectoryPath && target.hasPrefix(inside))
    }

    /// The path without a trailing slash (but the root keeps its own), so `/a/site` and `/a/site/` compare equal and `/a/site-2` is
    /// not inside `/a/site`.
    private static func path(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

/// One Chromium page's `file:` scope, shared by CEF's UI thread, which sets it when a main-frame navigation begins, before its
/// first subresource can be requested, and by its IO thread, which asks it for every subresource. It applies the same trust rule
/// as WebKit and fails closed: a `file:` subresource is refused unless the scope is known, the requesting frame's document is a
/// `file:` URL inside it, and the resource is inside that document's own scope. Between a navigation and its commit the frame
/// still shows the old document, which is outside the new scope, so nothing slips through on a stale address.
nonisolated final class ChromiumFileScope: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: URL?

    /// A main-frame navigation to `url` is going ahead: what that file may read is the scope, and any other address leaves none.
    func mainFrameNavigation(to url: URL?) {
        let next = url.flatMap { $0.isFileURL ? FileAccessScope.readAccess(for: $0) : nil }
        lock.lock()
        scope = next
        lock.unlock()
    }

    /// Whether `resource`, requested by the frame whose document is `document` (nil when it is not known), must be refused.
    func refuses(_ resource: URL, requestedBy document: URL?) -> Bool {
        guard resource.isFileURL else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let scope, let document, document.isFileURL else { return true }
        return !FileAccessScope.allows(document, from: scope) || !FileAccessScope.allows(resource, from: document)
    }
}
