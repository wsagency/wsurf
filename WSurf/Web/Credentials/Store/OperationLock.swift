// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Synchronization

/// One flock(2) on its own file descriptor. Closing the descriptor releases the lock, so the descriptor is taken out
/// under the mutex first: a second `release()` (or deinit after release) finds nothing and cannot close a reused fd.
nonisolated final class OperationLockHold: Sendable {
    private let descriptor: Mutex<Int32?>

    fileprivate init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    func release() {
        let taken = descriptor.withLock { state -> Int32? in
            defer { state = nil }
            return state
        }
        if let taken {
            close(taken)
        }
    }

    deinit { release() }
}

nonisolated enum OperationLock {
    enum Mode: Sendable { case shared, exclusive }

    /// flock(2) on `<directory>/Credentials.lock`, polled every 10 ms. Each call opens its own descriptor, so holders
    /// in one process conflict like holders in two processes; a shared holder asking for exclusive times out
    /// (`.storeBusy`) instead of upgrading.
    static func acquire(in directory: URL, mode: Mode, wait: Duration = StoreFormat.lockWait) async throws -> OperationLockHold {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Credentials.lock")
        var errorCode: Int32 = 0
        let descriptor = file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errorCode = EINVAL; return -1 }
            let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            if descriptor < 0 {
                errorCode = errno
            }
            return descriptor
        }
        guard descriptor >= 0 else { throw StoreFileError.io(errorCode) }

        let operation = (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        do {
            while true {
                if flock(descriptor, operation) == 0 {
                    return OperationLockHold(descriptor: descriptor)
                }
                let code = errno
                guard code == EWOULDBLOCK || code == EINTR else { throw StoreFileError.io(code) }
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw CredentialStoreError.storeBusy }
                try await Task.sleep(for: min(.milliseconds(10), remaining))  // throws on cancellation: the descriptor is closed below
            }
        } catch {
            close(descriptor)
            throw error
        }
    }
}
