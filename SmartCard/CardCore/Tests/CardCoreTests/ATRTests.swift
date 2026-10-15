import Foundation
import Testing
@testable import CardCore

@Suite struct ATRMaskTests {
    let mask = ATRMask(value: Data(hex: "3BDF18"), mask: Data(hex: "FFFFFF"))

    @Test func exactMatchHits() {
        #expect(mask.matches(Data(hex: "3BDF18")))
    }

    @Test func longerATRMatchesOnPrefix() {
        #expect(mask.matches(Data(hex: "3BDF18FF81B1")))
    }

    @Test func differingByteMisses() {
        #expect(!mask.matches(Data(hex: "3BDF19FF")))
    }

    @Test func shorterATRMisses() {
        #expect(!mask.matches(Data(hex: "3BDF")))
        #expect(!mask.matches(Data()))
    }

    @Test func maskedBitsAreIgnoredAndUnmaskedBitsCompared() {
        let loose = ATRMask(value: Data(hex: "3B00"), mask: Data(hex: "FF0F"))
        #expect(loose.matches(Data(hex: "3BF0")))  // high nibble of byte 2 is don't-care
        #expect(loose.matches(Data(hex: "3B50")))
        #expect(!loose.matches(Data(hex: "3B01")))  // low nibble compared
    }

    @Test func valueBitsOutsideMaskAreIgnored() {
        let loose = ATRMask(value: Data(hex: "FF"), mask: Data(hex: "0F"))
        #expect(loose.matches(Data(hex: "0F")))
        #expect(loose.matches(Data(hex: "AF")))
    }
}

@Suite struct CardDetectorTests {
    func profile(_ id: String, _ value: String) -> CardProfile {
        CardProfile(
            id: id, displayName: id, atrMasks: [ATRMask(value: Data(hex: value), mask: Data(repeating: 0xFF, count: value.count / 2))],
            appletAID: nil, certificateFiles: [], pinMinLength: nil, pinMaxLength: nil, pinPaddedLength: nil,
            pinDataObjectID: nil, pinReference: nil, keyReference: nil, algorithms: [])
    }

    @Test func firstMatchingProfileWins() {
        let profiles = [profile("a", "3B00"), profile("b", "3B9F"), profile("c", "3B9F01")]
        #expect(CardDetector.profile(for: Data(hex: "3B9F01"), in: profiles)?.id == "b")
    }

    @Test func noMatchIsNil() {
        #expect(CardDetector.profile(for: Data(hex: "FFFF"), in: [profile("a", "3B00")]) == nil)
        #expect(CardDetector.profile(for: Data(hex: "3B00"), in: []) == nil)
    }

    @Test func builtInTableMatchesVendorATRsExactly() throws {
        let atr = Data(hex: "3BDD18FF81B1FE451FC39E414B442D43657274696C6961BD")
        #expect(CardDetector.profile(for: atr, in: CardSession.library)?.id == "certilia-gen2")
        // Exact full-string match: a different trailing byte (TCK) must not match.
        #expect(CardDetector.profile(for: Data(hex: "3BDD18FF81B1FE451FC39E414B442D43657274696C6961BE"), in: CardSession.library) == nil)
    }

    @Test func builtInATRsAreUniqueAcrossProfiles() {
        let all = CardSession.library.flatMap { $0.atrMasks.map(\.value) }
        #expect(Set(all).count == all.count)
        #expect(all.count == 15)
    }
}
