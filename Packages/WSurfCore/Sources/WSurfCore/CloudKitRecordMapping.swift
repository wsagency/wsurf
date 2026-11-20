// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation

/// The two-way mapping between sync types and CloudKit types. `syncRecord` is the allowlist boundary: a record of another type,
/// or one without the encrypted `payload`, never reaches the model.
nonisolated enum CloudKitMapping {
    static let payloadKey = "payload"
    static let schemaKey = "schemaVersion"

    static func zoneID(_ zone: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(_ id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.name, zoneID: zoneID(id.zone))
    }

    static func syncID(_ id: CKRecord.ID) -> SyncRecordID {
        SyncRecordID(zone: id.zoneID.zoneName, name: id.recordName)
    }

    static func syncRecord(_ record: CKRecord) -> SyncRecord? {
        guard let type = SyncRecordType(rawValue: record.recordType),
              let payload = record.encryptedValues[payloadKey] as? Data
        else { return nil }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return SyncRecord(
            id: syncID(record.recordID),
            type: type,
            schema: (record[schemaKey] as? Int) ?? 1,
            payload: payload,
            systemFields: archiver.encodedData,
            modifiedAt: record.modificationDate
        )
    }

    static func ckRecord(_ record: SyncRecord) -> CKRecord {
        let id = recordID(record.id)
        let result = restoredRecord(from: record.systemFields, matching: id, type: record.type)
            ?? CKRecord(recordType: record.type.rawValue, recordID: id)
        result[schemaKey] = record.schema as NSNumber
        result.encryptedValues[payloadKey] = record.payload
        return result
    }

    private static func restoredRecord(from fields: Data?, matching id: CKRecord.ID, type: SyncRecordType) -> CKRecord? {
        guard let fields, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: fields) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let restored = CKRecord(coder: unarchiver), restored.recordID == id, restored.recordType == type.rawValue
        else { return nil }
        return restored
    }
}
