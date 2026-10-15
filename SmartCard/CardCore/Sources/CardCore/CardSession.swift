import Foundation

public actor CardSession {
    public static let library: [CardProfile] = CardProfiles.builtIn

    private static let chunkSize = 256
    private static let maxResponseChain = 64

    private let transport: any APDUTransport
    private let profile: CardProfile
    private var appletSelected = false
    /// Set once the card is gone or the session is closed; every later operation fails closed.
    private var ended: CardError?

    public init(transport: any APDUTransport, profile: CardProfile) {
        self.transport = transport
        self.profile = profile
    }

    /// Detects the profile from the transport's ATR; an unknown ATR is `CardError.unsupportedCard`.
    public static func open(transport: any APDUTransport, profiles: [CardProfile] = CardSession.library) throws -> CardSession {
        guard let profile = CardDetector.profile(for: transport.atr, in: profiles) else {
            throw CardError.unsupportedCard(transport.atr)
        }
        return CardSession(transport: transport, profile: profile)
    }

    /// DER certificates in `profile.certificateFiles` order; tables list the end-entity first.
    public func readCertificates() async throws -> [Data] {
        guard !profile.certificateFiles.isEmpty else { throw unresolved("certificate file paths") }
        try await selectApplet()
        var certificates: [Data] = []
        for path in profile.certificateFiles {
            let fids = try Self.fids(path)
            for (index, fid) in fids.enumerated() {
                let select: APDU =
                    index == 0 && fid == 0x3F00 ? .selectMF() : index == fids.count - 1 ? .selectEF(fid) : .selectDF(fid)
                _ = try await command(select)
            }
            certificates.append(try await readDER())
        }
        return certificates
    }

    /// Profile PIN length bounds, or nil when the card's PIN object is the only source.
    public func pinLengths() -> (min: Int, max: Int)? {
        guard let min = profile.pinMinLength, let max = profile.pinMaxLength else { return nil }
        return (min, max)
    }

    public func verifyPIN(_ pin: String) async throws {
        guard let reference = profile.pinReference else { throw unresolved("PIN reference") }
        let length = pin.utf8.count
        if let bounds = pinLengths() {
            guard length >= bounds.min, length <= bounds.max else { throw CardError.invalidPIN }
        } else {
            guard length > 0 else { throw CardError.invalidPIN }
        }
        try await selectApplet()
        _ = try await command(.verify(pin: pin, reference: reference, paddedLength: profile.pinPaddedLength))
    }

    /// `keyReference` overrides the profile's key for cards holding several. The result is the card's
    /// response unchanged (ECDSA encoding is a G3 item).
    public func sign(_ digest: Data, algorithm: CardProfile.Algorithm, keyReference: UInt8? = nil) async throws -> Data {
        guard profile.algorithms.contains(algorithm) else { throw CardError.unsupportedCard(transport.atr) }
        precondition(digest.count == algorithm.digestLength, "\(algorithm) needs a \(algorithm.digestLength)-byte digest")
        guard let key = keyReference ?? profile.keyReference else { throw unresolved("key reference") }
        try await selectApplet()
        _ = try await command(.mseSetDST(algorithmTemplate: algorithm.mseTemplate, keyReference: key))
        let signature = try await command(.computeDigitalSignature(algorithm.signatureInput(for: digest)))
        guard !signature.isEmpty else { throw CardError.transport("card returned an empty signature") }
        return signature
    }

    public func close() async {
        if ended == nil { ended = .transport("session closed") }
        await transport.close()
    }

    // MARK: - Files

    private func unresolved(_ what: String) -> CardError {
        .invalidProfile("\(profile.id): \(what) not yet discovered")
    }

    private func selectApplet() async throws {
        guard !appletSelected else { return }
        let select: APDU = profile.appletAID.map { APDU.selectAID($0) } ?? APDU.selectMF()
        _ = try await command(select)
        appletSelected = true
    }

    private static func fids(_ path: String) throws -> [UInt16] {
        let digits = Array(path)
        guard !digits.isEmpty, digits.count % 4 == 0, digits.allSatisfy(\.isHexDigit) else {
            throw CardError.invalidProfile("malformed certificate path \(path)")
        }
        return stride(from: 0, to: digits.count, by: 4).map { UInt16(String(digits[$0..<$0 + 4]), radix: 16)! }
    }

    /// Reads one DER certificate; the total size comes from the outer SEQUENCE header.
    private func readDER() async throws -> Data {
        var der = try await readChunk(offset: 0, length: Self.chunkSize)
        guard der.count >= 2, der[0] == 0x30 else { throw CardError.transport("certificate file is not DER") }
        var headerLength = 2
        var bodyLength = Int(der[1])
        if bodyLength & 0x80 != 0 {
            let lengthBytes = bodyLength & 0x7F
            guard (1...3).contains(lengthBytes), der.count >= 2 + lengthBytes else {
                throw CardError.transport("unsupported DER length encoding")
            }
            bodyLength = der[2..<2 + lengthBytes].reduce(0) { $0 << 8 | Int($1) }
            headerLength = 2 + lengthBytes
        }
        let total = headerLength + bodyLength
        guard total <= 0xFFFF else { throw CardError.transport("certificate larger than READ BINARY offset range") }
        while der.count < total {
            let more = try await readChunk(offset: der.count, length: min(Self.chunkSize, total - der.count))
            guard !more.isEmpty else { throw CardError.transport("certificate file truncated") }
            der += more
        }
        return Data(der.prefix(total))
    }

    /// 6282 (end of file before Le bytes) still carries valid data.
    private func readChunk(offset: Int, length: Int) async throws -> Data {
        let response = try await exchange(.readBinary(offset: offset, length: length))
        guard response.sw == 0x9000 || response.sw == 0x6282 else { throw CardError(sw: response.sw) }
        return response.data
    }

    // MARK: - Exchange

    private func command(_ apdu: APDU) async throws -> Data {
        let response = try await exchange(apdu)
        guard response.sw == 0x9000 else { throw CardError(sw: response.sw) }
        return response.data
    }

    /// Sends `apdu`, resending once with the correct Le on 6Cxx and collecting 61xx via GET RESPONSE.
    private func exchange(_ apdu: APDU) async throws -> APDUResponse {
        var current = apdu
        var collected = Data()
        var corrected = false
        for _ in 0..<Self.maxResponseChain {
            let response = try await send(current)
            switch response.sw1 {
            case 0x61:
                collected += response.data
                current = .getResponse(length: response.sw2 == 0 ? 256 : Int(response.sw2))
            case 0x6C where !corrected:
                corrected = true
                current = current.withLe(response.sw2 == 0 ? 256 : Int(response.sw2))
            default:
                return APDUResponse(data: collected + response.data, sw: response.sw)
            }
        }
        throw CardError.transport("response chain too long")
    }

    private func send(_ apdu: APDU) async throws -> APDUResponse {
        if let ended { throw ended }
        do {
            return try APDUResponse(raw: try await transport.transmit(apdu.bytes))
        } catch let error as CardError {
            if error == .cardRemoved { ended = error }
            throw error
        } catch {
            throw CardError.transport(String(describing: error))
        }
    }
}
