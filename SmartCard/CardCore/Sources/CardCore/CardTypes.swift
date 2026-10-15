import Foundation

public protocol APDUTransport: Sendable {
    var atr: Data { get }
    /// Raw response APDU including SW1SW2.
    func transmit(_ apdu: Data) async throws -> Data
    func close() async
}

public enum CardError: Error, Equatable {
    case unsupportedCard(Data)
    case cardRemoved
    case pinWrong(remaining: Int)
    case pinBlocked
    case transport(String)
    case fileNotFound
    case incorrectParameters
    case unexpectedStatus(UInt16)
    /// PIN length outside the profile's range; rejected before any APDU is sent.
    case invalidPIN
    case invalidProfile(String)
}

extension CardError {
    /// Maps a non-success status word to its typed error.
    init(sw: UInt16) {
        switch sw {
        case 0x63C0...0x63CF: self = .pinWrong(remaining: Int(sw & 0x000F))
        case 0x6983: self = .pinBlocked
        case 0x6A82: self = .fileNotFound
        case 0x6A86: self = .incorrectParameters
        default: self = .unexpectedStatus(sw)
        }
    }
}

public struct ATRMask: Sendable, Equatable {
    public let value: Data
    public let mask: Data

    public init(value: Data, mask: Data) {
        precondition(value.count == mask.count, "ATR mask length must equal value length")
        self.value = value
        self.mask = mask
    }

    /// Prefix match: the ATR may be longer than `value`; only masked bits are compared.
    public func matches(_ atr: Data) -> Bool {
        guard atr.count >= value.count else { return false }
        return zip(zip(value, mask), atr).allSatisfy { vm, byte in byte & vm.1 == vm.0 & vm.1 }
    }
}

public struct CardProfile: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let atrMasks: [ATRMask]
    /// SELECT by AID before file operations; nil selects the MF only.
    public let appletAID: Data?
    /// Hex file-id paths, 4 hex digits per FID, e.g. "3F00DF015031": MF → DF → EF. Empty = not yet discovered.
    public let certificateFiles: [String]
    /// Nil = not hardcoded for this card; the card's PIN object holds it (see `pinDataObjectID`).
    public let pinMinLength: Int?
    public let pinMaxLength: Int?
    /// PIN is right-padded with 0xFF to this length; nil = unpadded.
    public let pinPaddedLength: Int?
    /// Id of the PIN object read with GET DATA `4D08 7006BF81<id>`; nil = use the profile constants.
    public let pinDataObjectID: UInt8?
    /// P2 of VERIFY; nil = not yet discovered, VERIFY refuses to run.
    public let pinReference: UInt8?
    /// Key reference for MSE SET DST; nil = not yet discovered, signing refuses to run.
    public let keyReference: UInt8?
    public enum Algorithm: Sendable, Equatable {
        case ecdsaP256Sha256, ecdsaP384Sha384
        /// RSA PKCS#1 v1.5 over SHA-256; the key size is a property of the card's key, not of this case.
        case rsaPkcsSha256
    }
    public let algorithms: [Algorithm]

    public init(
        id: String, displayName: String, atrMasks: [ATRMask], appletAID: Data?,
        certificateFiles: [String], pinMinLength: Int?, pinMaxLength: Int?, pinPaddedLength: Int?,
        pinDataObjectID: UInt8?, pinReference: UInt8?, keyReference: UInt8?, algorithms: [Algorithm]
    ) {
        self.id = id
        self.displayName = displayName
        self.atrMasks = atrMasks
        self.appletAID = appletAID
        self.certificateFiles = certificateFiles
        self.pinMinLength = pinMinLength
        self.pinMaxLength = pinMaxLength
        self.pinPaddedLength = pinPaddedLength
        self.pinDataObjectID = pinDataObjectID
        self.pinReference = pinReference
        self.keyReference = keyReference
        self.algorithms = algorithms
    }
}

public enum CardDetector {
    /// First profile with any matching ATR mask; no match means the card is unsupported.
    public static func profile(for atr: Data, in profiles: [CardProfile]) -> CardProfile? {
        profiles.first { $0.atrMasks.contains { $0.matches(atr) } }
    }
}
