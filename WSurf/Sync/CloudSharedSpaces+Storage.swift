// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation
import WSurfCore

/// The journal contains only the choices revoked against the last saved checkpoint.
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
    }

    private struct Journal: Codable {
        let checkpoint: UUID?
        let choices: Set<OptOut>
    }

    private let url: URL
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
    var pending: Set<OptOut> = []
    var pendingAccountReset: UUID?
    private(set) var unreadableJournal = false

    var hasOptOuts: Bool {
        unreadableJournal || pendingAccountReset != nil || !pending.isEmpty
    }

    init(_ file: URL) {
        url = file
        _ = reload()
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
        do {
            data = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            written = data
        } catch CocoaError.fileReadNoSuchFile {
            data = State()
            written = nil
            readable = true
            return true
        } catch {
            readable = false
            return false
        }
        readable = true
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
            try? files.removeItem(at: journalURL)
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
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
        } catch {
            try writeRecoveryFiles()
            throw error
        }
        written = next
        data = next
        if hasOptOuts {
            pending = []
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
        if readable && (unreadableJournal || !pending.isEmpty) {
            let journal = Journal(checkpoint: written?.checkpoint, choices: pending)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from file: URL) throws -> T? {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }
}
