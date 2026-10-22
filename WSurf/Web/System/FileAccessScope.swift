// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a page loaded from a `file:` URL may read: that file and nothing next to it, so an HTML or SVG file opened by hand,
/// by drag or from the Downloads page cannot read, or send out, its neighbours. A folder the person opened (its listing) is
/// the one exception, and then the scope is that folder only.
///
/// WebKit takes this as `allowingReadAccessTo`. Chromium has no such parameter, so `ChromiumFileScope` applies it to every
/// `file:` subresource.
nonisolated enum FileAccessScope {
    /// The file or folder `url` names, without its query and fragment and with `.` and `..` resolved.
    static func readAccess(for url: URL) -> URL {
        URL(fileURLWithPath: url.path(percentEncoded: false), isDirectory: url.hasDirectoryPath).standardizedFileURL
    }

    /// Whether the document at `document` may load `resource`. A resource that is not a `file:` URL is not a file read and is
    /// left to the engine; a `file:` resource is allowed only inside the scope of a `file:` document.
    static func allows(_ resource: URL, from document: URL) -> Bool {
        guard resource.isFileURL else { return true }
        guard document.isFileURL else { return false }
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

/// One Chromium page's `file:` scope, shared by CEF's UI thread, which sets it when a main-frame navigation begins, before its
/// first subresource can be requested, and by its IO thread, which asks it for every subresource. It fails closed: a `file:`
/// subresource is refused unless the scope is known, the requesting frame's document is a `file:` URL inside it, and the
/// resource is inside that document's own scope. Between a navigation and its commit the frame still shows the old document,
/// which is outside the new scope, so nothing slips through on a stale address.
nonisolated final class ChromiumFileScope: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: URL?

    /// A main-frame navigation to `url` is going ahead: the file it names is the scope, and any other address leaves none.
    func mainFrameNavigation(to url: URL?) {
        lock.lock()
        scope = url.flatMap { $0.isFileURL ? FileAccessScope.readAccess(for: $0) : nil }
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
