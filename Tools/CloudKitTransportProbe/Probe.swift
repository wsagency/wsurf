// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Darwin
import Foundation
import Security

private let appID = "io.wsagency.wsurf"
private let containerID = "iCloud.io.wsagency.wsurf"

private enum ProbeError: String, Error {
    case usage, developmentSignatureRequired, invalidNonce, zoneAlreadyExists
    case receiptRequired, useSecondMac, unexpectedRecord, awaitingOtherMac, missingSaveResult
}

private enum Phase: String, CaseIterable {
    case started, answered
}

private struct Trial {
    let nonce: UUID

    var token: String {
        nonce.uuidString.lowercased()
    }

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "wsurf-development-probe-" + token, ownerName: CKCurrentUserDefaultName)
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "round-trip", zoneID: zoneID)
    }

    var receipt: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("wsurf-probe-" + token + ".receipt")
    }

    enum Receipt: String {
        case pending, created
    }

    func receiptBytes(_ state: Receipt) -> Data {
        Data(("WSurf CloudKit development transport receipt v1\n" + token + "\n" + state.rawValue).utf8)
    }

    func readReceipt() throws -> Receipt {
        let bytes = try? Data(contentsOf: receipt)
        if bytes == receiptBytes(.created) {
            return .created
        }
        if bytes == receiptBytes(.pending) {
            return .pending
        }
        throw ProbeError.receiptRequired
    }

    init() {
        nonce = UUID()
    }

    init(token: String) throws {
        guard let id = UUID(uuidString: token), id.uuidString.lowercased() == token.lowercased(),
              id.uuid.6 >> 4 == 4, id.uuid.8 >> 6 == 2 else { throw ProbeError.invalidNonce }
        nonce = id
    }

    func payload(_ phase: Phase) -> Data {
        Data(("WSurf CloudKit development transport v1\n" + token + "\n" + phase.rawValue).utf8)
    }

    func phase(of record: CKRecord) throws -> Phase {
        guard record.recordID == recordID, record.recordType == "Device",
              let payload = record.encryptedValues["payload"] as? Data,
              let phase = Phase.allCases.first(where: { self.payload($0) == payload })
        else { throw ProbeError.unexpectedRecord }
        return phase
    }
}

private func absent(_ error: Error) -> Bool {
    guard let error = error as? CKError else { return false }
    return error.code == .zoneNotFound || error.code == .unknownItem
}

// Nothing constructs the CloudKit container until the running helper proves its own signature selected Development.
private func database() throws -> CKDatabase {
    guard let task = SecTaskCreateFromSelf(nil), Bundle.main.bundleIdentifier == appID,
          Bundle.main.object(forInfoDictionaryKey: "WSurfDevelopmentTransportProbe") as? Bool == true else {
        throw ProbeError.developmentSignatureRequired
    }
    func entitlement(_ key: String) -> Any? {
        SecTaskCopyValueForEntitlement(task, ("com.apple.developer." + key) as CFString, nil)
    }
    guard entitlement("icloud-container-environment") as? String == "Development",
          entitlement("aps-environment") as? String == "development",
          entitlement("icloud-container-identifiers") as? [String] == [containerID],
          entitlement("icloud-services") as? [String] == ["CloudKit"] else {
        throw ProbeError.developmentSignatureRequired
    }
    return CKContainer(identifier: containerID).privateCloudDatabase
}

private func save(_ record: CKRecord, to db: CKDatabase) async throws {
    let result = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
    guard let saved = result.saveResults[record.recordID] else { throw ProbeError.missingSaveResult }
    _ = try saved.get()
}

private func begin(_ trial: Trial, in db: CKDatabase) async throws {
    // The starting Mac alone generates and owns this nonce. Fail closed on every other zone lookup error.
    do {
        _ = try await db.recordZone(for: trial.zoneID)
        throw ProbeError.zoneAlreadyExists
    } catch where absent(error) { }
    try trial.receiptBytes(.pending).write(to: trial.receipt, options: .withoutOverwriting)
    FileHandle.standardOutput.write(Data(("NONCE=" + trial.token + "\n").utf8))
    _ = try await db.save(CKRecordZone(zoneID: trial.zoneID))
    try trial.receiptBytes(.created).write(to: trial.receipt, options: .atomic)
    let record = CKRecord(recordType: "Device", recordID: trial.recordID)
    record.encryptedValues["payload"] = trial.payload(.started)
    try await save(record, to: db)
    print("Synthetic marker saved.")
}

private func answer(_ trial: Trial, in db: CKDatabase) async throws {
    guard !FileManager.default.fileExists(atPath: trial.receipt.path) else { throw ProbeError.useSecondMac }
    let record = try await db.record(for: trial.recordID)
    if try trial.phase(of: record) == .started {
        record.encryptedValues["payload"] = trial.payload(.answered)
        try await save(record, to: db)
    }
    print("Second Mac read the marker and acknowledged it.")
}

private func confirm(_ trial: Trial, in db: CKDatabase) async throws {
    guard try trial.readReceipt() == .created else { throw ProbeError.receiptRequired }
    let record = try await db.record(for: trial.recordID)
    guard try trial.phase(of: record) == .answered else { throw ProbeError.awaitingOtherMac }
    print("Round trip confirmed in CloudKit Development.")
}

private func clean(_ trial: Trial, in db: CKDatabase) async throws {
    // The creator's exclusive local receipt also covers interruptions between creating the zone and saving the marker.
    let receipt = try trial.readReceipt()
    do {
        _ = try await db.recordZone(for: trial.zoneID)
    } catch where absent(error) {
        // An account switch can also hide the zone. Keep the receipt so the original account can retry cleanup.
        print("The trial's zone is absent in this account. Retained local receipt.")
        return
    }
    do {
        let record = try await db.record(for: trial.recordID)
        _ = try trial.phase(of: record)
    } catch where absent(error) {
        // Without a marker, only a server-confirmed creation acknowledges this exact zone as ours.
        guard receipt == .created else { throw ProbeError.receiptRequired }
    }
    do {
        _ = try await db.deleteRecordZone(withID: trial.zoneID)
    } catch where absent(error) { }
    print("The trial's zone is gone. Retained local receipt.")
}

private func offlineChecks() throws {
    let trial = Trial()
    let other = Trial()
    let restored = try Trial(token: trial.token)
    precondition(restored.zoneID == trial.zoneID && other.zoneID != trial.zoneID)
    precondition((try? Trial(token: "devices")) == nil)
    let record = CKRecord(recordType: "Device", recordID: trial.recordID)
    for phase in Phase.allCases {
        record.encryptedValues["payload"] = trial.payload(phase)
        let recognized = try trial.phase(of: record)
        precondition(recognized == phase)
        precondition((try? other.phase(of: record)) == nil)
    }
    record.encryptedValues["payload"] = other.payload(.started)
    precondition((try? trial.phase(of: record)) == nil)
    precondition((try? trial.readReceipt()) == nil)
    try trial.receiptBytes(.pending).write(to: trial.receipt, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: trial.receipt) }
    let pending = try restored.readReceipt()
    precondition(pending == .pending && (try? other.readReceipt()) == nil)
    try trial.receiptBytes(.created).write(to: trial.receipt, options: .atomic)
    let created = try restored.readReceipt()
    precondition(created == .created)
    try other.receiptBytes(.created).write(to: trial.receipt, options: .atomic)
    precondition((try? trial.readReceipt()) == nil)
    print("Offline checks passed.")
}

@main
private struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case "self-test" where args.count == 1:
                try offlineChecks()
            case "begin" where args.count == 1:
                try await begin(Trial(), in: database())
            case "answer", "confirm", "cleanup":
                guard args.count == 2 else { throw ProbeError.usage }
                let trial = try Trial(token: args[1])
                let db = try database()
                switch args[0] {
                case "answer":
                    try await answer(trial, in: db)
                case "confirm":
                    try await confirm(trial, in: db)
                default:
                    try await clean(trial, in: db)
                }
            default:
                throw ProbeError.usage
            }
        } catch {
            // CloudKit error descriptions can include account and record metadata.
            let message: String
            if let error = error as? ProbeError {
                message = error.rawValue
            } else if let error = error as? CKError {
                message = "CloudKit error " + String(error.code.rawValue)
            } else {
                message = "local or system error " + String((error as NSError).code)
            }
            FileHandle.standardError.write(Data(("Probe failed: " + message + "\n").utf8))
            exit(1)
        }
    }
}
