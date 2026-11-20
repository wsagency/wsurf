// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import CryptoKit
import Darwin
import Foundation
import Security

private let appID = "io.wsagency.wsurf"
private let containerID = "iCloud.io.wsagency.wsurf"

enum ProbeError: String, Error {
    case usage, developmentSignatureRequired, invalidNonce, modelUnavailable, receiptRequired
    case differentCreator, useSecondMac, unexpectedRecord, awaitingOtherMac, alreadyCleaned, missingSaveResult
}

// Both Studio and Air report a product model shared by many Macs. No serial number or hardware UUID is needed.
private func macModel() throws -> String {
    var length = 0
    guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 1 else { throw ProbeError.modelUnavailable }
    var bytes = [UInt8](repeating: 0, count: length)
    let result = bytes.withUnsafeMutableBytes { sysctlbyname("hw.model", $0.baseAddress, &length, nil, 0) }
    guard result == 0, let model = String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8), !model.isEmpty else {
        throw ProbeError.modelUnavailable
    }
    return model
}

struct Marker: Codable, Equatable {
    let version: Int
    let nonce: String
    let creator: Data
    var responder: Data?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct Trial {
    static let zoneID = CKRecordZone.ID(zoneName: "wsurf-development-transport-v2", ownerName: CKCurrentUserDefaultName)
    let nonce: UUID
    let model: String
    let directory: URL

    init(nonce: UUID = UUID(), model: String, directory: URL) {
        self.nonce = nonce
        self.model = model
        self.directory = directory
    }

    init(token: String, model: String, directory: URL) throws {
        guard let id = UUID(uuidString: token), id.uuidString.lowercased() == token.lowercased(),
              id.uuid.6 >> 4 == 4, id.uuid.8 >> 6 == 2 else { throw ProbeError.invalidNonce }
        self.init(nonce: id, model: model, directory: directory)
    }

    var token: String {
        nonce.uuidString.lowercased()
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "transport-" + token, zoneID: Self.zoneID)
    }

    var deviceTag: Data {
        Data(SHA256.hash(data: Data(("WSurf transport v2\n" + token + "\n" + model).utf8)))
    }

    var receipt: URL {
        directory.appendingPathComponent("wsurf-probe-" + token + ".receipt")
    }

    private var initial: Marker {
        Marker(version: 2, nonce: token, creator: deviceTag)
    }

    private func requireReceipt() throws {
        guard let data = try? Data(contentsOf: receipt), data == (try initial.encoded()) else {
            throw ProbeError.receiptRequired
        }
    }

    func reserve() throws {
        try initial.encoded().write(to: receipt, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: receipt)
        defer { try? file.close() }
        try file.synchronize()
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(folder) }
        guard fsync(folder) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    // A zero-length encrypted payload is the tombstone. A missing field or unrecognized payload is foreign.
    private func marker(in record: CKRecord) throws -> Marker? {
        guard record.recordID == recordID, record.recordType == "Device",
              let payload = record.encryptedValues["payload"] as? Data else { throw ProbeError.unexpectedRecord }
        if payload.isEmpty {
            return nil
        }
        guard let marker = try? JSONDecoder().decode(Marker.self, from: payload), try marker.encoded() == payload,
              marker.version == 2, marker.nonce == token, marker.creator.count == SHA256.byteCount,
              marker.responder == nil || (marker.responder?.count == SHA256.byteCount && marker.responder != marker.creator)
        else { throw ProbeError.unexpectedRecord }
        return marker
    }

    // The caller writes the receipt before even constructing the live database. Repeating start resumes that receipt.
    func start(in database: any ProbeDatabase) async throws {
        try requireReceipt()
        try await database.ensureZone(Self.zoneID)
        if let record = try await database.fetch(recordID) {
            guard let marker = try marker(in: record) else { throw ProbeError.alreadyCleaned }
            guard marker.creator == deviceTag else { throw ProbeError.differentCreator }
            return
        }
        let record = CKRecord(recordType: "Device", recordID: recordID)
        record.encryptedValues["payload"] = try initial.encoded()
        try await database.saveVersion(record)
    }

    func answer(in database: any ProbeDatabase) async throws {
        guard let record = try await database.fetch(recordID), var marker = try marker(in: record) else {
            throw ProbeError.awaitingOtherMac
        }
        guard marker.creator != deviceTag else { throw ProbeError.useSecondMac }
        if let responder = marker.responder {
            guard responder == deviceTag else { throw ProbeError.unexpectedRecord }
            return
        }
        marker.responder = deviceTag
        record.encryptedValues["payload"] = try marker.encoded()
        try await database.saveVersion(record)
    }

    func confirm(in database: any ProbeDatabase) async throws {
        try requireReceipt()
        guard let record = try await database.fetch(recordID), let marker = try marker(in: record),
              marker.creator == deviceTag, marker.responder != nil else { throw ProbeError.awaitingOtherMac }
    }

    @discardableResult
    func clean(in database: any ProbeDatabase) async throws -> Bool {
        try requireReceipt()
        guard let record = try await database.fetch(recordID) else { return false }
        if let marker = try marker(in: record) {
            guard marker.creator == deviceTag else { throw ProbeError.differentCreator }
            record.encryptedValues["payload"] = Data()
            try await database.saveVersion(record)
        }
        return true
    }
}

protocol ProbeDatabase {
    func ensureZone(_ id: CKRecordZone.ID) async throws
    func fetch(_ id: CKRecord.ID) async throws -> CKRecord?
    func saveVersion(_ record: CKRecord) async throws
}

extension CKDatabase: ProbeDatabase {
    func ensureZone(_ id: CKRecordZone.ID) async throws {
        do {
            _ = try await recordZone(for: id)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            _ = try await save(CKRecordZone(zoneID: id))
        }
    }

    func fetch(_ id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await record(for: id)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    func saveVersion(_ record: CKRecord) async throws {
        let result = try await modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[record.recordID] else { throw ProbeError.missingSaveResult }
        _ = try saved.get()
    }
}

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

@main
private struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            if args == ["self-test"] {
                try await offlineChecks()
                return
            }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let model = try macModel()
            switch args.first {
            case "begin" where args.count == 1:
                let trial = Trial(model: model, directory: directory)
                try trial.reserve()
                FileHandle.standardOutput.write(Data(("NONCE=" + trial.token + "\n").utf8))
                try await trial.start(in: database())
                print("Synthetic marker saved.")
            case "resume", "answer", "confirm", "cleanup":
                guard args.count == 2 else { throw ProbeError.usage }
                let trial = try Trial(token: args[1], model: model, directory: directory)
                let db = try database()
                switch args[0] {
                case "resume":
                    try await trial.start(in: db)
                    print("Synthetic marker ready.")
                case "answer":
                    try await trial.answer(in: db)
                    print("Other Mac model acknowledged the marker.")
                case "confirm":
                    try await trial.confirm(in: db)
                    print("Round trip confirmed in CloudKit Development.")
                default:
                    if try await trial.clean(in: db) {
                        print("Marker payload cleared. The empty record and creator receipt remain.")
                    } else {
                        print("Marker absent in this account. Retained creator receipt.")
                    }
                }
            default:
                throw ProbeError.usage
            }
        } catch {
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
