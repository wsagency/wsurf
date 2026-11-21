// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Security
import Synchronization
import Testing

@testable import WSurf

/// These fixtures own no system Keychain items. A case that seeds an item supplies its own storage inside this scope.
nonisolated struct EmptyProfileKeychain: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    @concurrent
    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await AutofillKeychainStorage.$deleteForTesting.withValue({ _, _ in errSecItemNotFound }) {
            try await function()
        }
    }
}

extension ProfileTests {
    enum KeychainItem: CaseIterable {
        case cards, contacts, passwords, saveIndex, inputPrivateKey, inputPublicKey, inputBinding

        func key(for id: UUID) -> String {
            let prefix = AutofillVaults.serviceNamespace()
            switch self {
            case .cards:
                return "io.wsagency.wsurf.payment-cards.tests.\(ProcessInfo.processInfo.processIdentifier).\(id)/cards"
            case .contacts:
                return "\(prefix).contacts.\(id)/records.when-unlocked"
            case .passwords:
                return "\(prefix).passwords.\(id)/records"
            case .saveIndex:
                return "\(AutofillSaveIndex.service(id))/records.when-unlocked"
            case .inputPrivateKey:
                return "\(prefix).input-history.\(id)/records"
            case .inputPublicKey:
                return "\(prefix).input-history.\(id)/records.when-unlocked"
            case .inputBinding:
                return "\(prefix).input-history.\(id).vault/records.when-unlocked"
            }
        }
    }

    @Test(arguments: KeychainItem.allCases)
    func recoveryKeepsTheErasureUntilTheNamedKeychainItemIsAccessible(item: KeychainItem) async throws {
        let files = FileManager.default, root = files.temporaryDirectory.appending(path: UUID().uuidString)
        let file = root.appending(path: "profiles.json"), store = ProfileStore(file: file)
        let work = store.add(name: "Work"), kept = store.add(name: "Kept")
        defer {
            try? files.removeItem(at: work.supportDirectory)
            try? files.removeItem(at: root)
        }
        let sentinel = work.supportDirectory.appending(path: "synthetic")
        try files.createDirectory(at: work.supportDirectory, withIntermediateDirectories: true)
        try Data("Synthetic file".utf8).write(to: sentinel)
        var checkpoint: Data?
        try await store.remove(work, releaseWindows: { checkpoint = try? Data(contentsOf: file) },
                               settingsSync: nil, sharedSpaces: nil, eraseData: { _ in }).get()
        try #require(checkpoint).write(to: file, options: .atomic)

        let deletedKey = item.key(for: work.id), liveKey = item.key(for: kept.id)
        let items = Mutex([deletedKey: Data("Work fixture".utf8), liveKey: Data("Kept fixture".utf8)])
        let locked = Mutex(true), denied = Mutex(false)
        try await AutofillKeychainStorage.$deleteForTesting.withValue({ service, account in
            let key = "\(service)/\(account)"
            return items.withLock { values in
                guard values[key] != nil else { return errSecItemNotFound }
                if key == deletedKey && locked.withLock({ $0 }) {
                    denied.withLock { $0 = true }
                    return errSecInteractionNotAllowed
                }
                values.removeValue(forKey: key)
                return errSecSuccess
            }
        }) {
            let restarted = ProfileStore(file: file)
            try #require(await waitUntil(timeout: .seconds(8)) { !files.fileExists(atPath: sentinel.path) })
            #expect(denied.withLock { $0 })
            #expect(try String(contentsOf: file, encoding: .utf8).contains(work.id.uuidString))
            #expect(items.withLock { $0[deletedKey] } == Data("Work fixture".utf8))

            locked.withLock { $0 = false }
            try await restarted.remove(work, settingsSync: nil, sharedSpaces: nil).get()
            #expect(items.withLock { $0 } == [liveKey: Data("Kept fixture".utf8)])
            #expect(try !String(contentsOf: file, encoding: .utf8).contains(work.id.uuidString))
            #expect(restarted.profiles == [.original(), kept])
        }
    }
}
