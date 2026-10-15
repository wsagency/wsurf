import Foundation
@testable import CardCore

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }
}

/// One scripted exchange: the exact request the session must send and what the card answers.
struct Exchange {
    let request: Data
    let reply: Result<Data, CardError>
}

func ex(_ request: String, _ response: Data) -> Exchange { Exchange(request: Data(hex: request), reply: .success(response)) }
func ex(_ request: String, _ responseHex: String) -> Exchange { ex(request, Data(hex: responseHex)) }
func ex(_ request: String, fail error: CardError) -> Exchange { Exchange(request: Data(hex: request), reply: .failure(error)) }

/// Scripted card: any deviation from the script fails the call with a `.transport` error naming it.
actor MockTransport: APDUTransport {
    nonisolated let atr: Data
    private var script: [Exchange]
    private(set) var sent: [Data] = []
    private(set) var closed = false

    init(atr: Data = Fixture.atr, script: [Exchange]) {
        self.atr = atr
        self.script = script
    }

    var remaining: Int { script.count }

    func transmit(_ apdu: Data) async throws -> Data {
        sent.append(apdu)
        guard !script.isEmpty else { throw CardError.transport("unscripted APDU \(apdu.hex)") }
        let next = script.removeFirst()
        guard next.request == apdu else {
            throw CardError.transport("expected \(next.request.hex), got \(apdu.hex)")
        }
        return try next.reply.get()
    }

    func close() { closed = true }
}

enum Fixture {
    /// Synthetic ATR used only by tests.
    static let atr = Data(hex: "3B9F01")
    static let aid = "A000000001"

    static func profile(
        aid: String? = Fixture.aid, files: [String], pinReference: UInt8? = 0x81, keyReference: UInt8? = 0x01,
        algorithms: [CardProfile.Algorithm] = [.rsaPkcsSha256, .ecdsaP256Sha256, .ecdsaP384Sha384]
    ) -> CardProfile {
        CardProfile(
            id: "test", displayName: "Test", atrMasks: [ATRMask(value: atr, mask: Data(hex: "FFFFFF"))],
            appletAID: aid.map { Data(hex: $0) }, certificateFiles: files,
            pinMinLength: 4, pinMaxLength: 8, pinPaddedLength: 8, pinDataObjectID: nil,
            pinReference: pinReference, keyReference: keyReference, algorithms: algorithms)
    }

    /// DER SEQUENCE of `body` filler bytes, with the minimal length encoding.
    static func cert(body: Int, fill: UInt8) -> Data {
        let header: [UInt8] =
            body < 0x80 ? [0x30, UInt8(body)]
            : body < 0x100 ? [0x30, 0x81, UInt8(body)]
            : [0x30, 0x82, UInt8(body >> 8), UInt8(body & 0xFF)]
        return Data(header) + Data(repeating: fill, count: body)
    }

    static let sha256DigestInfoHex = "3031300D060960864801650304020105000420"
}
