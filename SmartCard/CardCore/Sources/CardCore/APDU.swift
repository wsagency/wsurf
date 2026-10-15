import Foundation

/// ISO 7816-4 command APDU. `le` is the expected response length: 256 encodes as 0x00 (short),
/// anything larger switches the whole APDU to extended length (65536 encodes as 0x0000).
struct APDU: Equatable {
    var cla: UInt8 = 0x00
    var ins: UInt8
    var p1: UInt8
    var p2: UInt8
    var data = Data()
    var le: Int?

    var bytes: Data {
        precondition(data.count <= 0xFFFF && (le ?? 1) >= 1 && (le ?? 1) <= 0x10000, "APDU field out of range")
        var out = Data([cla, ins, p1, p2])
        if data.count > 0xFF || (le ?? 0) > 256 {
            if !data.isEmpty {
                out += [0x00, UInt8(data.count >> 8), UInt8(data.count & 0xFF)]
                out += data
            } else if le != nil {
                out.append(0x00)
            }
            if let le {
                let encoded = le & 0xFFFF
                out += [UInt8(encoded >> 8), UInt8(encoded & 0xFF)]
            }
        } else {
            if !data.isEmpty {
                out.append(UInt8(data.count))
                out += data
            }
            if let le { out.append(UInt8(le & 0xFF)) }
        }
        return out
    }

    func withLe(_ le: Int) -> APDU {
        var copy = self
        copy.le = le
        return copy
    }
}

extension APDU {
    /// P2 = 0C: no FCI requested.
    static func selectMF() -> APDU { selectFID(p1: 0x00, 0x3F00) }
    static func selectDF(_ fid: UInt16) -> APDU { selectFID(p1: 0x01, fid) }
    static func selectEF(_ fid: UInt16) -> APDU { selectFID(p1: 0x02, fid) }

    static func selectAID(_ aid: Data) -> APDU {
        APDU(ins: 0xA4, p1: 0x04, p2: 0x0C, data: aid)
    }

    private static func selectFID(p1: UInt8, _ fid: UInt16) -> APDU {
        APDU(ins: 0xA4, p1: p1, p2: 0x0C, data: Data([UInt8(fid >> 8), UInt8(fid & 0xFF)]))
    }

    /// Offsets below 0x8000 use READ BINARY (INS B0, offset in P1P2); from 0x8000 the odd-INS
    /// variant (INS B1) carries the offset as an offset data object `54 02 hh ll`.
    static func readBinary(offset: Int, length: Int) -> APDU {
        precondition((0...0xFFFF).contains(offset), "READ BINARY offset out of range")
        if offset < 0x8000 {
            return APDU(ins: 0xB0, p1: UInt8(offset >> 8), p2: UInt8(offset & 0xFF), le: length)
        }
        return APDU(ins: 0xB1, p1: 0x00, p2: 0x00, data: Data([0x54, 0x02, UInt8(offset >> 8), UInt8(offset & 0xFF)]), le: length)
    }

    static func getResponse(length: Int) -> APDU {
        APDU(ins: 0xC0, p1: 0x00, p2: 0x00, le: length)
    }

    /// PIN is sent as ASCII, right-padded with 0xFF when the profile defines a padded length.
    static func verify(pin: String, reference: UInt8, paddedLength: Int?) -> APDU {
        var block = Data(pin.utf8)
        if let paddedLength, block.count < paddedLength {
            block += Data(repeating: 0xFF, count: paddedLength - block.count)
        }
        return APDU(ins: 0x20, p1: 0x00, p2: reference, data: block)
    }

    /// MSE SET, digital signature template: optional algorithm template followed by the key reference (tag 84).
    static func mseSetDST(algorithmTemplate: Data, keyReference: UInt8) -> APDU {
        APDU(ins: 0x22, p1: 0x41, p2: 0xB6, data: algorithmTemplate + Data([0x84, 0x01, keyReference]))
    }

    /// PSO: COMPUTE DIGITAL SIGNATURE; Le 256 accepts any response up to 256 bytes.
    static func computeDigitalSignature(_ input: Data) -> APDU {
        APDU(ins: 0x2A, p1: 0x9E, p2: 0x9A, data: input, le: 256)
    }
}

struct APDUResponse: Equatable {
    let data: Data
    let sw: UInt16

    var sw1: UInt8 { UInt8(sw >> 8) }
    var sw2: UInt8 { UInt8(sw & 0xFF) }

    init(raw: Data) throws {
        guard raw.count >= 2 else { throw CardError.transport("response shorter than SW1SW2") }
        data = Data(raw.dropLast(2))
        sw = UInt16(raw[raw.endIndex - 2]) << 8 | UInt16(raw[raw.endIndex - 1])
    }

    init(data: Data, sw: UInt16) {
        self.data = data
        self.sw = sw
    }
}

extension CardProfile.Algorithm {
    var digestLength: Int {
        switch self {
        case .ecdsaP256Sha256, .rsaPkcsSha256: 32
        case .ecdsaP384Sha384: 48
        }
    }

    /// MSE data preceding tag 84. ECDSA: `80 04 FF 14|15 08 00` (evidence §4, hash length 0x20 / 0x30);
    /// RSA has no extracted template, so only the key reference is sent.
    var mseTemplate: Data {
        switch self {
        case .ecdsaP256Sha256: Data([0x80, 0x04, 0xFF, 0x14, 0x08, 0x00])
        case .ecdsaP384Sha384: Data([0x80, 0x04, 0xFF, 0x15, 0x08, 0x00])
        case .rsaPkcsSha256: Data()
        }
    }

    /// PSO input: ECDSA takes the bare hash; RSA takes the hash wrapped in a DER DigestInfo.
    func signatureInput(for digest: Data) -> Data {
        switch self {
        case .ecdsaP256Sha256, .ecdsaP384Sha384: digest
        case .rsaPkcsSha256: Self.sha256DigestInfo + digest
        }
    }

    /// RFC 8017 §9.2 SHA-256 DigestInfo prefix; the card applies PKCS#1 v1.5 padding.
    private static let sha256DigestInfo = Data([
        0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
    ])
}
