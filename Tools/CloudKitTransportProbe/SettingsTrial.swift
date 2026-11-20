// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation

/// The enrollment identifies a physical model only for this nonce. Neither model name goes to CloudKit.
extension Trial {
    var settingsEnrollment: UUID {
        let b = [UInt8](deviceTag.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], (b[6] & 0x0f) | 0x40, b[7],
                           (b[8] & 0x3f) | 0x80, b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

struct SettingsTrial {
    enum Phase {
        case initial, answer, reset
    }

    let trial: Trial
    let creator: UUID
    let responder: UUID

    init(trial: Trial, peer: UUID, answering: Bool) throws {
        let local = trial.settingsEnrollment
        guard local != peer else { throw ProbeError.useSecondMac }
        self.trial = trial
        creator = answering ? peer : local
        responder = answering ? local : peer
    }

    private var key: String { "zoom|trial-" + trial.token + ".invalid" }

    private var recordID: SyncRecordID {
        // App-created profiles use random version-4 UUIDs. Reserve a version-8 UUID derived from this trial for its zone.
        var profile = trial.nonce.uuid
        profile.6 = (profile.6 & 0x0f) | 0x80
        let channel = MacSettingChannel(category: .websiteSettings, localProfileID: nil, cloudProfileID: UUID(uuid: profile))
        return SyncRecordID(zone: channel.zone, name: MacSettingPayload(key: key, value: nil).recordName)
    }

    var id: CKRecord.ID {
        CloudKitMapping.recordID(recordID)
    }

    private var receipt: URL {
        trial.directory.appendingPathComponent("wsurf-settings-" + trial.token + ".receipt")
    }

    private var ownership: Data {
        Data(["WSurf MacSetting trial v1", trial.token, creator.uuidString, responder.uuidString].joined(separator: "\n").utf8)
    }

    func reserve() throws {
        guard creator == trial.settingsEnrollment else { throw ProbeError.differentCreator }
        if FileManager.default.fileExists(atPath: receipt.path) {
            try requireReceipt()
            return
        }
        try trial.reserve(ownership, at: receipt)
    }

    private func requireReceipt() throws {
        guard creator == trial.settingsEnrollment, (try? Data(contentsOf: receipt)) == ownership else { throw ProbeError.receiptRequired }
    }

    private func envelope(_ phase: Phase) throws -> MacSettingRecord {
        let level: Double?
        let enrollment: UUID
        switch phase {
        case .initial:
            (level, enrollment) = (1.25, creator)
        case .answer:
            (level, enrollment) = (1.5, responder)
        case .reset:
            (level, enrollment) = (nil, trial.nonce)
        }
        let value = try level.map { try JSONEncoder().encode($0) }
        return MacSettingRecord(MacSettingPayload(key: key, value: value), enrollment: enrollment)
    }

    /// Only the private trial's known key, exact enrolled sender, zoom and field set may be replaced.
    private func read(_ record: CKRecord) throws -> (Phase, SyncRecord) {
        guard record.recordID == id, record.recordType == SyncRecordType.macSetting.rawValue,
              Set(record.allKeys()).isSubset(of: [CloudKitMapping.schemaKey, CloudKitMapping.payloadKey]),
              Set(record.encryptedValues.allKeys()) == [CloudKitMapping.payloadKey],
              record[CloudKitMapping.schemaKey] as? Int == 1,
              let mapped = CloudKitMapping.syncRecord(record),
              let decoded = MacSettingRecord.decode(mapped.payload, recordName: mapped.id.name), decoded.key == key,
              let fields = try? JSONSerialization.jsonObject(with: mapped.payload) as? [String: Any],
              Set(fields.keys) == (decoded.value == nil ? ["key", "enrollment"] : ["key", "enrollment", "value"])
        else { throw ProbeError.unexpectedRecord }
        for phase in [Phase.initial, .answer, .reset] {
            let known = try envelope(phase)
            if decoded.enrollment == known.enrollment && decoded.setting == known.setting {
                return (phase, mapped)
            }
        }
        throw ProbeError.unexpectedRecord
    }

    private func save(_ phase: Phase, replacing previous: CKRecord?, fields: Data?, in db: any ProbeDatabase) async throws {
        let data = try envelope(phase).encoded()
        let record = SyncRecord(id: recordID, type: .macSetting, schema: 1, payload: data, systemFields: fields)
        try await db.saveVersion(CloudKitMapping.ckRecord(record), observed: previous)
    }

    func start(in db: any ProbeDatabase) async throws {
        try requireReceipt()
        try await db.ensureZone(id.zoneID)
        if let existing = try await db.fetch(id) {
            guard try read(existing).0 != .reset else { throw ProbeError.alreadyCleaned }
        } else {
            try await save(.initial, replacing: nil, fields: nil, in: db)
        }
    }

    func answer(in db: any ProbeDatabase) async throws {
        guard responder == trial.settingsEnrollment else { throw ProbeError.useSecondMac }
        guard let existing = try await db.fetch(id) else { throw ProbeError.awaitingOtherMac }
        let (phase, mapped) = try read(existing)
        switch phase {
        case .initial:
            try await save(.answer, replacing: existing, fields: mapped.systemFields, in: db)
        case .answer:
            return
        case .reset:
            throw ProbeError.alreadyCleaned
        }
    }

    func confirm(in db: any ProbeDatabase) async throws {
        try requireReceipt()
        guard let existing = try await db.fetch(id), try read(existing).0 == .answer else { throw ProbeError.awaitingOtherMac }
        try await db.verifyMetadata(of: existing)
    }

    /// CloudKit keeps the encrypted production reset in this otherwise disposable zone. A whole-zone delete could remove a neighbor.
    func clean(in db: any ProbeDatabase) async throws {
        try requireReceipt()
        guard let existing = try await db.fetch(id) else { throw ProbeError.awaitingOtherMac }
        let (phase, mapped) = try read(existing)
        if phase != .reset {
            try await save(.reset, replacing: existing, fields: mapped.systemFields, in: db)
        }
        guard let saved = try await db.fetch(id), try read(saved).0 == .reset else { throw ProbeError.unexpectedRecord }
    }
}

/// Mirrors the production asset cache's concrete-owner request and exact dictionary subscript on this synthetic record.
func verifyExplicitMetadata(
    id: CKRecord.ID, type: String, expectedTag: String?, user: () async throws -> String,
    fetch: (CKRecord.ID, [CKRecord.FieldKey]) async throws -> [CKRecord.ID: Result<(String, String?), any Error>]
) async throws {
    let owner = try await user()
    guard !owner.isEmpty, owner != CKCurrentUserDefaultName, let expectedTag else { throw ProbeError.explicitOwnerUnavailable }
    let zone = CKRecordZone.ID(zoneName: id.zoneID.zoneName, ownerName: owner)
    let requested = CKRecord.ID(recordName: id.recordName, zoneID: zone)
    let results = try await fetch(requested, [])
    guard let result = results[requested] else {
        if results.keys.contains(where: { $0.recordName == requested.recordName && $0.zoneID.zoneName == zone.zoneName }) {
            throw ProbeError.metadataKeyNormalized
        }
        throw ProbeError.metadataResultMissing
    }
    let (receivedType, tag) = try result.get()
    guard try await user() == owner else { throw ProbeError.explicitOwnerUnavailable }
    guard receivedType == type, tag == expectedTag else { throw ProbeError.metadataTagMismatch }
}

func settingsCommand(
    _ args: [String], model: String, directory: URL, database: () throws -> any ProbeDatabase
) async throws {
    guard args.count >= 2 else { throw ProbeError.usage }
    let base = try Trial(token: args[1], model: model, directory: directory)
    if args[0] == "settings-tag", args.count == 2 {
        print(base.settingsEnrollment.uuidString.lowercased())
        return
    }
    guard args.count == 3, let peer = UUID(uuidString: args[2]), peer.uuidString.lowercased() == args[2].lowercased() else {
        throw ProbeError.usage
    }
    let trial = try SettingsTrial(trial: base, peer: peer, answering: args[0] == "settings-answer")
    switch args[0] {
    case "settings-begin":
        try trial.reserve()
        try await trial.start(in: database())
        print("PASS Studio wrote 125%.")
    case "settings-resume":
        try await trial.start(in: database())
        print("PASS Studio recovered the owned record.")
    case "settings-answer":
        try await trial.answer(in: database())
        print("PASS Air acknowledged the trial at 150%.")
    case "settings-confirm":
        try await trial.confirm(in: database())
        print("PASS Studio read the 150% reply.")
        print("PASS explicit-owner metadata matched its full-record tag.")
    case "settings-cleanup":
        try await trial.clean(in: database())
        print("PASS Studio verified the stored reset.")
    default:
        throw ProbeError.usage
    }
}
