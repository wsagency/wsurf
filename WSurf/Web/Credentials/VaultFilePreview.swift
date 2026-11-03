// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Decrypted copies of vault files for Quick Look and Open With. One private folder per run of WSurf in the user's own Caches folder
/// (never the shared temporary directory, and outside backups), a folder per copy inside it; folders 0700, files 0600. A copy is
/// removed when its preview closes, every copy when a vault locks or WSurf quits, and whatever an earlier run left behind (a crash,
/// a forced quit) at the next launch.
nonisolated struct VaultFilePreviewFolder: Sendable {
    let root: URL
    let run: UUID

    static let shared = VaultFilePreviewFolder(
        root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "WSurf", directoryHint: .isDirectory)
            .appending(path: "Vault File Previews", directoryHint: .isDirectory),
        run: UUID()
    )

    var runFolder: URL {
        root.appending(path: run.uuidString, directoryHint: .isDirectory)
    }

    /// Where a new copy of a file called `name` goes: a fresh 0700 folder of its own, so two copies never collide.
    func newCopyURL(named name: String) throws -> URL {
        let folder = runFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        for directory in [root, runFolder, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // A folder that already existed keeps no wider mode than this.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try? excluded.setResourceValues(values)
        return folder.appending(path: Self.safeName(name), directoryHint: .notDirectory)
    }

    /// Removes the copy at `url` with its folder. Nothing outside this run's folder is ever touched.
    func remove(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == runFolder.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: runFolder)
    }

    /// Every run's folder but this one's.
    func removeLeftovers() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name != run.uuidString {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }

    /// A name a file can have: no folder separator, not hidden, not empty, at most 200 UTF-8 bytes.
    static func safeName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        var kept = ""
        for character in cleaned {
            guard kept.utf8.count + String(character).utf8.count <= 200 else { break }
            kept.append(character)
        }
        return kept.isEmpty ? "File" : kept
    }
}
