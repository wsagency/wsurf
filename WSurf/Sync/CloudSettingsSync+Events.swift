// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSettingsSync {
    private func decoded(_ record: SyncRecord) throws -> MacSettingPayload {
        guard record.type == .macSetting, record.schema == 1, record.payload.count <= 768 * 1024,
            let payload = try? JSONDecoder().decode(MacSettingPayload.self, from: record.payload),
            !payload.key.isEmpty, payload.key.utf8.count <= 4096, payload.recordName == record.id.name
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
            let data = try? JSONEncoder().encode(pending), data.count <= 768 * 1024
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
        let payload = try decoded(record)
        let profile = channel.localProfileID
        let category = channel.category
        let before = channel.records[payload.key]?.server
        try channel.receive(payload, fields: record.systemFields, modified: record.modifiedAt) {
            try apply($0, $1, category, profile)
        }
        // Some values, such as a remote camera grant, await local approval in the store.
        if before != channel.records[payload.key]?.server, channel.records[payload.key]?.pending == nil {
            channel.observed[payload.key] = try read(category, profile)[payload.key]
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
            channel.observed[key] = try read(category, profile)[key]
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
                guard !state.channels.isEmpty else { return }
                try await verifyAccount(generation)
                for zone in zones.keys where state.channels[zone] != nil {
                    forget(zone: zone)
                }
                try save()
            case .zoneSavesOverQuota(let zones):
                if zones.contains(where: { state.channels[$0] != nil }) {
                    notice = String(localized: "Your iCloud storage is full. Settings changes are waiting on this Mac.")
                }
            case .fetched(let records, let deleted):
                guard !state.channels.isEmpty else { return }
                try await verifyAccount(generation)
                try fetched(records, deleted: deleted)
            case .sent(let saved, let deleted, let failed):
                guard !state.channels.isEmpty else { return }
                try await verifyAccount(generation)
                try sent(saved, deleted: deleted, failed: failed)
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

    private func fetched(_ records: [SyncRecord], deleted: [SyncRecordID]) throws {
        guard trustedUser != nil, trustedUser == state.account else { return }
        for record in records where state.channels[record.id.zone] != nil {
            if loading[record.id.zone] != nil {
                buffered[record.id.zone, default: []].append(.save(record))
            } else if ready.contains(record.id.zone) {
                try receive(record)
            }
        }
        for id in deleted {
            if loading[id.zone] != nil {
                buffered[id.zone, default: []].append(.remove(id))
            } else if ready.contains(id.zone) {
                try removed(id)
            }
        }
        try save()
    }

    private func sent(_ saved: [SyncRecord], deleted: [SyncRecordID], failed: [SyncFailedSave]) throws {
        guard trustedUser != nil, trustedUser == state.account else { return }
        for record in saved where ready.contains(record.id.zone) {
            let payload = try decoded(record)
            guard var channel = state.channels[record.id.zone] else { continue }
            channel.acknowledge(payload, fields: record.systemFields, modified: record.modifiedAt)
            updateChannel(channel)
        }
        for id in deleted where ready.contains(id.zone) {
            try removed(id)
        }
        for error in failed where ready.contains(error.id.zone) {
            switch error.failure {
            case .serverRecordChanged(let server):
                try receive(server)
            case .unknownItem:
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
