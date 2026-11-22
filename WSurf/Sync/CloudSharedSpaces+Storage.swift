// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation
import WSurfCore

/// Keeps local revocations replayable until the catalog checkpoint includes them.
@Observable
final class SharedCatalogStorage {
    struct OptOut: Codable, Hashable {
        let category: SharedCatalogCategory
        let profile: UUID
        var item: UUID?
    }

    struct State: Codable, Equatable {
        var catalog = SharedCatalogState()
        var links: [UUID: SharedProfileLinks] = [:]
        var pausedLinks: [String: [UUID: SharedProfileLinks]]?
        var checkpoint: UUID?
        var appliedAccountReset: UUID?

        var localProfileIDs: Set<UUID> {
            var owners = catalog.localProfileIDs.union(links.keys)
            for parked in (pausedLinks ?? [:]).values {
                owners.formUnion(parked.keys)
            }
            return owners
        }
    }

    private struct Journal: Codable {
        let checkpoint: UUID?
        let choices: Set<OptOut>
        var erasingProfiles: Set<UUID>?
        /// Removals requested before the checkpoint could be read.
        var unboundProfiles: Set<UUID>?
    }

    private let url: URL
    private let profilesAvailable: () -> Bool
    private var journalURL: URL {
        url.appendingPathExtension("opt-outs")
    }
    private var accountResetURL: URL {
        url.appendingPathExtension("account-reset")
    }
    @ObservationIgnored var data = State()
    @ObservationIgnored private var written: State?
    @ObservationIgnored var applyingOptOuts = false
    private(set) var readable = false
    var needsReload: Bool {
        // Both files can be missing at launch. Pick up a returning checkpoint before the first local change.
        !readable || (written == nil && data == State() && FileManager.default.fileExists(atPath: url.path))
    }
    var pending: Set<OptOut> = []
    private(set) var erasingProfiles: Set<UUID> = []
    private var unboundProfiles: Set<UUID> = []
    var pendingAccountReset: UUID?
    private(set) var unreadableJournal = false

    var hasOptOuts: Bool {
        unreadableJournal || pendingAccountReset != nil || !pending.isEmpty || !erasingProfiles.isEmpty
    }

    init(_ file: URL, profilesAvailable: @escaping () -> Bool) {
        url = file
        self.profilesAvailable = profilesAvailable
        _ = reload()
    }

    func reconcileProfiles(with liveIDs: Set<UUID>) {
        erasingProfiles.formUnion(data.localProfileIDs.subtracting(liveIDs))
    }

    func requestProfileRemoval(_ id: UUID) throws {
        erasingProfiles.insert(id)
        guard !readable else { return }
        // Keep earlier choices bound to their original checkpoint while recording this removal.
        unboundProfiles.insert(id)
        var journal = try read(Journal.self, from: journalURL) ?? Journal(checkpoint: nil, choices: [])
        journal.unboundProfiles = (journal.unboundProfiles ?? []).union(unboundProfiles)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    /// A temporarily unreadable checkpoint may contain other enrollments and links. Wait for it before replacing it.
    func reload() -> Bool {
        let files = FileManager.default
        let journal: Journal?
        unreadableJournal = false
        do {
            do {
                let reset = try read(UUID.self, from: accountResetURL)
                pendingAccountReset = pendingAccountReset ?? reset
            } catch is DecodingError {
                pendingAccountReset = pendingAccountReset ?? UUID()
            }
            journal = try read(Journal.self, from: journalURL)
        } catch is DecodingError {
            unreadableJournal = true
            journal = nil
        } catch {
            // An inaccessible journal can still hold valid choices. Do not replace it or its checkpoint.
            unreadableJournal = true
            readable = false
            return false
        }
        pending.formUnion(journal?.choices ?? [])
        erasingProfiles.formUnion(journal?.erasingProfiles ?? [])
        unboundProfiles.formUnion(journal?.unboundProfiles ?? [])
        defer { erasingProfiles.formUnion(unboundProfiles) }
        do {
            let saved = try read(State.self, from: url)
            // Personal exists on every Mac. Named owners need the profile list before we can reconcile this checkpoint.
            guard profilesAvailable() || (saved?.localProfileIDs.isSubset(of: [Profile.originalID]) ?? (!hasOptOuts && unboundProfiles.isEmpty)) else {
                readable = false
                return false
            }
            written = saved
            data = saved ?? State()
            // A per-item enrollment never authorized the whole library. Keep its mappings and outbox for an explicit opt-in.
            if let enabled = data.catalog.enabled[.pins] {
                let links = data.links
                data.catalog.enabled[.pins] = enabled.filter { links[$0]?.sharesPinLibrary == true }
            }
            readable = true
            guard saved != nil else { return true }
        } catch {
            readable = false
            return false
        }
        if let reset = pendingAccountReset, reset == data.appliedAccountReset {
            pendingAccountReset = nil
            try? files.removeItem(at: accountResetURL)
        }
        if unreadableJournal {
            // A damaged revocation list cannot authorize any prior enrollment.
            pending = Set(data.catalog.enabled.flatMap { category, profiles in
                profiles.map { OptOut(category: category, profile: $0) }
            })
            for (profile, link) in data.links {
                pending.formUnion(link.spaces.keys.map { OptOut(category: .spaces, profile: profile, item: $0) })
                pending.formUnion(link.pins.keys.map { OptOut(category: .pins, profile: profile, item: $0) })
            }
        } else if let journal, journal.checkpoint != data.checkpoint {
            // The checkpoint advanced before a previous process could remove its journal.
            pending = []
            erasingProfiles = []
            if unboundProfiles.isEmpty {
                try? files.removeItem(at: journalURL)
            }
        }
        return true
    }

    func write() throws {
        guard !applyingOptOuts else { return }
        guard readable else {
            try writeRecoveryFiles()
            throw SharedCatalogError.storage
        }
        guard written != data || hasOptOuts else { return }
        var next = data
        next.checkpoint = UUID()
        next.appliedAccountReset = pendingAccountReset ?? data.appliedAccountReset
        let files = FileManager.default
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !unboundProfiles.isEmpty {
                // Bind these removals before advancing the checkpoint. A stale journal must allow a later enrollment.
                try writeBoundJournal()
                unboundProfiles = []
            }
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
        } catch {
            try writeRecoveryFiles()
            throw error
        }
        written = next
        data = next
        if hasOptOuts {
            pending = []
            erasingProfiles = []
            if pendingAccountReset != nil {
                pendingAccountReset = nil
                try? files.removeItem(at: accountResetURL)
            }
            unreadableJournal = false
            try? files.removeItem(at: journalURL)
        }
    }

    private func writeRecoveryFiles() throws {
        // Sign-out must survive even when the item journal is temporarily unreadable.
        if let reset = pendingAccountReset {
            try JSONEncoder().encode(reset).write(to: accountResetURL, options: .atomic)
        }
        if readable && (unreadableJournal || !pending.isEmpty || !erasingProfiles.isEmpty) {
            try writeBoundJournal()
        }
    }

    private func writeBoundJournal() throws {
        let journal = Journal(checkpoint: written?.checkpoint, choices: pending, erasingProfiles: erasingProfiles.isEmpty ? nil : erasingProfiles)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from file: URL) throws -> T? {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }
}
