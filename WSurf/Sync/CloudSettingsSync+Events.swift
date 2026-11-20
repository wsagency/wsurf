// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSettingsSync {
    private func decoded(_ record: SyncRecord) throws -> MacSettingRecord {
        guard record.type == .macSetting, record.schema == 1,
            let payload = MacSettingRecord.decode(record.payload, recordName: record.id.name)
        else {
            throw Issue.invalidRecord
        }
        return payload
    }

    func queuePending(_ zone: String) {
        guard ready.contains(zone), sendingAllowed, trustedUser != nil, trustedUser == state.account,
            let channel = state.channels[zone]
        else { return }
        let edits = channel.records.values.compactMap { record -> SyncChange? in
            guard let payload = record.pending, !record.conflict else { return nil }
            let id = SyncRecordID(zone: zone, name: payload.recordName)
            names[id] = payload.key
            return .saveRecord(id)
        }
        if !edits.isEmpty {
            engine?.add(edits)
        }
    }

    func record(for id: SyncRecordID) -> SyncRecord? {
        guard ready.contains(id.zone), sendingAllowed, trustedUser != nil, trustedUser == state.account,
            let key = names[id], var channel = state.channels[id.zone], let record = channel.records[key],
            !record.conflict, let pending = record.pending, pending.recordName == id.name,
            let data = try? MacSettingRecord(pending, enrollment: channel.enrollment).encoded(),
            data.count <= 768 * 1024
        else { return nil }
        if record.inFlight != pending {
            channel.records[key]?.inFlight = pending
            updateChannel(channel)
            do {
                try save()
            } catch {
                reportError()
                return nil
            }
        }
        return SyncRecord(id: id, type: .macSetting, schema: 1, payload: data, systemFields: record.fields)
    }

    func receive(_ record: SyncRecord) throws {
        guard var channel = state.channels[record.id.zone] else { return }
        let payload = try decoded(record).setting
        let profile = channel.localProfileID
        let category = channel.category
        let before = channel.records[payload.key]?.server
        try channel.receive(payload, fields: record.systemFields, modified: record.modifiedAt) {
            try apply($0, $1, category, profile)
        }
        // Some values, such as a remote camera grant, await local approval in the store.
        if before != channel.records[payload.key]?.server, channel.records[payload.key]?.pending == nil {
            let values = try snapshot(&channel)
            channel.observed[payload.key] = values[payload.key]
        }
        names[record.id] = payload.key
        updateChannel(channel)
    }

    func removed(_ id: SyncRecordID) throws {
        guard var channel = state.channels[id.zone], let key = names[id],
            let record = channel.records[key], record.server != nil
        else { return }
        let profile = channel.localProfileID
        let category = channel.category
        try channel.receive(MacSettingPayload(key: key, value: nil), fields: nil) {
            try apply($0, $1, category, profile)
        }
        if channel.records[key]?.pending == nil {
            let values = try snapshot(&channel)
            channel.observed[key] = values[key]
        }
        updateChannel(channel)
    }

    func handle(_ event: SyncEvent) async {
        do {
            switch event {
            case .state, .zoneDeletesFailed:
                return
            case .account(let change):
                if accountNotifications != nil {
                    refreshAccountVerification()
                }
                switch change {
                case .signOut:
                    try resetAccount(to: nil)
                case .switchAccounts(let user):
                    try resetAccount(to: user)
                case .signIn(let user):
                    if let previous = state.account, previous != user {
                        try resetAccount(to: user)
                    }
                    beat()
                }
            case .zonesDeleted(let zones):
                try await zonesDeleted(zones)
            case .zoneSavesOverQuota(let zones):
                if zones.contains(where: { state.channels[$0] != nil }) {
                    notice = String(localized: "Your iCloud storage is full. Settings changes are waiting on this Mac.")
                }
            case .fetched(let records, let deleted):
                guard !state.channels.isEmpty else { return }
                try await verifyAccount(generation)
                try fetched(records, deleted: deleted)
            case .sent(let saved, _, let failed):
                guard !state.channels.isEmpty else { return }
                try await verifyAccount(generation)
                try sent(saved, failed: failed)
            }
        } catch {
            // An unrecognized future record must not be overwritten by this version.
            switch event {
            case .fetched(let records, _):
                ready.subtract(records.map { $0.id.zone })
            case .sent(let records, _, let failed):
                ready.subtract(records.map { $0.id.zone } + failed.map { $0.id.zone })
            default:
                break
            }
            reportError()
        }
    }

    private func zonesDeleted(_ zones: [String: SyncZoneDeletionReason]) async throws {
        let enrolled = state.channels.filter { zones[$0.key] != nil && !$0.value.needsConfirmation }.mapValues(\.enrollment)
        guard !enrolled.isEmpty else { return }
        let started = generation
        try await verifyAccount(started)
        guard generation == started else { return }
        for (zone, epoch) in enrolled where state.channels[zone]?.enrollment == epoch {
            forget(zone: zone)
        }
        try save()
    }

    private func fetched(_ records: [SyncRecord], deleted: [SyncRecordID]) throws {
        guard trustedUser != nil, trustedUser == state.account else { return }
        let modifiedByZone = Dictionary(grouping: records) { $0.id.zone }
        let removedByZone = Dictionary(grouping: deleted) { $0.zone }
        for zone in Set(modifiedByZone.keys).union(removedByZone.keys) where state.channels[zone] != nil {
            let modified = modifiedByZone[zone] ?? []
            let deletions = removedByZone[zone] ?? []
            if loading[zone] != nil {
                buffered[zone, default: []] += modified.map(BufferedChange.save) + deletions.map(BufferedChange.remove)
            } else if ready.contains(zone) {
                do {
                    try collectLocalChanges(in: zone)
                    try modified.forEach(receive)
                    try deletions.forEach(removed)
                } catch {
                    ready.remove(zone)
                    reportError()
                }
            }
        }
        try save()
    }

    private func currentSubmission(_ record: SyncRecord) -> MacSettingPayload? {
        guard ready.contains(record.id.zone), let channel = state.channels[record.id.zone],
            let submitted = try? decoded(record), submitted.enrollment == channel.enrollment,
            channel.records[submitted.key]?.inFlight == submitted.setting
        else { return nil }
        return submitted.setting
    }

    private func sent(_ saved: [SyncRecord], failed: [SyncFailedSave]) throws {
        guard trustedUser != nil, trustedUser == state.account else { return }
        for record in saved {
            guard let payload = currentSubmission(record), var channel = state.channels[record.id.zone] else { continue }
            channel.acknowledge(payload, fields: record.systemFields, modified: record.modifiedAt)
            updateChannel(channel)
        }
        // A reset is a saved setting. This channel never submits a physical record deletion.
        for error in failed {
            guard let attempted = error.attempted, attempted.id == error.id, currentSubmission(attempted) != nil else { continue }
            switch error.failure {
            case .serverRecordChanged(let server):
                try collectLocalChanges(in: error.id.zone)
                try receive(server)
            case .unknownItem:
                try collectLocalChanges(in: error.id.zone)
                try removed(error.id)
            case .zoneNotFound:
                forget(zone: error.id.zone)
            case .quotaExceeded, .other:
                reportError()
            }
        }
        try save()
        // A newer local edit can be waiting behind the one that just finished.
        for zone in Set(saved.map { $0.id.zone }) {
            queuePending(zone)
        }
    }

    func reconcileDeletions(in zone: String, seen: Set<SyncRecordID>) throws {
        guard let records = state.channels[zone]?.records else { return }
        for (key, record) in records {
            guard let server = record.server else { continue }
            let id = SyncRecordID(zone: zone, name: server.recordName)
            names[id] = key
            if !seen.contains(id) {
                try removed(id)
            }
        }
    }
}
