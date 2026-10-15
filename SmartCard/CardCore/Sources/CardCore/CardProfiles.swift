import Foundation

/// The built-in profile table. Adding a card family is a pure data edit: add a row to `rows`.
///
/// Source: build/research/card-profile-evidence.md (Certilia Middleware 3.9.12, static analysis).
///   - ATRs/ATS: the 15 exact strings of §2, registered by `CardRegistry::CardRegistry` (arm64 0xa9134).
///     The vendor matches full strings, no masks, so every mask here is all-FF.
///   - AIDs (§3/§4): Gen1 `A0000005016961736563632E617070` ("iasecc.app", via EF.DIR); Gen2
///     `A000000167455349474E` ("ESIGN"), the SelectApplet use site.
///   - Algorithms (§6): the vendor library's mechanism list is library-wide, so it is recorded for
///     every row; per-card support is a G3 item.
///
/// Discovery items for G3 (real-card probe), deliberately left nil/empty rather than invented:
///   - `certificateFiles`: §7 names EF.Cert* files but no numeric FIDs. Until filled,
///     `readCertificates()` throws `invalidProfile`.
///   - `pinReference` / `keyReference`: runtime values in the VERIFY / MSE use sites (§4). Until
///     filled, `verifyPIN` / `sign` throw `invalidProfile`.
///   - `pinDataObjectID`, PIN min/max: read from the card's PIN object (§5, GET DATA
///     `4D08 7006BF81<id>`); the exact data object bytes and runtime read are not extracted.
///   - Per-class APDU differences between Gen1 classes were not diffed (§9): rows differ only by ATR.
///   - Secure channel (Gen2 AES-CBC+CMAC, Gen1 3DES retail MAC, §4): no caller found for plain
///     VERIFY/PSO; whether signing needs it is unknown and NOT implemented here.
enum CardProfiles {
    static let builtIn: [CardProfile] = rows.map { row in
        CardProfile(
            id: row.id, displayName: row.displayName,
            atrMasks: row.atrs.map(exact),
            appletAID: Data(hex: row.gen2 ? gen2AID : gen1AID),
            certificateFiles: [], pinMinLength: nil, pinMaxLength: nil, pinPaddedLength: nil,
            pinDataObjectID: nil, pinReference: nil, keyReference: nil,
            algorithms: [.ecdsaP256Sha256, .ecdsaP384Sha384, .rsaPkcsSha256])
    }

    private static let gen1AID = "A0000005016961736563632E617070"
    private static let gen2AID = "A000000167455349474E"

    private struct Row {
        let id: String
        let displayName: String
        let gen2: Bool
        let atrs: [String]
    }

    /// Order follows the vendor registry (§2 #1–#15); #3/#4/#8/#11 are contactless ATS strings.
    private static let rows: [Row] = [
        Row(id: "akd-eid-base", displayName: "AKD eID Base Card", gen2: false, atrs: [
            "3BF91300008131FE454A434F503234325233A2",
            "3BFE9100FF918171FE400041380011F7B14A434F503234325211",
            "0E78F7B1024A434F503234325233",
            "0E7880B1024A434F503234325233",
        ]),
        Row(id: "akd-eid-card", displayName: "AKD eID Card", gen2: false, atrs: [
            "3BFF1300008131FE450031B9640444ECC17394018082900012",
        ]),
        Row(id: "mup-corporate", displayName: "MUP Corporate Card", gen2: false, atrs: [
            "3BFF1300008131FE450031B9640401ECC17394018082900057",
            "3B8F80010031B9640401ECC173940180829000BE",
            "1478F7B1020031B9640401ECC173940180829000",
        ]),
        Row(id: "akd-eid-health", displayName: "AKD eID Health Card", gen2: false, atrs: [
            "3BFF1300008131FE450031B9640402ECC17394018082900054",
            "3B8F80010031B9640402ECC173940180829000BD",
            "1478F7B1020031B9640402ECC173940180829000",
        ]),
        Row(id: "hlk-corporate", displayName: "HLK Corporate Card", gen2: false, atrs: [
            "3BFF1300008131FE450031B9640403ECC17394018082900055",
        ]),
        Row(id: "kid-corporate", displayName: "KID Corporate Card", gen2: false, atrs: [
            "3BFF1300008131FE450031B9640404ECC17394018082900052",
        ]),
        Row(id: "akd-eid-gen2", displayName: "AKD eID Gen2 Card", gen2: true, atrs: [
            "3BDF18FF81B1FE451FC39E414B44654944322E302D53534344D1",
        ]),
        Row(id: "certilia-gen2", displayName: "Certilia Gen2 Card", gen2: true, atrs: [
            "3BDD18FF81B1FE451FC39E414B442D43657274696C6961BD",
        ]),
    ]

    private static func exact(_ hex: String) -> ATRMask {
        let value = Data(hex: hex)
        return ATRMask(value: value, mask: Data(repeating: 0xFF, count: value.count))
    }
}

extension Data {
    /// Hex literal for static tables; malformed input is a programmer error.
    init(hex: String) {
        precondition(hex.count % 2 == 0, "odd hex length")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
