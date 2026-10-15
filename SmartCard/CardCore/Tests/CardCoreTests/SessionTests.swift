import Foundation
import Testing
@testable import CardCore

private let selectAID = "00A4040C05" + Fixture.aid
private let pin1234 = "0020008108" + "31323334FFFFFFFF"
private let digest = Data(repeating: 0xAB, count: 32)

private func make(_ profile: CardProfile, _ script: [Exchange]) -> (CardSession, MockTransport) {
    let transport = MockTransport(script: script)
    return (CardSession(transport: transport, profile: profile), transport)
}

@Suite struct CardSessionTests {
    @Test func readsChainAcrossFilesWithMultiChunkAndLeCorrection() async throws {
        let first = Fixture.cert(body: 296, fill: 0x11)  // 300 bytes: needs a second READ BINARY
        let second = Fixture.cert(body: 48, fill: 0x22)  // 50 bytes: card answers 6C32 to Le=256
        let (session, transport) = make(
            Fixture.profile(files: ["C001", "C002"]),
            [
                ex(selectAID, "9000"),
                ex("00A4020C02C001", "9000"),
                ex("00B0000000", first.prefix(256) + Data(hex: "9000")),
                ex("00B001002C", first[256..<300] + Data(hex: "9000")),
                ex("00A4020C02C002", "9000"),
                ex("00B0000000", "6C32"),
                ex("00B0000032", second + Data(hex: "9000")),
            ])
        let certificates = try await session.readCertificates()
        #expect(certificates == [first, second])
        #expect(await transport.remaining == 0)
    }

    @Test func collectsChained61xxWithGetResponse() async throws {
        let cert = Fixture.cert(body: 253, fill: 0x33)  // 3-byte header + 253 = 256 bytes
        let (session, transport) = make(
            Fixture.profile(files: ["C001"]),
            [
                ex(selectAID, "9000"),
                ex("00A4020C02C001", "9000"),
                ex("00B0000000", cert.prefix(128) + Data(hex: "6180")),
                ex("00C0000080", cert[128..<256] + Data(hex: "9000")),
            ])
        #expect(try await session.readCertificates() == [cert])
        #expect(await transport.remaining == 0)
    }

    @Test func walksMFDFEFPathWhenProfileHasNoAID() async throws {
        let cert = Fixture.cert(body: 18, fill: 0x44)  // 20 bytes
        let (session, transport) = make(
            Fixture.profile(aid: nil, files: ["3F00AA00BB01"]),
            [
                ex("00A4000C023F00", "9000"),  // applet step: MF
                ex("00A4000C023F00", "9000"),
                ex("00A4010C02AA00", "9000"),
                ex("00A4020C02BB01", "9000"),
                ex("00B0000000", cert + Data(hex: "6282")),  // end of file reached: data still valid
            ])
        #expect(try await session.readCertificates() == [cert])
        #expect(await transport.remaining == 0)
    }

    @Test func missingFileMapsToFileNotFound() async {
        let (session, _) = make(Fixture.profile(files: ["C001"]), [ex(selectAID, "9000"), ex("00A4020C02C001", "6A82")])
        await #expect(throws: CardError.fileNotFound) { try await session.readCertificates() }
    }

    @Test func unexpectedReadStatusIsReported() async {
        let (session, _) = make(
            Fixture.profile(files: ["C001"]),
            [ex(selectAID, "9000"), ex("00A4020C02C001", "9000"), ex("00B0000000", "6B00")])
        await #expect(throws: CardError.unexpectedStatus(0x6B00)) { try await session.readCertificates() }
    }

    @Test func nonDERFileIsRejected() async {
        let (session, _) = make(
            Fixture.profile(files: ["C001"]),
            [ex(selectAID, "9000"), ex("00A4020C02C001", "9000"), ex("00B0000000", "FFFFFFFF9000")])
        await #expect(throws: CardError.transport("certificate file is not DER")) { try await session.readCertificates() }
    }

    @Test func verifyThenRSASignHappyPath() async throws {
        let signature = Data(repeating: 0x5A, count: 256)
        let (session, transport) = make(
            Fixture.profile(files: ["C001"]),
            [
                ex(selectAID, "9000"),
                ex(pin1234, "9000"),
                ex("002241B6" + "03" + "840101", "9000"),
                ex("002A9E9A33" + Fixture.sha256DigestInfoHex + digest.hex + "00", signature + Data(hex: "9000")),
            ])
        try await session.verifyPIN("1234")
        #expect(try await session.sign(digest, algorithm: .rsaPkcsSha256) == signature)
        #expect(await transport.remaining == 0)  // the applet was selected exactly once
    }

    @Test func ecdsaP384SignUsesKeyOverrideAndRawHash() async throws {
        let digest48 = Data(repeating: 0xCD, count: 48)
        let signature = Data(repeating: 0x07, count: 96)
        let (session, transport) = make(
            Fixture.profile(files: ["C001"]),
            [
                ex(selectAID, "9000"),
                ex("002241B6" + "09" + "8004FF1508" + "00" + "840102", "9000"),
                ex("002A9E9A30" + digest48.hex + "00", signature + Data(hex: "9000")),
            ])
        #expect(try await session.sign(digest48, algorithm: .ecdsaP384Sha384, keyReference: 0x02) == signature)
        #expect(await transport.remaining == 0)
    }

    @Test func wrongPINReportsRetriesLeftAndSessionStaysUsable() async {
        let (session, transport) = make(
            Fixture.profile(files: ["C001"]),
            [ex(selectAID, "9000"), ex(pin1234, "63C2"), ex("0020008108" + "35363738FFFFFFFF", "63C1")])
        await #expect(throws: CardError.pinWrong(remaining: 2)) { try await session.verifyPIN("1234") }
        await #expect(throws: CardError.pinWrong(remaining: 1)) { try await session.verifyPIN("5678") }
        #expect(await transport.remaining == 0)
    }

    @Test func blockedPIN() async {
        let (session, _) = make(Fixture.profile(files: ["C001"]), [ex(selectAID, "9000"), ex(pin1234, "6983")])
        await #expect(throws: CardError.pinBlocked) { try await session.verifyPIN("1234") }
    }

    @Test func pinOutsideProfileRangeIsRejectedWithoutTouchingTheCard() async {
        let (session, transport) = make(Fixture.profile(files: ["C001"]), [])
        await #expect(throws: CardError.invalidPIN) { try await session.verifyPIN("123") }
        await #expect(throws: CardError.invalidPIN) { try await session.verifyPIN("123456789") }
        #expect(await transport.sent.isEmpty)
    }

    @Test func cardRemovedMidSignFailsClosed() async {
        let (session, transport) = make(
            Fixture.profile(files: ["C001"]),
            [
                ex(selectAID, "9000"),
                ex(pin1234, "9000"),
                ex("002241B6" + "03" + "840101", "9000"),
                ex("002A9E9A33" + Fixture.sha256DigestInfoHex + digest.hex + "00", fail: .cardRemoved),
            ])
        await #expect(throws: CardError.cardRemoved) {
            try await session.verifyPIN("1234")
            _ = try await session.sign(digest, algorithm: .rsaPkcsSha256)
        }
        #expect(await transport.sent.count == 4)
        await #expect(throws: CardError.cardRemoved) { try await session.verifyPIN("1234") }
        #expect(await transport.sent.count == 4)  // nothing further reached the transport
    }

    @Test func closedSessionRefusesOperationsAndClosesTransport() async {
        let (session, transport) = make(Fixture.profile(files: ["C001"]), [])
        await session.close()
        #expect(await transport.closed)
        await #expect(throws: CardError.transport("session closed")) { try await session.verifyPIN("1234") }
        #expect(await transport.sent.isEmpty)
    }

    @Test func undiscoveredProfileFieldsFailWithInvalidProfileBeforeAnyAPDU() async {
        let (noKey, keyTransport) = make(Fixture.profile(files: ["C001"], keyReference: nil), [])
        await #expect(throws: CardError.invalidProfile("test: key reference not yet discovered")) {
            try await noKey.sign(digest, algorithm: .rsaPkcsSha256)
        }
        let (noPin, _) = make(Fixture.profile(files: ["C001"], pinReference: nil), [])
        await #expect(throws: CardError.invalidProfile("test: PIN reference not yet discovered")) {
            try await noPin.verifyPIN("1234")
        }
        let (noFiles, _) = make(Fixture.profile(files: []), [])
        await #expect(throws: CardError.invalidProfile("test: certificate file paths not yet discovered")) {
            try await noFiles.readCertificates()
        }
        #expect(await keyTransport.sent.isEmpty)
    }

    @Test func algorithmOutsideProfileIsUnsupported() async {
        let (session, _) = make(Fixture.profile(files: ["C001"], algorithms: [.rsaPkcsSha256]), [])
        await #expect(throws: CardError.unsupportedCard(Fixture.atr)) {
            try await session.sign(Data(repeating: 0, count: 32), algorithm: .ecdsaP256Sha256)
        }
    }

    @Test func openDetectsProfileOrReportsUnsupported() throws {
        let profile = Fixture.profile(files: ["C001"])
        _ = try CardSession.open(transport: MockTransport(script: []), profiles: [profile])
        let unknown = Data(hex: "FFFF")
        #expect(throws: CardError.unsupportedCard(unknown)) {
            try CardSession.open(transport: MockTransport(atr: unknown, script: []), profiles: [profile])
        }
    }

    @Test func pinLengthsComeFromProfileConstants() async {
        let (session, _) = make(Fixture.profile(files: ["C001"]), [])
        let lengths = await session.pinLengths()
        #expect(lengths?.min == 4 && lengths?.max == 8)
    }
}
