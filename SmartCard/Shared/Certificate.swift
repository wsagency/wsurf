import Foundation

/// The X.509 fields PKCS#11 objects and CryptoTokenKit items are built from. Parsed by hand
/// because PKCS#11 wants the original DER encodings of subject/issuer/serial, which Security.framework
/// only returns normalised.
struct Certificate: Sendable {
    enum Key: Sendable, Equatable {
        case rsa(modulus: Data, exponent: Data)
        /// `curve` is the DER-encoded namedCurve OID (CKA_EC_PARAMS); `point` the raw uncompressed EC point.
        case ec(curve: Data, point: Data)
    }

    let der: Data
    let subject: Data
    let issuer: Data
    /// DER INTEGER including tag and length, as CKA_SERIAL_NUMBER requires.
    let serial: Data
    let key: Key
    let commonName: String?
    /// First keyUsage byte (0x80 digitalSignature, 0x40 nonRepudiation, 0x04 keyCertSign); nil without the extension.
    let keyUsage: UInt8?

    /// Role label portals search for. "Identification" is not derivable from the certificate alone and
    /// stays unmapped until a real card shows which certificate carries it (spec §10 G3).
    var role: String {
        if let keyUsage {
            if keyUsage & 0x40 != 0 { return "Signature" }
            if keyUsage & 0x80 != 0 { return "Authentication" }
        }
        return "Additional"
    }

    var isCA: Bool { subject == issuer || (keyUsage ?? 0) & 0x04 != 0 }

    init?(der: Data) {
        let bytes = [UInt8](der)
        guard let root = DERElement(bytes, at: 0), root.tag == 0x30,
              let tbs = root.children(bytes).first, tbs.tag == 0x30
        else { return nil }
        let fields = tbs.children(bytes)
        let offset = fields.first?.tag == 0xA0 ? 1 : 0
        guard fields.count >= offset + 6 else { return nil }
        let (serial, issuer, subject, spki) = (fields[offset], fields[offset + 2], fields[offset + 4], fields[offset + 5])
        guard serial.tag == 0x02, let key = Self.publicKey(spki, bytes) else { return nil }

        self.der = der
        self.serial = serial.encoded(bytes)
        self.issuer = issuer.encoded(bytes)
        self.subject = subject.encoded(bytes)
        self.key = key
        self.commonName = Self.commonName(subject, bytes)
        self.keyUsage = fields.dropFirst(offset + 6).first { $0.tag == 0xA3 }.flatMap { Self.keyUsage($0, bytes) }
    }

    private static let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let ecOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let commonNameOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
    private static let keyUsageOID: [UInt8] = [0x55, 0x1D, 0x0F]

    private static func publicKey(_ spki: DERElement, _ bytes: [UInt8]) -> Key? {
        let parts = spki.children(bytes)
        guard parts.count == 2, let algorithm = parts[0].children(bytes).first, parts[1].tag == 0x03,
              parts[1].content.count > 1, bytes[parts[1].content.lowerBound] == 0
        else { return nil }
        let bits = parts[1].content.lowerBound + 1
        if Array(bytes[algorithm.content]) == rsaOID {
            guard let sequence = DERElement(bytes, at: bits), sequence.tag == 0x30 else { return nil }
            let integers = sequence.children(bytes)
            guard integers.count == 2, integers.allSatisfy({ $0.tag == 0x02 }) else { return nil }
            return .rsa(modulus: integers[0].unsignedValue(bytes), exponent: integers[1].unsignedValue(bytes))
        }
        if Array(bytes[algorithm.content]) == ecOID {
            let algorithmChildren = parts[0].children(bytes)
            guard algorithmChildren.count == 2, algorithmChildren[1].tag == 0x06 else { return nil }
            return .ec(curve: algorithmChildren[1].encoded(bytes), point: Data(bytes[bits..<parts[1].end]))
        }
        return nil
    }

    private static func commonName(_ subject: DERElement, _ bytes: [UInt8]) -> String? {
        let range = subject.content
        guard range.count > commonNameOID.count else { return nil }
        for i in range.lowerBound...(range.upperBound - commonNameOID.count)
        where Array(bytes[i..<(i + commonNameOID.count)]) == commonNameOID {
            guard let value = DERElement(bytes, at: i + commonNameOID.count), value.end <= range.upperBound else { return nil }
            return String(decoding: bytes[value.content], as: UTF8.self)
        }
        return nil
    }

    private static func keyUsage(_ extensions: DERElement, _ bytes: [UInt8]) -> UInt8? {
        for list in extensions.children(bytes) {
            for ext in list.children(bytes) {
                let parts = ext.children(bytes)
                guard parts.count >= 2, Array(bytes[parts[0].content]) == keyUsageOID,
                      let octets = parts.last, octets.tag == 0x04,
                      let bitString = DERElement(bytes, at: octets.content.lowerBound), bitString.tag == 0x03,
                      bitString.content.count >= 2
                else { continue }
                return bytes[bitString.content.lowerBound + 1]
            }
        }
        return nil
    }
}

private struct DERElement {
    let tag: UInt8
    let start: Int
    let content: Range<Int>
    var end: Int { content.upperBound }

    init?(_ bytes: [UInt8], at start: Int) {
        guard start >= 0, start + 2 <= bytes.count else { return nil }
        var position = start + 1
        var length = Int(bytes[position])
        position += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), position + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[position])
                position += 1
            }
        }
        guard position + length <= bytes.count else { return nil }
        self.tag = bytes[start]
        self.start = start
        self.content = position..<(position + length)
    }

    func children(_ bytes: [UInt8]) -> [DERElement] {
        var result: [DERElement] = []
        var position = content.lowerBound
        while position < content.upperBound, let child = DERElement(bytes, at: position), child.end <= content.upperBound {
            result.append(child)
            position = child.end
        }
        return result
    }

    func encoded(_ bytes: [UInt8]) -> Data { Data(bytes[start..<end]) }

    /// INTEGER content without the sign-padding zero.
    func unsignedValue(_ bytes: [UInt8]) -> Data {
        let value = bytes[content]
        return Data(value.first == 0 ? value.dropFirst() : value)
    }
}
