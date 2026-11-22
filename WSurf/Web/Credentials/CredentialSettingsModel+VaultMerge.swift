// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Synchronization
import WSurfCore
import WSurfVault

/// The picker lists locally held vaults, including those of a separately created profile with the same name.
struct VaultMergeSource: Identifiable, Hashable {
    nonisolated struct Identifier: Hashable, Sendable {
        let profileID: UUID
        let vaultID: UUID
    }

    let id: Identifier
    fileprivate let profileLabel: String
    fileprivate let listing: VaultListing
    fileprivate let source: CredentialManager
    fileprivate let listedEpoch: UInt64?
    fileprivate let target: MergeTarget

    var label: String {
        let name = listedEpoch != nil && listedEpoch == source.authorizationEpoch ? listing.label : listing.numberedName
        return "\(profileLabel) · \(name)"
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// The picker and review both name the same selected vault, Apple account, and cloud enrollment.
private struct MergeTarget {
    let window: UUID
    let selection: UInt64
    let manager: CredentialManager
    let sync: VaultSync
    let enrollment: VaultSync.MergeDestination
}

struct VaultMergeReview {
    let rows: [CredentialVaultMergePlan.Row]
    let sourceLabel: String
    let destinationLabel: String
    fileprivate let source: VaultMergeSource
    fileprivate let enrollment: VaultSync.MergeAuthorization
    fileprivate let sourceEpoch: UInt64
    fileprivate let destinationEpoch: UInt64
    fileprivate let sourceRevision: UInt64
    fileprivate let destinationRevision: UInt64
    fileprivate let sourceStamps: [UUID: AccountStamp]
    fileprivate let destinationStamps: [UUID: AccountStamp]
}

enum VaultMergeError: Error { case unavailableDestination }

extension CredentialSettingsModel {
    var canMergeIntoSharedVault: Bool {
        mergeTarget != nil
    }

    private var mergeTarget: MergeTarget? {
        guard let manager, let sync = vaultSync,
              let enrollment = sync.mergeDestination(profileID: profile.id, vaultID: manager.vaultID) else { return nil }
        return MergeTarget(window: owner, selection: vaultSelectionGeneration, manager: manager, sync: sync, enrollment: enrollment)
    }

    private var mergeProfiles: [Profile] {
        (CloudSync.shared?.profileStore ?? .shared).verifiedProfiles ?? [.original()]
    }

    var vaultMergeDestinationLabel: String {
        let listing = vaults.first { $0.vaultID == selectedVaultID }
        let label = (isUnlocked ? listing?.label : listing?.numberedName) ?? String(localized: "Vault")
        return "\(profile.vaultPickerLabel(among: mergeProfiles)) · \(label)"
    }

    func mergeSources() async throws -> [VaultMergeSource] {
        guard let target = mergeTarget else { throw VaultMergeError.unavailableDestination }
        let profiles = mergeProfiles
        var sources: [VaultMergeSource] = []
        var unavailable: (any Error)?
        for profile in profiles where !profile.isPrivate {
            try Task.checkCancellation()
            let changes = VaultStateChanges.shared.count(for: profile.id)
            let listing: [VaultListing]
            do {
                let store = try CredentialManager.store(for: profile)
                listing = try await store.listing()
            } catch {
                // A damaged unrelated profile must not prevent copying from another readable source.
                unavailable = error
                continue
            }
            for vault in listing where profile.id != target.manager.profileID || vault.vaultID != target.manager.vaultID {
                let source = try CredentialManager.forVault(profile, vaultID: vault.vaultID, native: native)
                sources.append(VaultMergeSource(
                    id: .init(profileID: profile.id, vaultID: vault.vaultID), profileLabel: profile.vaultPickerLabel(among: profiles),
                    listing: vault, source: source, listedEpoch: changes == VaultStateChanges.shared.count(for: profile.id) ? source.authorizationEpoch : nil, target: target
                ))
            }
        }
        try Task.checkCancellation()
        guard matches(target) else { throw VaultMergeError.unavailableDestination }
        if sources.isEmpty, let unavailable {
            throw unavailable
        }
        return sources
    }

    private func matches(_ target: MergeTarget) -> Bool {
        guard target.window == owner, target.selection == vaultSelectionGeneration, target.manager === manager,
              target.sync === vaultSync else { return false }
        return target.enrollment == target.sync.mergeDestination(profileID: profile.id, vaultID: target.manager.vaultID)
    }

    private func requireSource(_ source: VaultMergeSource) throws {
        try Task.checkCancellation()
        guard matches(source.target), !profile.isPrivate, source.id.profileID != Profile.privateID,
              source.id != .init(profileID: profile.id, vaultID: source.target.manager.vaultID),
              mergeProfiles.contains(where: { $0.id == source.id.profileID }) else { throw VaultMergeError.unavailableDestination }
    }

    @discardableResult
    private func verifyTarget(_ target: MergeTarget) async throws -> VaultSync.MergeAuthorization {
        do {
            return try await target.sync.verifyMergeDestination(target.enrollment)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VaultMergeError.unavailableDestination
        }
    }

    /// The sheet retains only review metadata. Source and destination records are read again under both original leases at confirmation.
    func reviewVaultMerge(from source: VaultMergeSource, in anchor: @autoclosure () -> NSWindow) async throws -> VaultMergeReview {
        try requireSource(source)
        let target = source.target
        let destinationEpoch = try await target.manager.unlock(in: anchor()).epoch
        try requireSource(source)
        let sourceEpoch = try await source.source.unlock(in: anchor()).epoch
        let enrollment = try await verifyTarget(target)
        try requireSource(source)
        let incoming = try await source.source.snapshot()
        let stored = try await target.manager.snapshot()
        let rows = try await Self.compare(incoming, with: stored)
        let listing = try await source.source.store.listing()
        let destination = try await target.manager.store.listing()
        guard let from = listing.first(where: { $0.vaultID == source.id.vaultID }),
              let to = destination.first(where: { $0.vaultID == target.manager.vaultID }) else { throw CredentialVaultError.staleRevision }
        let review = VaultMergeReview(
            rows: rows, sourceLabel: "\(source.profileLabel) · \(from.label)", destinationLabel: "\(profile.vaultPickerLabel(among: mergeProfiles)) · \(to.label)",
            source: source, enrollment: enrollment, sourceEpoch: sourceEpoch, destinationEpoch: destinationEpoch, sourceRevision: incoming.revision, destinationRevision: stored.revision,
            sourceStamps: incoming.stamps, destinationStamps: stored.stamps
        )
        try await verifyDuplicateFiles(review, in: stored)
        try requireReview(review)
        return review
    }

    @concurrent private static func compare(_ source: StoreSnapshot, with destination: StoreSnapshot) async throws -> [CredentialVaultMergePlan.Row] {
        try Task.checkCancellation()
        return try CredentialVaultMergePlan.rows(source: source.accounts, destination: destination.accounts)
    }

    func isCurrentVaultMerge(_ review: VaultMergeReview) -> Bool {
        review.enrollment.isCurrent && matches(review.source.target)
            && review.source.source.authorizationEpoch == review.sourceEpoch && authorizationEpoch == review.destinationEpoch
    }

    private func requireReview(_ review: VaultMergeReview) throws {
        try requireSource(review.source)
        guard review.enrollment.isCurrent else { throw VaultMergeError.unavailableDestination }
        guard review.source.source.authorizationEpoch == review.sourceEpoch, authorizationEpoch == review.destinationEpoch else { throw CredentialVaultError.unauthorized }
    }

    private func verifyDuplicateFiles(_ review: VaultMergeReview, in destination: StoreSnapshot) async throws {
        try requireReview(review)
        var ids = Set<UUID>()
        for row in review.rows where row.kind == .duplicate {
            guard let target = row.targetID else { throw CredentialVaultError.staleRevision }
            ids.insert(target)
        }
        guard !ids.isEmpty else { return }
        let matches = destination.accounts.filter { ids.contains($0.id) }
        guard matches.count == ids.count else { throw CredentialVaultError.staleRevision }
        let files = matches.flatMap { $0.attachments ?? [] }
        if !files.isEmpty {
            try await review.source.target.manager.verifyMergeAttachments(files, destinationEpoch: review.destinationEpoch)
        }
    }

    @discardableResult
    func confirmVaultMerge(_ review: VaultMergeReview, choices: [UUID: CredentialVaultMergePlan.Choice]) async throws -> Int {
        try requireReview(review)
        let source = review.source.source, target = review.source.target
        guard let sourceGeneration = source.stableGeneration, let targetGeneration = target.manager.stableGeneration else { throw CredentialVaultError.staleRevision }
        let incoming = try await source.snapshot(), stored = try await target.manager.snapshot()
        guard incoming.revision == review.sourceRevision, incoming.stamps == review.sourceStamps,
              stored.revision == review.destinationRevision, stored.stamps == review.destinationStamps else { throw CredentialVaultError.staleRevision }
        let entries = try await Self.planEntries(review.rows, choices, source: incoming, destination: stored)
        try requireReview(review)
        guard !entries.isEmpty else {
            try await verifyDuplicateFiles(review, in: stored)
            try await verifyTarget(target)
            try requireReview(review)
            guard source.stableGeneration == sourceGeneration, target.manager.stableGeneration == targetGeneration else { throw CredentialVaultError.staleRevision }
            return 0
        }
        guard try await verifyOwner(String(localized: "copy entries into the shared vault")) == review.destinationEpoch else { throw CredentialVaultError.unauthorized }
        try requireReview(review)
        let files = entries.flatMap { $0.attachments ?? [] }
        if !files.isEmpty {
            try await target.manager.checkMergeAttachments(files, destinationEpoch: review.destinationEpoch)
        }
        var pins: [VaultImportedAttachment] = []
        do {
            var writes: [AccountWrite] = []
            for var entry in entries {
                if let files = entry.attachments, !files.isEmpty {
                    var local: [CredentialAttachment] = []
                    for file in files {
                        try requireReview(review)
                        let pin = try await target.manager.copyMergeAttachment(
                            file, from: source, sourceEpoch: review.sourceEpoch, destinationEpoch: review.destinationEpoch
                        )
                        pins.append(pin)
                        local.append(pin.descriptor)
                    }
                    entry.attachments = local
                }
                writes.append(.init(accountID: entry.id, expected: stored.stamps[entry.id].map(AccountExpectation.stamp) ?? .absent, replacement: entry))
            }
            try await verifyDuplicateFiles(review, in: stored)
            try await verifyTarget(target)
            guard try await source.snapshot().stamps == review.sourceStamps else { throw CredentialVaultError.staleRevision }
            try requireReview(review)
            guard source.stableGeneration == sourceGeneration else { throw CredentialVaultError.staleRevision }
            try await commitMerge(writes, review: review, sourceGeneration: sourceGeneration)
            withExtendedLifetime(pins) {}
        } catch {
            let ids = Set(pins.map { $0.descriptor.id })
            pins.removeAll()
            if !ids.isEmpty {
                try? await target.manager.discardMergeAttachments(ids, destinationEpoch: review.destinationEpoch)
            }
            throw error
        }
        if isCurrentVaultMerge(review) {
            _ = try? await reloadAfterWrite(epoch: review.destinationEpoch)
        }
        return entries.count
    }

    private func commitMerge(_ writes: [AccountWrite], review: VaultMergeReview, sourceGeneration: UInt64) async throws {
        let source = review.source.source, target = review.source.target
        let access = try source.currentAccess(), enrollment = review.enrollment
        let cancelled = Mutex(false)
        try await withTaskCancellationHandler {
            _ = try await target.manager.commitAccounts(
                writes, authorizedEpoch: review.destinationEpoch, cause: CredentialChangeCause.merge, expectedRevision: review.destinationRevision
            ) { instant in
                if cancelled.withLock({ $0 }) {
                    throw CancellationError()
                }
                guard access.isAuthorized(at: instant) else { throw CredentialVaultError.unauthorized }
                guard source.contentGeneration == sourceGeneration else { throw CredentialVaultError.staleRevision }
                guard enrollment.isCurrent else { throw VaultMergeError.unavailableDestination }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    @concurrent private static func planEntries(
        _ rows: [CredentialVaultMergePlan.Row], _ choices: [UUID: CredentialVaultMergePlan.Choice], source: StoreSnapshot, destination: StoreSnapshot
    ) async throws -> [CredentialAccount] {
        try Task.checkCancellation()
        return try CredentialVaultMergePlan.replacements(rows: rows, choices: choices, source: source.accounts, destination: destination.accounts)
    }
}
