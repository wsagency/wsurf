import CardCore
import Foundation

extension Certificate {
    private static let p256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let p384: [UInt8] = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22]

    /// The card algorithm this certificate's key signs with, if the card profile offers it.
    func algorithm(in profile: CardProfile) -> CardProfile.Algorithm? {
        let algorithm: CardProfile.Algorithm
        switch key {
        case .rsa:
            algorithm = .rsaPkcsSha256
        case .ec(let curve, _):
            if curve == Data(Self.p256) {
                algorithm = .ecdsaP256Sha256
            } else if curve == Data(Self.p384) {
                algorithm = .ecdsaP384Sha384
            } else {
                return nil
            }
        }
        return profile.algorithms.contains(algorithm) ? algorithm : nil
    }

    /// ECDSA component size in bytes; nil for RSA.
    var ecComponentLength: Int? {
        guard case .ec(let curve, _) = key else { return nil }
        return curve == Data(Self.p384) ? 48 : 32
    }

    var keyBits: Int {
        switch key {
        case .rsa(let modulus, _): modulus.count * 8
        case .ec: (ecComponentLength ?? 32) * 8
        }
    }

    /// Length of the signature the card returns (PKCS#11 raw form for ECDSA).
    var signatureLength: Int {
        switch key {
        case .rsa(let modulus, _): modulus.count
        case .ec: 2 * (ecComponentLength ?? 32)
        }
    }
}

enum ECDSASignature {
    /// r‖s with both components `size` bytes, from either raw r‖s or an ASN.1 DER SEQUENCE{r, s}
    /// (CardCore passes the card's bytes through untouched and the card's format is not yet observed).
    static func raw(_ signature: Data, size: Int) -> Data? {
        if signature.count == 2 * size { return signature }
        let b = [UInt8](signature)
        guard b.count > 2, b[0] == 0x30 else { return nil }
        var i = b[1] & 0x80 != 0 ? 2 + Int(b[1] & 0x7F) : 2
        var out = Data()
        for _ in 0..<2 {
            guard i + 2 <= b.count, b[i] == 0x02 else { return nil }
            let length = Int(b[i + 1])
            guard length < 128, i + 2 + length <= b.count else { return nil }
            var value = Array(b[(i + 2)..<(i + 2 + length)])
            while value.count > size, value.first == 0 { value.removeFirst() }
            guard value.count <= size else { return nil }
            out.append(contentsOf: [UInt8](repeating: 0, count: size - value.count) + value)
            i += 2 + length
        }
        return i == b.count ? out : nil
    }

    /// ASN.1 DER SEQUENCE{r, s} (X9.62) from raw r‖s, the form SecKey ECDSA algorithms return.
    static func der(_ raw: Data) -> Data {
        let half = raw.count / 2
        func integer(_ part: Data) -> [UInt8] {
            var value = Array(part.drop(while: { $0 == 0 }))
            if value.isEmpty { value = [0] }
            if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
            return [0x02, UInt8(value.count)] + value
        }
        let body = integer(raw.prefix(half)) + integer(raw.suffix(half))
        return Data((body.count < 128 ? [0x30, UInt8(body.count)] : [0x30, 0x81, UInt8(body.count)]) + body)
    }
}
