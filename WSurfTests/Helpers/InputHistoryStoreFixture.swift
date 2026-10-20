// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

@testable import WSurf

/// A wall clock that only moves when a test moves it. Entries are named after it, so a test ages them by advancing it.
nonisolated final class InputHistoryTestWallClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func now() -> Date {
        current.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// One Input History store over a temporary directory and in-memory key storage. Nothing here reaches the real Keychain or the
/// installed app's files.
nonisolated struct InputHistoryStoreFixture {
    let root: URL
    let directory: URL
    let profileID: UUID
    let privateKeys: MemoryAutofillStorage
    let publicKeys: MemoryAutofillStorage
    let clock: InputHistoryTestWallClock
    let store: InputHistoryStore

    init(
        profileID: UUID = UUID(),
        ownsSession: Bool = true,
        privateKeys: MemoryAutofillStorage = MemoryAutofillStorage(),
        publicKeys: MemoryAutofillStorage = MemoryAutofillStorage(),
        clock: InputHistoryTestWallClock = InputHistoryTestWallClock(),
        directory: URL? = nil
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InputHistoryTests-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        self.directory = directory ?? root.appendingPathComponent("InputHistory", isDirectory: true)
        self.profileID = profileID
        self.privateKeys = privateKeys
        self.publicKeys = publicKeys
        self.clock = clock
        store = InputHistoryStore(
            profileID: profileID,
            directory: self.directory,
            privateKeys: privateKeys,
            publicKeys: publicKeys,
            ownsSession: ownsSession,
            now: { clock.now() }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A second store over the same files and keys, as another copy of the app would see them.
    func sibling(ownsSession: Bool) -> InputHistoryStore {
        let clock = clock
        return InputHistoryStore(
            profileID: profileID,
            directory: directory,
            privateKeys: privateKeys,
            publicKeys: publicKeys,
            ownsSession: ownsSession,
            now: { clock.now() }
        )
    }

    /// The entry files, sorted by name.
    var files: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".wih") }.sorted().map { directory.appendingPathComponent($0) }
    }
}

extension InputHistoryPayload {
    /// Synthetic values only.
    static func testSample(
        _ value: String = "dummy-secret-123",
        kind: Kind = .password,
        username: String? = "ada@example.test",
        url: String = "https://example.test/login",
        title: String = "Sign in",
        label: String = "Password"
    ) -> InputHistoryPayload {
        InputHistoryPayload(
            url: url, frameOrigin: nil, title: title, label: label, kind: kind, value: value, username: username
        )
    }
}
