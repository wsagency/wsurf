// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-20: where the Chromium service may keep its profile tree. The hello names the root cache path, and CEF makes its whole tree
// there, so the service refuses a root that is not under one of the folders WSurf itself uses (the service cannot know which run
// is a staged one, so it holds to folders, not to runs).

import Foundation

public enum CefRemoteRoot {
    /// The folder inside the user's Application Support that is WSurf's own (`AppDatabase.supportDirectory`): the installed app's
    /// root is `<Application Support>/WSurf/Chromium`.
    public static let supportFolderName = "WSurf"

    /// The exact rule. A root is allowed when, after every link and alias in it is resolved, it is STRICTLY BELOW one of
    /// - `<Application Support>/WSurf` (the app), or
    /// - the user's temporary folder (`NSTemporaryDirectory()`: the tests, which make `wsurf-*` folders there, and a staged run's
    ///   default home, `<temporary folder>/wsurf-stage/home`).
    /// The base itself is not a root (a root's parent is where a staged run's log may go, and that must stay inside the base).
    /// A staged home anywhere else (a folder of a checkout, say) is refused: naming it is a decision for the owner, not a default.
    /// Ownership and the mode of the folder are not judged here; a sandbox (D4-S) bounds them.
    public static func bases() -> [String] {
        var found: [String] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let resolved = resolve(support.appendingPathComponent(supportFolderName, isDirectory: true).path) {
            found.append(resolved)
        }
        if let resolved = resolve(NSTemporaryDirectory()) {
            found.append(resolved)
        }
        return found
    }

    /// Whether `root` (already resolved, see ``resolve(_:)``) is strictly below one of `bases`, component by component (`/a/bc`
    /// is not below `/a/b`).
    public static func isAllowed(_ root: String, bases: [String]) -> Bool {
        let inner = (root as NSString).pathComponents
        return bases.contains { base in
            let outer = (base as NSString).pathComponents
            return inner.count > outer.count && Array(inner.prefix(outer.count)) == outer
        }
    }

    /// `path` with every symlink and alias resolved, for a path that may not exist yet: the nearest existing ancestor goes through
    /// `realpath` and the components below it are appended (they do not exist, so they cannot be links). Nil for a relative path,
    /// for one with a `.` or `..` component (which would be resolved before a link in front of it, so the result could name
    /// somewhere else than the path does), and when no ancestor resolves.
    ///
    /// What this does and does not guarantee (review L5): the answer is true at the moment of the call. Between it and the use
    /// (CEF's own open, `createDirectory`) a process of the same user could plant a link in a component that did not exist yet.
    /// Nothing binds the checked path to the opened one (no directory descriptor), so this is a guard against a wrong path, not a
    /// boundary against a hostile process of the same user; the sandbox of D4-S is that boundary.
    public static func resolve(_ path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else { return nil }
        var existing = path
        var below: [String] = []
        // `lstat`, not `fileExists`: that one follows a link, so a dangling symlink looked "not made yet" and was appended as if it
        // were a folder to come (review L2). Here it is present, `realpath` fails on it, and the path is refused.
        while !isPresent(existing) {
            guard existing != "/" else { return nil }
            below.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return nil }
        defer { free(resolved) }
        return ([String(cString: resolved)] + below).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// Whether something is at `path`, a link (even a dangling one) included.
    public static func isPresent(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
