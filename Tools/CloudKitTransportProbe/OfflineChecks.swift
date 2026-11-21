// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation

private enum FixtureError: Error {
    case lostReply, conflict, wrongOwner, assertionFailed
}

// A fetch returns a detached snapshot. A save succeeds only against its observed revision, as in CKDatabase.saveVersion.
private final class OfflineDatabase: ProbeDatabase {
    struct Row: Equatable {
        let revision: Int
        let payload: Data
        var type = "Device"
        var schema: Int?
    }

    var zone: CKRecordZone.ID?
    var rows: [CKRecord.ID: Row] = [:]
    var owner = "offline-owner"
    var switchAfterFetch = false
    var switchBeforeSave = false
    var unauthenticatedSave = false
    var loseZoneReply = false
    var loseSaveReply = false
    var changeBeforeSave = false
    var normalizeMetadataKey = false
    var staleMetadata = false
    private var fetched: [ObjectIdentifier: (CKRecord, Int)] = [:]

    func currentOwner() async throws -> String {
        owner
    }

    func ensureZone(_ id: CKRecordZone.ID) async throws {
        if let zone {
            precondition(zone == id)
        }
        zone = id
        if loseZoneReply {
            loseZoneReply = false
            throw FixtureError.lostReply
        }
    }

    func fetch(_ id: CKRecord.ID) async throws -> CKRecord? {
        if switchAfterFetch {
            owner = "offline-other"
            switchAfterFetch = false
        }
        guard id.zoneID == zone, let row = rows[id] else { return nil }
        let record = CKRecord(recordType: row.type, recordID: id)
        record["schemaVersion"] = row.schema.map { NSNumber(value: $0) }
        record.encryptedValues["payload"] = row.payload
        fetched[ObjectIdentifier(record)] = (record, row.revision)
        return record
    }

    func saveVersion(_ record: CKRecord, observed: CKRecord?) async throws {
        let id = record.recordID
        if switchBeforeSave {
            switchBeforeSave = false
            owner = "offline-other"
        }
        guard id.zoneID.ownerName == CKCurrentUserDefaultName || id.zoneID.ownerName == owner else { throw FixtureError.wrongOwner }
        if unauthenticatedSave {
            unauthenticatedSave = false
            throw CKError(.notAuthenticated)
        }
        guard id.zoneID == zone, let payload = record.encryptedValues["payload"] as? Data else { throw FixtureError.assertionFailed }
        let previous = observed.flatMap { fetched.removeValue(forKey: ObjectIdentifier($0))?.1 }
        if changeBeforeSave {
            changeBeforeSave = false
            rows[id] = Row(revision: (rows[id]?.revision ?? 0) + 1, payload: Data("concurrent write".utf8))
        }
        guard previous == rows[id]?.revision else { throw FixtureError.conflict }
        rows[id] = Row(revision: (previous ?? 0) + 1, payload: payload, type: record.recordType, schema: record["schemaVersion"] as? Int)
        if loseSaveReply {
            loseSaveReply = false
            throw FixtureError.lostReply
        }
    }

    func verifyMetadata(of record: CKRecord) async throws {
        guard let revision = fetched[ObjectIdentifier(record)]?.1 else { throw FixtureError.assertionFailed }
        let id = record.recordID
        try await verifyExplicitMetadata(id: id, type: record.recordType, expectedTag: String(revision), user: { self.owner }, fetch: { requested, keys in
            guard keys.isEmpty, requested.recordName == id.recordName, requested.zoneID.zoneName == id.zoneID.zoneName,
                  requested.zoneID.ownerName == "offline-owner", let row = self.rows[id] else { throw FixtureError.assertionFailed }
            let alias = CKRecordZone.ID(zoneName: id.zoneID.zoneName, ownerName: CKCurrentUserDefaultName)
            let key = self.normalizeMetadataKey ? CKRecord.ID(recordName: id.recordName, zoneID: alias) : requested
            return [key: .success((row.type, String(row.revision + (self.staleMetadata ? 1 : 0))))]
        })
    }
}

private func expect<Failure: Error & Equatable>(_ expected: Failure, _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as Failure where error == expected {
        return
    }
    throw FixtureError.assertionFailed
}

func offlineChecks() async throws {
    let files = FileManager.default
    let scratch = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent(UUID().uuidString)
    let otherDirectory = scratch.appendingPathComponent("another-directory")
    try files.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }
    let studio = Trial(model: "test-studio", directory: scratch)
    let copied = try Trial(token: studio.token, model: "test-studio", directory: otherDirectory)
    let air = try Trial(token: studio.token, model: "test-air", directory: otherDirectory)
    let other = Trial(model: "test-studio", directory: scratch)
    precondition(studio.deviceTag == copied.deviceTag && studio.deviceTag != air.deviceTag && studio.deviceTag != other.deviceTag)
    precondition(studio.recordID != other.recordID && studio.recordID.zoneID == other.recordID.zoneID)
    for invalid in ["devices", "00000000-0000-1000-8000-000000000000", "00000000-0000-4000-0000-000000000000"] {
        precondition((try? Trial(token: invalid, model: "fixture", directory: scratch)) == nil)
    }

    let db = OfflineDatabase()
    try await expect(ProbeError.receiptRequired) { try await studio.start(in: db) }
    precondition(db.zone == nil && db.rows.isEmpty)
    try studio.reserve()
    db.loseZoneReply = true
    try await expect(FixtureError.lostReply) { try await studio.start(in: db) }
    precondition(db.zone == Trial.zoneID && db.rows.isEmpty && files.fileExists(atPath: studio.receipt.path))
    db.loseSaveReply = true
    try await expect(FixtureError.lostReply) { try await studio.start(in: db) }
    let first = db.rows[studio.recordID]
    try await studio.start(in: db)
    precondition(first != nil && db.rows[studio.recordID] == first)
    try await expect(ProbeError.useSecondMac) { try await copied.answer(in: db) }
    try await expect(ProbeError.awaitingOtherMac) { try await studio.confirm(in: db) }
    try await air.answer(in: db)
    let answered = db.rows[studio.recordID]
    try await air.answer(in: db)
    precondition(db.rows[studio.recordID] == answered)
    try await studio.confirm(in: db)
    try await expect(ProbeError.receiptRequired) { try await air.clean(in: db) }
    try files.copyItem(at: studio.receipt, to: air.receipt)
    try await expect(ProbeError.receiptRequired) { try await air.clean(in: db) }

    let neighbor = CKRecord.ID(recordName: "foreign-record", zoneID: Trial.zoneID)
    let foreign = OfflineDatabase.Row(revision: 1, payload: Data("foreign data".utf8))
    db.rows[neighbor] = foreign
    db.loseSaveReply = true
    try await expect(FixtureError.lostReply) { try await studio.clean(in: db) }
    try await studio.clean(in: db)
    precondition(db.rows[studio.recordID]?.payload == Data() && db.rows[neighbor] == foreign && db.zone == Trial.zoneID)
    try await expect(ProbeError.alreadyCleaned) { try await studio.start(in: db) }

    try other.reserve()
    try await other.start(in: db)
    db.changeBeforeSave = true
    try await expect(FixtureError.conflict) { try await other.clean(in: db) }
    try await expect(ProbeError.unexpectedRecord) { try await other.clean(in: db) }
    precondition(db.rows[other.recordID]?.payload == Data("concurrent write".utf8))
    let extended = Marker(version: 2, nonce: other.token, creator: other.deviceTag)
    var fields = try JSONSerialization.jsonObject(with: extended.encoded()) as? [String: Any] ?? [:]
    fields["otherData"] = "foreign data"
    let extra = OfflineDatabase.Row(revision: 3, payload: try JSONSerialization.data(withJSONObject: fields))
    db.rows[other.recordID] = extra
    try await expect(ProbeError.unexpectedRecord) { try await other.clean(in: db) }
    precondition(db.rows[other.recordID] == extra)
    let foundOnOtherAccount = try await other.clean(in: OfflineDatabase())
    precondition(!foundOnOtherAccount && files.fileExists(atPath: other.receipt.path) && db.rows[neighbor] == foreign)
    try await settingsChecks(studio: studio, air: air, copied: copied, other: other)
    print("Offline checks passed.")
}

private func settingsChecks(studio: Trial, air: Trial, copied: Trial, other: Trial) async throws {
    let db = OfflineDatabase()
    let account = try studio.settingsAccount(owner: db.owner)
    try await expect(ProbeError.usage) {
        try await settingsCommand(["settings-begin", studio.token], model: studio.model, directory: studio.directory,
                                  database: { throw FixtureError.assertionFailed })
    }
    let a = try SettingsTrial(trial: studio, peer: air.settingsEnrollment, answering: false, owner: db.owner, account: account)
    let b = try SettingsTrial(trial: air, peer: studio.settingsEnrollment, answering: true, owner: db.owner, account: account)
    let otherAccount = try other.settingsAccount(owner: db.owner)
    precondition(account != otherAccount && account.count == 64)
    let unrelated = try SettingsTrial(trial: other, peer: air.settingsEnrollment, answering: false, owner: db.owner, account: otherAccount)
    precondition(a.id == b.id && a.id.zoneID != unrelated.id.zoneID && a.id != studio.recordID)
    precondition(a.id.zoneID.ownerName == db.owner)
    try await expect(ProbeError.useSecondMac) {
        _ = try SettingsTrial(trial: copied, peer: studio.settingsEnrollment, answering: true, owner: db.owner, account: account)
    }
    try await expect(ProbeError.receiptRequired) { try await a.start(in: db) }
    precondition(db.zone == nil && db.rows.isEmpty)
    let receipt = try a.issueReceipt()
    guard let bytes = Data(base64Encoded: receipt), let decoded = String(data: bytes, encoding: .utf8),
          decoded.contains(account), !decoded.contains(db.owner) else { throw FixtureError.assertionFailed }
    try b.restoreReceipt(receipt)
    try await expect(ProbeError.receiptRequired) { try unrelated.restoreReceipt(receipt) }
    db.loseSaveReply = true
    try await expect(FixtureError.lostReply) { try await a.start(in: db) }
    let switched = OfflineDatabase()
    switched.owner = "offline-other"
    try await expect(ProbeError.originalAccountRequired) {
        _ = try SettingsTrial(trial: studio, peer: air.settingsEnrollment, answering: false, owner: switched.owner, account: account)
    }
    try await expect(ProbeError.originalAccountRequired) {
        _ = try SettingsTrial(trial: air, peer: studio.settingsEnrollment, answering: true, owner: switched.owner, account: account)
    }
    try await expect(ProbeError.originalAccountRequired) {
        try await settingsCommand(["settings-begin", studio.token, air.settingsEnrollment.uuidString, account, receipt],
                                  model: studio.model, directory: studio.directory, database: { switched })
    }
    try await expect(ProbeError.originalAccountRequired) { try await a.start(in: switched) }
    try await expect(ProbeError.originalAccountRequired) { try await b.answer(in: switched) }
    try await expect(ProbeError.originalAccountRequired) { try await a.confirm(in: switched) }
    try await expect(ProbeError.originalAccountRequired) { try await a.clean(in: switched) }
    guard switched.zone == nil, switched.rows.isEmpty, db.rows[a.id] != nil else {
        print("FAIL: a retry after a lost first write created a second account's trial")
        throw FixtureError.assertionFailed
    }
    let otherZone = CKRecordZone.ID(zoneName: a.id.zoneID.zoneName, ownerName: switched.owner)
    switched.zone = otherZone
    let decoy = CKRecord.ID(recordName: a.id.recordName, zoneID: otherZone)
    switched.rows[decoy] = db.rows[a.id]
    try await expect(ProbeError.originalAccountRequired) { try await a.clean(in: switched) }
    precondition(switched.rows[decoy] == db.rows[a.id])
    // A fresh Studio deployment restores the controller's receipt before replaying the lost first write.
    let recovered = try SettingsTrial(trial: copied, peer: air.settingsEnrollment, answering: false, owner: db.owner, account: account)
    try await expect(ProbeError.receiptRequired) { try await recovered.start(in: db) }
    try recovered.restoreReceipt(receipt)
    try await recovered.start(in: db)
    let neighbor = CKRecord.ID(recordName: "preserve-neighbor", zoneID: a.id.zoneID)
    let witness = OfflineDatabase.Row(revision: 4, payload: Data([9]))
    db.rows[neighbor] = witness
    func checkRow(_ revision: Int, expected: Double?, enrollment: UUID) throws {
        guard let row = db.rows[a.id], row.type == "MacSetting", row.schema == 1, row.revision == revision,
              let fields = try JSONSerialization.jsonObject(with: row.payload) as? [String: String],
              fields["key"] == "zoom|trial-" + studio.token + ".invalid",
              fields["enrollment"].flatMap(UUID.init(uuidString:)) == enrollment else { throw FixtureError.assertionFailed }
        let value = try fields["value"].map { value in
            guard let bytes = Data(base64Encoded: value) else { throw FixtureError.assertionFailed }
            return try JSONDecoder().decode(Double.self, from: bytes)
        }
        guard value == expected else { throw FixtureError.assertionFailed }
    }
    try checkRow(1, expected: 1.25, enrollment: studio.settingsEnrollment)
    try await expect(ProbeError.awaitingOtherMac) { try await a.confirm(in: db) }
    db.switchAfterFetch = true
    try await expect(ProbeError.originalAccountRequired) { try await b.answer(in: db) }
    db.owner = "offline-owner"
    try checkRow(1, expected: 1.25, enrollment: studio.settingsEnrollment)
    db.switchBeforeSave = true
    try await expect(ProbeError.originalAccountRequired) { try await b.answer(in: db) }
    db.owner = "offline-owner"
    db.unauthenticatedSave = true
    try await expect(ProbeError.explicitOwnerUnavailable) { try await b.answer(in: db) }
    try checkRow(1, expected: 1.25, enrollment: studio.settingsEnrollment)
    db.loseSaveReply = true
    try await expect(FixtureError.lostReply) { try await b.answer(in: db) }
    try await b.answer(in: db)
    try checkRow(2, expected: 1.5, enrollment: air.settingsEnrollment)
    try await a.confirm(in: db)
    db.normalizeMetadataKey = true
    try await expect(ProbeError.metadataKeyNormalized) { try await a.confirm(in: db) }
    db.normalizeMetadataKey = false
    db.staleMetadata = true
    try await expect(ProbeError.metadataTagMismatch) { try await a.confirm(in: db) }
    db.staleMetadata = false
    try await expect(ProbeError.receiptRequired) { try await b.clean(in: db) }
    let good = db.rows[a.id]!
    var foreign = good
    foreign.type = "Device"
    db.rows[a.id] = foreign
    try await expect(ProbeError.unexpectedRecord) { try await a.clean(in: db) }
    foreign.type = "MacSetting"
    foreign.schema = 2
    db.rows[a.id] = foreign
    try await expect(ProbeError.unexpectedRecord) { try await a.clean(in: db) }
    db.rows[a.id] = good
    db.changeBeforeSave = true
    try await expect(FixtureError.conflict) { try await a.clean(in: db) }
    try await expect(ProbeError.unexpectedRecord) { try await a.clean(in: db) }
    precondition(db.rows[a.id]?.payload == Data("concurrent write".utf8))
    db.rows[a.id] = good
    db.loseSaveReply = true
    try await expect(FixtureError.lostReply) { try await a.clean(in: db) }
    try await recovered.clean(in: db)
    try checkRow(3, expected: nil, enrollment: studio.nonce)
    try await expect(ProbeError.alreadyCleaned) { try await a.start(in: db) }
    precondition(db.rows.count == 2 && db.rows[neighbor] == witness)
    print("Original account and Studio receipt verified after a lost write and an account change.")
    print("MacSetting offline: 125%, 150%, confirmed, reset; neighbor preserved.")
}
