// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

nonisolated enum StoreFileError: Error, Equatable, Sendable { case exists, unsupported, io(Int32) }

/// Filesystem primitives the store's atomic commits depend on, injectable so tests can fail one step.
nonisolated struct StoreFileOps: Sendable {
    var renameExclusive: @Sendable (_ from: URL, _ to: URL) throws -> Void  // RENAME_EXCL; existing destination ⇒ .exists
    var renameSwap: @Sendable (_ a: URL, _ b: URL) throws -> Void  // RENAME_SWAP; ENOTSUP/EINVAL ⇒ .unsupported
    var fullFsync: @Sendable (_ file: URL) throws -> Void  // open + fcntl(F_FULLFSYNC)
    var fsyncDirectory: @Sendable (_ directory: URL) throws -> Void
    var afterMigrationStep: (@Sendable (_ step: Int) throws -> Void)?  // test seam, nil in production; Task 9 calls it after each step 1-10

    // ponytail: directories also use F_FULLFSYNC; a filesystem that refuses it surfaces as .io, add an fsync(2) fallback if one ever does.
    static let live = StoreFileOps(
        renameExclusive: { try renameNode($0, $1, flags: UInt32(RENAME_EXCL), unsupported: []) },
        renameSwap: { try renameNode($0, $1, flags: UInt32(RENAME_SWAP), unsupported: [ENOTSUP, EINVAL]) },
        fullFsync: { try flush($0, openFlags: O_RDONLY) },
        fsyncDirectory: { try flush($0, openFlags: O_RDONLY | O_DIRECTORY) },
        afterMigrationStep: nil
    )

    private static func renameNode(_ from: URL, _ to: URL, flags: UInt32, unsupported: [Int32]) throws {
        let result = from.withUnsafeFileSystemRepresentation { source in
            to.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return EINVAL }
                return renamex_np(source, destination, flags) == 0 ? 0 : errno
            }
        }
        switch result {
        case 0:
            return
        case EEXIST where flags == UInt32(RENAME_EXCL):
            throw StoreFileError.exists
        case let code where unsupported.contains(code):
            throw StoreFileError.unsupported
        case let code:
            throw StoreFileError.io(code)
        }
    }

    private static func flush(_ url: URL, openFlags: Int32) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            let descriptor = open(path, openFlags | O_CLOEXEC)
            guard descriptor >= 0 else { return errno }
            defer { close(descriptor) }
            return fcntl(descriptor, F_FULLFSYNC) == 0 ? 0 : errno
        }
        if result != 0 {
            throw StoreFileError.io(result)
        }
    }
}
