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

/// Each Mac reads the setting. Its sender also checks the enrollment in the encrypted payload on replies.
nonisolated struct MacSettingRecord: Codable {
    let key: String
    let value: Data?
    let enrollment: UUID?

    var setting: MacSettingPayload {
        MacSettingPayload(key: key, value: value)
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data, recordName: String) -> Self? {
        guard data.count <= 768 * 1024, let record = try? JSONDecoder().decode(Self.self, from: data),
              !record.key.isEmpty, record.key.utf8.count <= 4096, record.setting.recordName == recordName else { return nil }
        return record
    }

    init(_ setting: MacSettingPayload, enrollment: UUID) {
        key = setting.key
        value = setting.value
        self.enrollment = enrollment
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
        /// Last shared definition before this enrollment handed an obsolete provider reset to the engine.
        var valueBeforePrivateReset: Data?
        /// The sampled value follows the cloud while the endpoint is private on this Mac.
        var followsSharedProvider: Bool?
        var conflict = false
    }

    let category: MacSettingsCategory
    let localProfileID: UUID?
    let cloudProfileID: UUID?
    var enrollment = UUID()
    /// Optional on disk for checkpoints written before per-enrollment approval.
    var awaitingAccountConfirmation: Bool? = true
    var needsConfirmation: Bool {
        awaitingAccountConfirmation != false
    }
    var fetched = false
    /// An app-deletion notice can outlive this enrollment. A full read checks whether the zone still exists.
    var checkingDeletion: Bool?
    var lastSync: Date?
    var observed: [String: Data] = [:]
    var records: [String: Record] = [:]
    var zone: String {
        "mac-prefs-" + category.rawValue + (cloudProfileID.map { "-" + $0.uuidString } ?? "")
    }

    /// A provider with a private endpoint follows its shared definition until the owner shares an edit or removes it.
    mutating func preserveLocalOnlyProviders(_ keys: Set<String>, in values: inout [String: Data]) {
        for (key, var record) in records where !keys.contains(key)
            && (record.followsSharedProvider == true || record.valueBeforePrivateReset != nil) {
            record.followsSharedProvider = nil
            record.valueBeforePrivateReset = nil
            observed[key] = record.server?.value
            let choice = MacSettingPayload(key: key, value: values[key])
            record.pending = nil
            if let inFlight = record.inFlight, inFlight != choice {
                record.pending = choice
            }
            records[key] = record
        }
        for key in keys {
            guard var record = records[key] else {
                observed[key] = nil
                continue
            }
            if record.valueBeforePrivateReset == nil {
                if record.inFlight == MacSettingPayload(key: key, value: nil) {
                    record.valueBeforePrivateReset = record.server?.value ?? observed[key]
                }
                record.pending = nil
            }
            record.followsSharedProvider = true
            record.conflict = false
            records[key] = record
            let shared = record.pending?.value ?? record.server?.value
            values[key] = shared
            observed[key] = shared
        }
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
        _ payload: MacSettingPayload, from sender: UUID? = nil, fields: Data?, modified: Date? = nil,
        apply: (Data?, String) throws -> Void
    ) rethrows {
        var record = records[payload.key] ?? Record()
        if let modified, let last = record.modified, modified < last {
            return
        }
        if sender == enrollment && record.inFlight == payload {
            acknowledge(payload, fields: fields, modified: modified)
            return
        }
        if record.valueBeforePrivateReset != nil {
            let reset = MacSettingPayload(key: payload.key, value: nil)
            if record.server != payload {
                try apply(payload.value, payload.key)
            }
            // The conditional reset can still land only while the fetched revision matches its base.
            if payload != reset || sender != enrollment {
                let awaitingReset = record.inFlight == reset && record.fields == fields && payload.value != nil
                record.pending = nil
                if !awaitingReset {
                    record.valueBeforePrivateReset = nil
                    record.inFlight = nil
                }
            }
            observed[payload.key] = record.pending?.value ?? payload.value
        } else if record.pending == payload {
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
            if payload.value == nil, let retained = record.valueBeforePrivateReset {
                record.pending = MacSettingPayload(key: payload.key, value: retained)
            } else {
                record.valueBeforePrivateReset = nil
            }
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
