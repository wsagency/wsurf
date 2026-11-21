// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfCore
@testable import WSurfVault

@MainActor
struct VaultSyncFileCapacityTests {
    @Test func aFullAttachmentBudgetRefusesOnlyTheEntryThatAddsAFile() async throws {
        try await withDevicePair { pair in
            let source = pair.envA.directory.appending(path: "incoming.bin")
            try Data([1]).write(to: source)
            var incoming = pair.account("incoming-file")
            incoming.attachments = [try await pair.managerA.addAttachment(from: source)]
            let password = pair.account("independent-password")
            try await pair.save([incoming, password], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockBWithoutSync()
            let manager = try #require(pair.managerB)

            // The store counts the sizes sealed into the live rows. Fill the budget without allocating 2 GB of test files.
            var full = pair.account("existing-files")
            full.attachments = (0..<Int(CredentialAttachment.vaultBytes / CredentialAttachment.fileBytes)).map { _ in
                CredentialAttachment(id: UUID(), name: "fixture", contentType: "public.data", size: CredentialAttachment.fileBytes,
                                     sha256: Data(count: 32), wrappedKey: Data(count: 60))
            }
            try await pair.save([full], in: manager)
            pair.syncB.vaultUnlocked(profileID: pair.profile.id, vaultID: pair.vaultID)
            await pair.syncB.settle()

            let local = try await pair.accounts(manager)
            #expect(local[password.id]?.password == password.password)
            #expect(local[full.id]?.attachments == full.attachments)
            #expect(local[incoming.id] == nil)
            let review = try await pair.syncB.conflicts(profileID: pair.profile.id, vaultID: pair.vaultID)
            #expect(review.map(\.id) == [incoming.id] && review.first?.kind == .refused)
        }
    }
}
