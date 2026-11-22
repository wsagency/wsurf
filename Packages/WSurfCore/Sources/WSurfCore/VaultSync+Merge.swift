// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Synchronization

extension VaultSyncSummary {
    var readyForMerge: Bool {
        enabled && (stored == .active || stored == .iCloudFull) && !isReading && inbox == 0 && review == 0 && parked == 0 && unreadable == 0
    }
}

extension VaultSync {
    /// A review belongs to one enrollment. Disabling and re-enabling the same zone starts another.
    public struct MergeDestination: Equatable, Sendable {
        fileprivate let key: VaultKey
        fileprivate let owner: String
        fileprivate let session: Int
    }

    public func mergeDestination(profileID: UUID, vaultID: UUID) -> MergeDestination? {
        let key = localKey(profileID: profileID, vaultID: vaultID)
        guard let owner = connectedAccount, permits(key), let summary = summaries[key], summary.enabled,
              summary.stored == .active || summary.stored == .iCloudFull else { return nil }
        return MergeDestination(key: key, owner: owner, session: token(key))
    }

    /// A database writer can check this while it commits, even if it waited through an account or enrollment change.
    public nonisolated final class MergeAuthorization: Sendable {
        private let valid = Mutex(true)

        public var isCurrent: Bool {
            valid.withLock { $0 }
        }

        fileprivate func revoke() {
            valid.withLock { $0 = false }
        }
    }

    func invalidateMergeReview(_ key: VaultKey) {
        mergeReviews.removeValue(forKey: key)?.revoke()
    }

    func invalidateMergeReviews() {
        for review in mergeReviews.values {
            review.revoke()
        }
        mergeReviews.removeAll()
    }

    /// Joining a locked vault can leave incoming entries waiting. Compare only after its queued unlock pass and check
    /// the live Apple account and profile instance before transferring credentials across vaults.
    public func verifyMergeDestination(_ destination: MergeDestination) async throws -> MergeAuthorization {
        let key = destination.key
        return try await serial(key) { [self] in
            guard let engine, let identity = engine as? any SyncAccountIdentity,
                  destination == mergeDestination(profileID: key.profileID, vaultID: key.vaultID) else { throw VaultSyncFailure.unavailable }
            try await checkInstance?(key.profileID, destination.owner)
            guard try await identity.currentAccountUser() == destination.owner, self.engine === engine,
                  destination == mergeDestination(profileID: key.profileID, vaultID: key.vaultID),
                  !incomplete.contains(key), let (_, row) = runningRow(key), !row.needsFetch,
                  summaries[key]?.readyForMerge == true else { throw VaultSyncFailure.unavailable }
            if let current = mergeReviews[key] {
                return current
            }
            let review = MergeAuthorization()
            mergeReviews[key] = review
            return review
        }
    }
}
