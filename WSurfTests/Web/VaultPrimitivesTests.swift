// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

struct VaultPrimitivesTests {
    nonisolated enum MalformedCase: CaseIterable, Sendable {
        case truncatedU32, textLengthBeyondRemaining, invalidUTF8Text, boolByteTwo, optionalTagTwo
        case arrayOverMaxCount, uuidSetOutOfOrder, uuidSetDuplicate

        private static func id(_ first: UInt8) -> [UInt8] {
            [first] + [UInt8](repeating: 0, count: 15)
        }

        var data: Data {
            switch self {
            case .truncatedU32:
                Data([0, 0, 1])
            case .textLengthBeyondRemaining:
                Data([0, 0, 0, 5, 0x61, 0x62])
            case .invalidUTF8Text:
                Data([0, 0, 0, 1, 0xFF])
            case .boolByteTwo:
                Data([2])
            case .optionalTagTwo:
                Data([2])
            case .arrayOverMaxCount:
                Data([0, 0, 0, 3, 1, 2, 3])
            case .uuidSetOutOfOrder:
                Data([0, 0, 0, 2] + Self.id(2) + Self.id(1))
            case .uuidSetDuplicate:
                Data([0, 0, 0, 2] + Self.id(1) + Self.id(1))
            }
        }

        func read(_ reader: inout StoreReader) throws {
            switch self {
            case .truncatedU32:
                _ = try reader.u32()
            case .textLengthBeyondRemaining, .invalidUTF8Text:
                _ = try reader.text()
            case .boolByteTwo:
                _ = try reader.bool()
            case .optionalTagTwo:
                _ = try reader.optional { try $0.u8() }
            case .arrayOverMaxCount:
                _ = try reader.array(maxCount: 2) { try $0.u8() }
            case .uuidSetOutOfOrder, .uuidSetDuplicate:
                _ = try reader.uuidSet(maxCount: 8)
            }
        }
    }

    private func bytes(_ build: (inout StoreWriter) -> Void) -> [UInt8] {
        var writer = StoreWriter()
        build(&writer)
        return [UInt8](writer.data)
    }

    private func raw(_ id: UUID) -> [UInt8] {
        withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    private func data(hex: String) -> Data {
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    @Test func writerAndReaderRoundTripEveryEncodingRule() throws {
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 1234.5)
        let set: Set<UUID> = [UUID(), UUID(), UUID()]
        var writer = StoreWriter()
        writer.u8(7)
        writer.u32(1)
        writer.u64(1)
        writer.bool(true)
        writer.uuid(id)
        writer.text("é")
        writer.bytes(Data([1, 2]))
        writer.date(date)
        writer.optional(nil as Int?) { $0.u32($1) }
        writer.optional(5) { $0.u32($1) }
        writer.array([1, 2, 3]) { $0.u32($1) }
        writer.uuidSet(set)

        var reader = StoreReader(writer.data)
        #expect(try reader.u8() == 7)
        #expect(try reader.u32() == 1)
        #expect(try reader.u64() == 1)
        #expect(try reader.bool() == true)
        #expect(try reader.uuid() == id)
        #expect(try reader.text() == "é")
        #expect(try reader.bytes() == Data([1, 2]))
        #expect(try reader.date() == date)
        #expect(try reader.optional { try $0.u32() } == nil)
        #expect(try reader.optional { try $0.u32() } == 5)
        #expect(try reader.array(maxCount: 3) { try $0.u32() } == [1, 2, 3])
        #expect(try reader.uuidSet(maxCount: 3) == set)
        #expect(reader.isAtEnd)
    }

    @Test func encodingsAreExactlyTheSpecifiedBytes() {
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 1234.5)
        let low = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        let mid = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
        let high = UUID(uuidString: "30000000-0000-0000-0000-000000000000")!

        #expect(bytes { $0.u32(1) } == [0, 0, 0, 1])
        #expect(bytes { $0.u64(1) } == [0, 0, 0, 0, 0, 0, 0, 1])
        #expect(bytes { $0.uuid(id) } == raw(id))
        #expect(bytes { $0.text("ab") } == [0, 0, 0, 2, 0x61, 0x62])
        #expect(bytes { $0.bool(true) } == [1])
        #expect(bytes { $0.optional(nil as UInt8?) { $0.u8($1) } } == [0])
        #expect(bytes { $0.optional(UInt8(9)) { $0.u8($1) } } == [1, 9])
        #expect(bytes { $0.date(date) } == withUnsafeBytes(of: date.timeIntervalSinceReferenceDate.bitPattern.bigEndian) { Array($0) })
        for set in [[high, low, mid], [mid, high, low], [low, mid, high]] {
            #expect(bytes { $0.uuidSet(Set(set)) } == [0, 0, 0, 3] + raw(low) + raw(mid) + raw(high))
        }
    }

    @Test(arguments: MalformedCase.allCases)
    func readerRejectsMalformedInput(_ input: MalformedCase) {
        #expect(throws: CredentialStoreError.malformed) {
            var reader = StoreReader(input.data)
            try input.read(&reader)
        }
    }

    @Test func lengthPrefixesKeepFieldPairsDistinct() {
        let first = bytes { $0.text("ab"); $0.text("c") }
        let second = bytes { $0.text("a"); $0.text("bc") }
        #expect(first != second)
    }

    // Persisted wire format (§5): the exact SQL strings and UInt8 tags, independent of Swift case spelling.
    @Test func persistedSQLNamesAndTagsArePinned() {
        let roles: [(VaultRole, String, UInt8)] = [(.active, "active", 1), (.trash, "trash", 2)]
        let kinds: [(RecordKind, String, UInt8)] = [(.account, "account", 1), (.revision, "revision", 2), (.trashEntry, "trashEntry", 3), (.tombstone, "tombstone", 4)]
        let subjects: [(RecordSubject, String, UInt8)] = [
            (.account, "account", 1), (.password, "password", 2), (.totp, "totp", 3), (.passkey, "passkey", 4), (.metadata, "metadata", 5),
        ]
        for (value, name, tag) in roles {
            #expect(value.sqlName == name && value.rawValue == tag && VaultRole(sqlName: name) == value)
        }
        for (value, name, tag) in kinds {
            #expect(value.sqlName == name && value.rawValue == tag && RecordKind(sqlName: name) == value)
        }
        for (value, name, tag) in subjects {
            #expect(value.sqlName == name && value.rawValue == tag && RecordSubject(sqlName: name) == value)
        }
    }

    @Test func sqlNameParsersRejectUnknownAndDifferentlyCasedStrings() {
        for name in ["", "nope", "Active", "TRASH", " active", "active "] { #expect(VaultRole(sqlName: name) == nil) }
        for name in ["", "nope", "trashentry", "TrashEntry", "trash_entry", "Account"] { #expect(RecordKind(sqlName: name) == nil) }
        for name in ["", "nope", "Password", "TOTP", "passKey", "meta"] { #expect(RecordSubject(sqlName: name) == nil) }
    }

    @Test func readerDecodesFixedUUIDBytesFromASlicedBuffer() throws {
        let expected = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let raw = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        let sliced = (Data([0xEE, 0xEE, 0xEE]) + raw + Data([0xEE])).dropFirst(3).dropLast()  // startIndex == 3
        #expect(sliced.startIndex == 3)
        var reader = StoreReader(sliced)
        #expect(try reader.uuid() == expected)
        #expect(reader.isAtEnd)
    }

    // Frozen from the ORIGINAL, unedited CredentialVaultCrypto.wrap (component probe on the Pro, run.log,
    // evidence/probe-1791800425-99315): DEK 0x11×32; credentialID 0x01×32, prfInput 0x02×32, prf 0x03×32;
    // profile …00A1, vault …00B2. The wrap nonce is random, so only unwrap of this fixture is asserted.
    @Test func frozenWrapperVectorStillUnwraps() throws {
        let wrapper = CredentialKeyWrapper(
            credentialID: Data(repeating: 0x01, count: 32),
            prfInput: Data(repeating: 0x02, count: 32),
            nonce: data(hex: "76c1b022972ed8fbe11fccd8"),
            ciphertext: data(hex: "add6cd10975fcf7383d790153d7e2e2b0e9f8fe246b162c080840260ea4e8f07"),
            tag: data(hex: "61704555590f93d73c40f58c45d30f24")
        )
        let unwrapped = try CredentialVaultCrypto.unwrap(
            wrapper,
            prf: SymmetricKey(data: Data(repeating: 0x03, count: 32)),
            profileID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            vaultID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        )
        #expect(unwrapped == Data(repeating: 0x11, count: 32))
    }
}
