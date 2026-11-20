// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation

private enum FixtureError: Error {
    case lostReply, conflict, assertionFailed
}

// A fetch returns a detached snapshot. A save succeeds only against its observed revision, as in CKDatabase.saveVersion.
private final class OfflineDatabase: ProbeDatabase {
    struct Row: Equatable {
        let revision: Int
        let payload: Data
    }

    var zone: CKRecordZone.ID?
    var rows: [CKRecord.ID: Row] = [:]
    var loseZoneReply = false
    var loseSaveReply = false
    var changeBeforeSave = false
    private var fetched: [ObjectIdentifier: (CKRecord, Int)] = [:]

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
        guard id.zoneID == zone, let row = rows[id] else { return nil }
        let record = CKRecord(recordType: "Device", recordID: id)
        record.encryptedValues["payload"] = row.payload
        fetched[ObjectIdentifier(record)] = (record, row.revision)
        return record
    }

    func saveVersion(_ record: CKRecord) async throws {
        let id = record.recordID
        guard id.zoneID == zone, let payload = record.encryptedValues["payload"] as? Data else { throw FixtureError.assertionFailed }
        let previous = fetched.removeValue(forKey: ObjectIdentifier(record))?.1
        if changeBeforeSave {
            changeBeforeSave = false
            rows[id] = Row(revision: (rows[id]?.revision ?? 0) + 1, payload: Data("concurrent write".utf8))
        }
        guard previous == rows[id]?.revision else { throw FixtureError.conflict }
        rows[id] = Row(revision: (previous ?? 0) + 1, payload: payload)
        if loseSaveReply {
            loseSaveReply = false
            throw FixtureError.lostReply
        }
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
    print("Offline checks passed.")
}
