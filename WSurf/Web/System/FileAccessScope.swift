// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UniformTypeIdentifiers

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
/// WebKit, measured with a standalone web view outside the temporary directory, holds a PDF, an image, a text file, an SVG and an
/// XHTML document to a single-file grant, but still lets an `.html` document load the files in its folder. So on WebKit a
/// quarantined file whose type is not known to be inert (an image, PDF, plain text, audio or video) also runs without script
/// (`allowsScript(inFile:)`) and refuses file frames (`refusesSubframe`): static siblings may still render,
/// but the page cannot read them into data or send them anywhere. Chromium's gate confines it fully.
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

    /// Types a quarantined file may be shown as without taking its script away: images, PDF, plain text, audio and video. An SVG is
    /// an image but also XML, and a web archive is neither, so the second list takes precedence. Anything else, and any type that
    /// is not known, may carry script.
    private static let inertTypes: [UTType] = [.image, .pdf, .plainText, .audiovisualContent]
    private static let scriptedTypes: [UTType] = [.xml, .html, .webArchive]

    /// Whether a file's type is known to run no script when shown.
    static func isInert(_ file: URL) -> Bool {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
        return inertTypes.contains { type.conforms(to: $0) } && !scriptedTypes.contains { type.conforms(to: $0) }
    }

    /// Whether a page loaded from `url` may run script on WebKit. Not when it is a quarantined file whose type is not known to be
    /// inert (HTML, XHTML, XML, SVG, a web archive, or a type nobody knows): WebKit may let such a document read its folder, and
    /// without script it cannot read the files into data or send them anywhere. The person's own file, a quarantined image, PDF,
    /// text, audio or video file, a folder and a web address are not held back.
    static func allowsScript(inFile url: URL) -> Bool {
        guard url.isFileURL else { return true }
        let item = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL
        guard !item.hasDirectoryPath, isQuarantined(item) else { return true }
        return isInert(item)
    }

    /// Whether a frame inside the page at `main` must not be shown `target`. Any `file:` frame of a quarantined file page is refused,
    /// and so is a quarantined file that could run script, wherever it is embedded: the page's script setting covers its frames, so
    /// an embedded one would run script the way its page does.
    static func refusesSubframe(to target: URL, inPageAt main: URL?) -> Bool {
        guard target.isFileURL else { return false }
        if !allowsScript(inFile: target) {
            return true
        }
        guard let main, main.isFileURL else { return false }
        return isQuarantined(URL(fileURLWithPath: main.path(percentEncoded: false)).standardizedFileURL)
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
