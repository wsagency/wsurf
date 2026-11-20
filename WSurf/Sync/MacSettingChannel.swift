// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation

nonisolated enum MacSettingsCategory: String, Codable, CaseIterable {
    case websiteSettings = "websites"
    case providers
}

nonisolated struct MacSettingPayload: Codable, Equatable {
    let key: String
    let value: Data?

    var recordName: String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct MacSettingChannel: Codable {
    struct Record: Codable {
        var server: MacSettingPayload?
        var fields: Data?
        var modified: Date?
        var pending: MacSettingPayload?
        /// The engine can finish an earlier save after the user has restored the previous value.
        var inFlight: MacSettingPayload?
        var conflict = false
    }

    let category: MacSettingsCategory
    let localProfileID: UUID?
    let cloudProfileID: UUID?
    var enrollment = UUID()
    var fetched = false
    var lastSync: Date?
    var observed: [String: Data] = [:]
    var records: [String: Record] = [:]
    var zone: String {
        "mac-prefs-" + category.rawValue + (cloudProfileID.map { "-" + $0.uuidString } ?? "")
    }

    /// An absent value is a reset only after this Mac has actually observed the setting.
    mutating func collect(_ values: [String: Data]) {
        for key in Set(values.keys).union(observed.keys) where values[key] != observed[key] {
            let update = MacSettingPayload(key: key, value: values[key])
            var record = records[key] ?? Record()
            record.pending = update
            if update == record.server {
                if record.inFlight == nil || record.inFlight == update {
                    record.pending = nil
                }
                record.conflict = false
            }
            records[key] = record
        }
        observed = values
    }

    mutating func receive(
        _ payload: MacSettingPayload, fields: Data?, modified: Date? = nil,
        apply: (Data?, String) throws -> Void
    ) rethrows {
        var record = records[payload.key] ?? Record()
        if let modified, let last = record.modified, modified < last {
            return
        }
        if record.inFlight == payload {
            acknowledge(payload, fields: fields, modified: modified)
            return
        }
        if record.pending == payload {
            if record.inFlight == nil {
                record.pending = nil
            }
            record.conflict = false
        } else if record.pending != nil {
            if record.server != payload {
                record.conflict = true
            }
        } else if record.server != payload {
            try apply(payload.value, payload.key)
            observed[payload.key] = payload.value
        }
        record.server = payload
        record.fields = fields
        record.modified = modified
        records[payload.key] = record
    }

    mutating func acknowledge(_ payload: MacSettingPayload, fields: Data?, modified: Date?) {
        var record = records[payload.key] ?? Record()
        if let modified, let last = record.modified, modified < last {
            return
        }
        if record.inFlight == payload {
            record.inFlight = nil
        }
        if record.pending == payload && record.inFlight == nil {
            record.pending = nil
            record.conflict = false
        }
        record.server = payload
        record.fields = fields
        record.modified = modified
        records[payload.key] = record
    }

    mutating func resolve(_ key: String, useCloud: Bool, apply: (Data?, String) throws -> Void) rethrows {
        guard var record = records[key], record.conflict else { return }
        if useCloud, let server = record.server {
            try apply(server.value, key)
            observed[key] = server.value
            record.pending = record.inFlight != nil && record.inFlight != server ? server : nil
        }
        record.conflict = false
        records[key] = record
    }
}
