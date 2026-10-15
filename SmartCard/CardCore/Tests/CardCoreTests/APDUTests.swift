import Foundation
import Testing
@testable import CardCore

@Suite struct APDUBuilderTests {
    @Test func selectFamily() {
        #expect(APDU.selectMF().bytes == Data(hex: "00A4000C023F00"))
        #expect(APDU.selectDF(0xDF01).bytes == Data(hex: "00A4010C02DF01"))
        #expect(APDU.selectEF(0x5031).bytes == Data(hex: "00A4020C025031"))
        #expect(APDU.selectAID(Data(hex: "A000000167455349474E")).bytes == Data(hex: "00A4040C0AA000000167455349474E"))
    }

    @Test func readBinaryShort() {
        #expect(APDU.readBinary(offset: 0x0102, length: 0x20).bytes == Data(hex: "00B0010220"))
        #expect(APDU.readBinary(offset: 0, length: 256).bytes == Data(hex: "00B0000000"))
        #expect(APDU.readBinary(offset: 0x7FFF, length: 1).bytes == Data(hex: "00B07FFF01"))
    }

    @Test func readBinaryExtendedLength() {
        #expect(APDU.readBinary(offset: 0, length: 1024).bytes == Data(hex: "00B00000" + "00" + "0400"))
        #expect(APDU.readBinary(offset: 0x0010, length: 65536).bytes == Data(hex: "00B00010" + "00" + "0000"))
        #expect(APDU.readBinary(offset: 0, length: 257).bytes == Data(hex: "00B00000" + "00" + "0101"))
    }

    @Test func readBinaryOddInstructionBeyondFifteenBitOffset() {
        #expect(APDU.readBinary(offset: 0x8000, length: 16).bytes == Data(hex: "00B10000" + "04" + "54028000" + "10"))
        // Odd INS with extended Le forces extended Lc as well.
        #expect(
            APDU.readBinary(offset: 0x9ABC, length: 1024).bytes
                == Data(hex: "00B10000" + "000004" + "54029ABC" + "0400"))
    }

    @Test func getResponse() {
        #expect(APDU.getResponse(length: 0x80).bytes == Data(hex: "00C0000080"))
        #expect(APDU.getResponse(length: 256).bytes == Data(hex: "00C0000000"))
    }

    @Test func verifyPadsWithFFWhenProfileSaysSo() {
        #expect(
            APDU.verify(pin: "1234", reference: 0x81, paddedLength: 8).bytes
                == Data(hex: "00200081" + "08" + "31323334FFFFFFFF"))
    }

    @Test func verifyUnpaddedAndFullLength() {
        #expect(APDU.verify(pin: "1234", reference: 0x80, paddedLength: nil).bytes == Data(hex: "00200080" + "04" + "31323334"))
        #expect(
            APDU.verify(pin: "12345678", reference: 0x80, paddedLength: 8).bytes
                == Data(hex: "00200080" + "08" + "3132333435363738"))
    }

    @Test func mseSetDST() {
        #expect(
            APDU.mseSetDST(algorithmTemplate: CardProfile.Algorithm.ecdsaP256Sha256.mseTemplate, keyReference: 0x03).bytes
                == Data(hex: "002241B6" + "09" + "8004FF1408" + "00" + "840103"))
        #expect(
            APDU.mseSetDST(algorithmTemplate: CardProfile.Algorithm.ecdsaP384Sha384.mseTemplate, keyReference: 0x03).bytes
                == Data(hex: "002241B6" + "09" + "8004FF1508" + "00" + "840103"))
        #expect(
            APDU.mseSetDST(algorithmTemplate: CardProfile.Algorithm.rsaPkcsSha256.mseTemplate, keyReference: 0x01).bytes
                == Data(hex: "002241B6" + "03" + "840101"))
    }

    @Test func computeDigitalSignature() {
        let digest = Data(repeating: 0xAB, count: 32)
        #expect(APDU.computeDigitalSignature(digest).bytes == Data(hex: "002A9E9A20") + digest + Data([0x00]))
    }

    @Test func signatureInputPerAlgorithm() {
        let digest = Data(repeating: 0xAB, count: 32)
        #expect(CardProfile.Algorithm.ecdsaP256Sha256.signatureInput(for: digest) == digest)
        #expect(
            CardProfile.Algorithm.rsaPkcsSha256.signatureInput(for: digest)
                == Data(hex: Fixture.sha256DigestInfoHex) + digest)
    }
}

@Suite struct APDUResponseTests {
    @Test func splitsDataAndStatus() throws {
        let response = try APDUResponse(raw: Data(hex: "0102039000"))
        #expect(response.data == Data(hex: "010203"))
        #expect(response.sw == 0x9000)
        #expect(response.sw1 == 0x90 && response.sw2 == 0x00)
    }

    @Test func statusOnly() throws {
        #expect(try APDUResponse(raw: Data(hex: "6A82")).data.isEmpty)
    }

    @Test func tooShortIsTransportError() {
        #expect(throws: CardError.transport("response shorter than SW1SW2")) { try APDUResponse(raw: Data([0x90])) }
    }

    @Test func statusWordMapping() {
        #expect(CardError(sw: 0x63C2) == .pinWrong(remaining: 2))
        #expect(CardError(sw: 0x63C0) == .pinWrong(remaining: 0))
        #expect(CardError(sw: 0x63CF) == .pinWrong(remaining: 15))
        #expect(CardError(sw: 0x6983) == .pinBlocked)
        #expect(CardError(sw: 0x6A82) == .fileNotFound)
        #expect(CardError(sw: 0x6A86) == .incorrectParameters)
        #expect(CardError(sw: 0x6982) == .unexpectedStatus(0x6982))
    }
}
