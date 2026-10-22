// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Persisted binary format: big-endian integers, u32 length prefixes, no padding.
nonisolated struct StoreWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) {
        data.append(v)
    }

    mutating func u32(_ v: Int) {
        guard let value = UInt32(exactly: v) else { preconditionFailure("u32 out of range: \(v)") }
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ v: UInt64) {
        withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func bool(_ v: Bool) {
        u8(v ? 1 : 0)
    }

    mutating func uuid(_ v: UUID) {
        withUnsafeBytes(of: v.uuid) { data.append(contentsOf: $0) }
    }

    mutating func text(_ v: String) {
        u32(v.utf8.count)
        data.append(contentsOf: v.utf8)
    }

    mutating func bytes(_ v: Data) {
        u32(v.count)
        data.append(v)
    }

    /// `timeIntervalSinceReferenceDate` as its Float64 bit pattern, UInt64 big-endian.
    mutating func date(_ v: Date) {
        u64(v.timeIntervalSinceReferenceDate.bitPattern)
    }

    mutating func uuidSet(_ v: Set<UUID>) {
        u32(v.count)
        for id in v.sorted(by: { $0.orderKey < $1.orderKey }) {
            uuid(id)
        }
    }

    mutating func optional<T>(_ v: T?, _ write: (inout StoreWriter, T) -> Void) {
        guard let v else { return u8(0) }
        u8(1)
        write(&self, v)
    }

    mutating func array<T>(_ v: [T], _ write: (inout StoreWriter, T) -> Void) {
        u32(v.count)
        for element in v {
            write(&self, element)
        }
    }
}

/// Every failure throws `CredentialStoreError.malformed`; all reads are bounds-checked before they touch the data.
nonisolated struct StoreReader {
    private let data: Data
    private var position: Data.Index

    init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    var isAtEnd: Bool {
        position == data.endIndex
    }

    private var remaining: Int {
        data.endIndex - position
    }

    private mutating func take(_ count: Int) throws -> Range<Data.Index> {
        guard count >= 0, count <= remaining else { throw CredentialStoreError.malformed }
        defer { position += count }
        return position..<position + count
    }

    private mutating func unsigned(byteCount: Int) throws -> UInt64 {
        let range = try take(byteCount)
        return data[range].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    mutating func u8() throws -> UInt8 {
        UInt8(try unsigned(byteCount: 1))
    }

    mutating func u32() throws -> Int {
        Int(try unsigned(byteCount: 4))
    }

    mutating func u64() throws -> UInt64 {
        try unsigned(byteCount: 8)
    }

    mutating func bool() throws -> Bool {
        switch try u8() {
        case 0:
            false
        case 1:
            true
        default:
            throw CredentialStoreError.malformed
        }
    }

    mutating func uuid() throws -> UUID {
        let range = try take(16)
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: data[range]) }
        return UUID(uuid: raw)
    }

    mutating func text() throws -> String {
        let range = try take(try u32())
        guard let text = String(validating: data[range], as: UTF8.self) else { throw CredentialStoreError.malformed }
        return text
    }

    mutating func bytes() throws -> Data {
        let range = try take(try u32())
        return Data(data[range])
    }

    mutating func date() throws -> Date {
        Date(timeIntervalSinceReferenceDate: Double(bitPattern: try u64()))
    }

    /// Ids must be strictly ascending (the writer's order); a duplicate or out-of-order id is malformed.
    mutating func uuidSet(maxCount: Int) throws -> Set<UUID> {
        let count = try u32()
        guard count <= maxCount, count <= remaining / 16 else { throw CredentialStoreError.malformed }
        var result = Set<UUID>(minimumCapacity: count)
        var previous: UUID?
        for _ in 0..<count {
            let id = try uuid()
            if let previous, !(previous.orderKey < id.orderKey) {
                throw CredentialStoreError.malformed
            }
            result.insert(id)
            previous = id
        }
        return result
    }

    mutating func optional<T>(_ read: (inout StoreReader) throws -> T) throws -> T? {
        switch try u8() {
        case 0:
            nil
        case 1:
            try read(&self)
        default:
            throw CredentialStoreError.malformed
        }
    }

    mutating func array<T>(maxCount: Int, _ read: (inout StoreReader) throws -> T) throws -> [T] {
        let count = try u32()
        guard count <= maxCount else { throw CredentialStoreError.malformed }
        var result: [T] = []
        result.reserveCapacity(min(count, remaining))  // a hostile count cannot force a large allocation
        for _ in 0..<count {
            result.append(try read(&self))
        }
        return result
    }
}

private extension UUID {
    /// The 16 raw bytes as two big-endian words: tuple order equals byte-wise ascending order.
    nonisolated var orderKey: ComparableKey {
        withUnsafeBytes(of: uuid) {
            ComparableKey(high: $0.loadUnaligned(as: UInt64.self).bigEndian, low: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).bigEndian)
        }
    }
}

private nonisolated struct ComparableKey: Comparable {
    let high: UInt64, low: UInt64

    static func < (a: Self, b: Self) -> Bool {
        (a.high, a.low) < (b.high, b.low)
    }
}
