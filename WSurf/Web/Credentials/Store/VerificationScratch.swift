// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import GRDB

/// The verification scratch database (spec §7): a throwaway SQLite file `<support>/Credentials.scratch/<UUID>.db` that holds the
/// V4/V5 ledgers. It is created `0600` in a `0700` directory before SQLite opens it, attached to the caller's writer connection
/// in autocommit, written inside one deferred snapshot that is always rolled back, then detached and unlinked. It never touches
/// `TEMP`, the OS temporary directory or any process-global pragma. Its rows are opaque ids, small integers and SHA-256 digests.
nonisolated enum VerificationScratch {
    static func directory(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Credentials.scratch", isDirectory: true)
    }

    /// `side` is 0 for the source vault and 1 for its Trash; `subject` is 0 for "none". V4: `expected` (one row per history
    /// row the journal says exists); V5: `transfers` (one per transfer group) and `transferRows` (the rows it moved).
    private static let ledgerTables = """
        CREATE TABLE scratch.expected(
            side INTEGER NOT NULL, recordID BLOB NOT NULL, kind INTEGER NOT NULL, ownerID BLOB NOT NULL, subject INTEGER NOT NULL,
            version INTEGER NOT NULL, rowDigest BLOB NOT NULL, seen INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(side, recordID)) WITHOUT ROWID;
        CREATE TABLE scratch.transfers(
            transferID BLOB NOT NULL, side INTEGER NOT NULL, direction INTEGER NOT NULL, scope INTEGER NOT NULL, ownerID BLOB NOT NULL,
            subject INTEGER NOT NULL, liveRecordID BLOB NOT NULL, liveVersion INTEGER NOT NULL, entryRecordID BLOB NOT NULL,
            PRIMARY KEY(transferID, side)) WITHOUT ROWID;
        CREATE TABLE scratch.transferRows(
            transferID BLOB NOT NULL, side INTEGER NOT NULL, recordID BLOB NOT NULL, kind INTEGER NOT NULL, ownerID BLOB NOT NULL,
            subject INTEGER NOT NULL, version INTEGER NOT NULL, PRIMARY KEY(transferID, side, recordID)) WITHOUT ROWID;
        """

    /// Owns the whole lifecycle and returns or rethrows exactly what `body` does. `body` runs on `writer`'s serialized connection
    /// inside one deferred transaction that is always rolled back, so it must never write the main database. A cleanup failure
    /// (detach or unlink) goes to `cleanupFailed` and never changes the outcome. `writeWithoutTransaction`, not `read`: a read
    /// connection is `query_only` (no scratch writes) and a read-only one cannot attach a new file.
    static func run<T>(
        on writer: any DatabaseWriter,
        supportDirectory: URL,
        cleanupFailed: @Sendable (URL) -> Void,
        _ body: (Database) throws -> T
    ) throws -> T {
        try attached(on: writer, supportDirectory: supportDirectory, cleanupFailed: cleanupFailed) { db in
            var value: T?
            try db.inTransaction(.deferred) {
                value = try body(db)
                return .rollback
            }
            return value.unsafelyUnwrapped  // `inTransaction` either threw above or ran `body`
        }
    }

    /// The same lifecycle with `body` running in autocommit on the attached connection, for a caller that opens its own transaction
    /// (a write transaction cannot attach, so a MOVE's ledger preflight needs the scratch attached before `BEGIN IMMEDIATE`).
    /// `body` owns its transaction; whatever it leaves in `scratch` is discarded with the file.
    static func attached<T>(
        on writer: any DatabaseWriter,
        supportDirectory: URL,
        cleanupFailed: @Sendable (URL) -> Void,
        _ body: (Database) throws -> T
    ) throws -> T {
        let file = try create(in: directory(in: supportDirectory))
        var detachFailed = false
        let outcome: Result<T, Error> = writer.writeWithoutTransaction { db in
            var attached = false
            let outcome = Result<T, Error> {
                try db.execute(sql: "ATTACH DATABASE ? AS scratch", arguments: [file.path])
                attached = true
                // SQLite refuses OFF here and answers `delete` (measured, evidence/task5-journal-probe); MEMORY leaves no journal file.
                guard try String.fetchOne(db, sql: "PRAGMA scratch.journal_mode = MEMORY") == "memory" else {
                    throw StoreFileError.unsupported
                }
                try db.execute(sql: "PRAGMA scratch.synchronous = OFF")  // illegal inside a transaction
                try db.execute(sql: ledgerTables)
                return try body(db)
            }
            if attached {
                do {
                    try db.execute(sql: "DETACH DATABASE scratch")
                } catch {
                    detachFailed = true
                }
            }
            return outcome
        }
        do {
            try FileManager.default.removeItem(at: file)
            if detachFailed {
                cleanupFailed(file)
            }
        } catch {
            cleanupFailed(file)
        }
        return try outcome.get()
    }

    /// Removes everything in the scratch directory and returns what it could not remove; `[directory]` when it exists but cannot
    /// be listed, or is a link or not owned by this user (never followed). Never throws and never logs. The caller invokes it only
    /// under the EXCLUSIVE operation lock: under SHARED another process may still be verifying with its live scratch file.
    static func cleanLeftovers(in supportDirectory: URL) -> [URL] {
        let directory = directory(in: supportDirectory)
        let descriptor = directory.withUnsafeFileSystemRepresentation { path in path.map { openOwned($0).descriptor } ?? -1 }
        guard descriptor >= 0 else { return StoreAnchors.exists(directory) ? [directory] : [] }  // a link, a foreign owner or unlistable
        defer { close(descriptor) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [directory] }
        return names.map { directory.appendingPathComponent($0) }.filter { entry in
            (try? FileManager.default.removeItem(at: entry)) == nil
        }
    }

    /// Opens the scratch directory itself, never through a link, and only when this user owns it: the descriptor, or the errno.
    private static func openOwned(_ path: UnsafePointer<CChar>) -> (descriptor: Int32, error: Int32) {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return (-1, errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid() else {
            close(descriptor)
            return (-1, EPERM)
        }
        return (descriptor, 0)
    }

    /// An absent directory is created `0700`; an existing one must be a directory this user owns (never a link) and is forced to
    /// `0700`. The new `0600` file is created exclusively, relative to that descriptor, before SQLite ever opens it.
    private static func create(in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("\(UUID().uuidString).db", isDirectory: false)
        let code = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            if mkdir(path, 0o700) != 0, errno != EEXIST {
                return errno
            }
            let root = openOwned(path)
            guard root.descriptor >= 0 else { return root.error }
            defer { close(root.descriptor) }
            guard fchmod(root.descriptor, 0o700) == 0 else { return errno }
            let descriptor = openat(root.descriptor, file.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return errno }
            close(descriptor)
            return 0
        }
        guard code == 0 else { throw StoreFileError.io(code) }
        return file
    }
}
