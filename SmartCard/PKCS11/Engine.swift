import CardCore
import CryptoKit
import Foundation

// CK_RV / CKA_* / CKM_* values from PKCS#11 v2.40 (OASIS) that the engine uses.
private enum RV {
    static let ok: UInt = 0x00
    static let slotIDInvalid: UInt = 0x03
    static let general: UInt = 0x05
    static let dataLenRange: UInt = 0x21
    static let deviceError: UInt = 0x30
    static let deviceRemoved: UInt = 0x32
    static let keyHandleInvalid: UInt = 0x60
    static let keyTypeInconsistent: UInt = 0x63
    static let mechanismInvalid: UInt = 0x70
    static let objectHandleInvalid: UInt = 0x82
    static let operationActive: UInt = 0x90
    static let operationNotInitialized: UInt = 0x91
    static let pinIncorrect: UInt = 0xA0
    static let pinLenRange: UInt = 0xA2
    static let pinLocked: UInt = 0xA4
    static let sessionHandleInvalid: UInt = 0xB3
    static let tokenNotPresent: UInt = 0xE0
    static let tokenNotRecognized: UInt = 0xE1
    static let userAlreadyLoggedIn: UInt = 0x100
    static let userNotLoggedIn: UInt = 0x101
    static let userTypeInvalid: UInt = 0x103
    static let bufferTooSmall: UInt = 0x150
    static let notInitialized: UInt = 0x190
    static let alreadyInitialized: UInt = 0x191
    static let attributeTypeInvalid: UInt = 0x12
}

private enum CKA {
    static let `class`: UInt = 0x000
    static let token: UInt = 0x001
    static let `private`: UInt = 0x002
    static let label: UInt = 0x003
    static let value: UInt = 0x011
    static let certificateType: UInt = 0x080
    static let issuer: UInt = 0x081
    static let serialNumber: UInt = 0x082
    static let trusted: UInt = 0x086
    static let certificateCategory: UInt = 0x087
    static let keyType: UInt = 0x100
    static let subject: UInt = 0x101
    static let id: UInt = 0x102
    static let sensitive: UInt = 0x103
    static let encrypt: UInt = 0x104
    static let decrypt: UInt = 0x105
    static let wrap: UInt = 0x106
    static let unwrap: UInt = 0x107
    static let sign: UInt = 0x108
    static let signRecover: UInt = 0x109
    static let verify: UInt = 0x10A
    static let verifyRecover: UInt = 0x10B
    static let derive: UInt = 0x10C
    static let modulus: UInt = 0x120
    static let modulusBits: UInt = 0x121
    static let publicExponent: UInt = 0x122
    static let extractable: UInt = 0x162
    static let local: UInt = 0x163
    static let neverExtractable: UInt = 0x164
    static let alwaysSensitive: UInt = 0x165
    static let modifiable: UInt = 0x170
    static let ecParams: UInt = 0x180
    static let ecPoint: UInt = 0x181
    static let alwaysAuthenticate: UInt = 0x202
}

private enum CKM {
    static let sha256RSAPKCS: UInt = 0x40
    static let ecdsa: UInt = 0x1041
}

private let userUserType: UInt = 1
private let certificateHandleBase: UInt = 0x100
private let publicKeyHandle: UInt = 0x200
private let privateKeyHandle: UInt = 0x300

private struct Slot {
    let id: UInt
    let reader: String
    let atr: Data
    let profile: CardProfile
}

/// One connection to a card, shared by every session on that slot (PKCS#11 login state is per token).
private final class Token {
    let slot: Slot
    var card: CardSession?
    var certificates: [Certificate]?
    var loggedIn = false

    init(slot: Slot) { self.slot = slot }

    /// Object kinds exist only for certificate[0]'s key: CardCore signs with the profile's single key reference.
    var hasKey: Bool { certificates?.isEmpty == false }

    func close() {
        guard let card else { return }
        self.card = nil
        _ = try? blocking { await card.close() }
    }
}

private struct SignOperation {
    let algorithm: CardProfile.Algorithm
    let hashesMessage: Bool
    let digestLength: Int
    let ecComponentLength: Int?
    let signatureLength: Int
}

private struct Session {
    let slotID: UInt
    var filters: [(type: UInt, value: Data)]?
    var matches: [UInt]?
    var cursor = 0
    var signOperation: SignOperation?
}

private struct State {
    var initialized = false
    var slots: [UInt: Slot] = [:]
    var tokens: [UInt: Token] = [:]
    var sessions: [UInt: Session] = [:]
    var pinRanges: [UInt: (min: UInt, max: UInt)] = [:]
    var nextSession: UInt = 1
}

/// Every entry point takes this one lock for its whole duration, including card I/O.
/// ponytail: global lock; the card is a single serial resource, per-token locks buy nothing.
private final class Module: @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    func perform(_ body: (inout State) -> UInt) -> UInt {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    func initialized(_ body: (inout State) -> UInt) -> UInt {
        perform { $0.initialized ? body(&$0) : RV.notInitialized }
    }
}

private let module = Module()

// MARK: - Helpers

private func slotID(for reader: String) -> UInt {
    var hash: UInt32 = 2_166_136_261
    for byte in reader.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
    return UInt(hash)
}

private func closeToken(_ state: inout State, _ slot: UInt) {
    state.tokens.removeValue(forKey: slot)?.close()
}

private func ulong(_ value: UInt) -> Data { withUnsafeBytes(of: value) { Data($0) } }
private func bool(_ value: Bool) -> Data { Data([value ? 1 : 0]) }

/// Maps a card failure to CK_RV; a removed card also drops the token so later calls fail closed.
private func status(_ error: Error, slot: UInt, _ state: inout State) -> UInt {
    guard let error = error as? CardError else { return RV.deviceError }
    switch error {
    case .pinWrong: return RV.pinIncorrect
    case .pinBlocked: return RV.pinLocked
    case .invalidPIN: return RV.pinLenRange
    case .unsupportedCard: return RV.tokenNotRecognized
    case .cardRemoved:
        closeToken(&state, slot)
        state.slots[slot] = nil
        return RV.deviceRemoved
    default: return RV.deviceError
    }
}

private func probe(_ reader: String) -> Slot? {
    guard let transport = try? PCSCTransport(readerName: reader) else { return nil }
    let atr = transport.atr
    _ = try? blocking { await transport.close() }
    guard let profile = CardDetector.profile(for: atr, in: CardSession.library) else { return nil }
    return Slot(id: slotID(for: reader), reader: reader, atr: atr, profile: profile)
}

/// Rescans readers. A reader whose token is already connected is not probed again (a second PC/SC
/// connection would contend with ours); its removal surfaces as `cardRemoved` on the next card operation.
private func refresh(_ state: inout State) {
    let readers = (try? PCSCTransport.readers()) ?? []
    var slots: [UInt: Slot] = [:]
    for reader in readers {
        let id = slotID(for: reader)
        if let token = state.tokens[id] {
            slots[id] = token.slot
        } else if let slot = probe(reader) {
            slots[id] = slot
        }
    }
    for id in Array(state.tokens.keys) where slots[id] == nil { closeToken(&state, id) }
    state.slots = slots
}

private func ensureCard(_ token: Token) -> UInt {
    if token.card != nil { return RV.ok }
    guard let transport = try? PCSCTransport(readerName: token.slot.reader) else { return RV.tokenNotPresent }
    guard transport.atr == token.slot.atr else {
        _ = try? blocking { await transport.close() }
        return RV.deviceRemoved
    }
    token.card = CardSession(transport: transport, profile: token.slot.profile)
    return RV.ok
}

private func loadCertificates(_ token: Token, _ state: inout State) -> UInt {
    guard let card = token.card else { return RV.general }
    do {
        let ders = try blocking { try await card.readCertificates() }
        // Certificate[0] is the end-entity certificate (CardCore table convention); without it there is no key.
        guard let first = ders.first, Certificate(der: first) != nil else { return RV.deviceError }
        token.certificates = ders.compactMap { Certificate(der: $0) }
        return RV.ok
    } catch {
        return status(error, slot: token.slot.id, &state)
    }
}

private func copyOut(_ values: [UInt], _ out: UnsafeMutablePointer<UInt>?, _ count: UnsafeMutablePointer<UInt>) -> UInt {
    let capacity = count.pointee
    count.pointee = UInt(values.count)
    guard let out else { return RV.ok }
    guard capacity >= UInt(values.count) else { return RV.bufferTooSmall }
    for (index, value) in values.enumerated() { out[index] = value }
    return RV.ok
}

private func lookup(_ state: State, _ session: UInt) -> (Session, Token)? {
    guard let value = state.sessions[session], let token = state.tokens[value.slotID] else { return nil }
    return (value, token)
}

/// Distinguishes a bad session handle from a session whose card was removed.
private func lookupFailure(_ state: State, _ session: UInt) -> UInt {
    state.sessions[session] == nil ? RV.sessionHandleInvalid : RV.deviceRemoved
}

private func pinRange(_ state: inout State, _ slot: Slot) -> (min: UInt, max: UInt) {
    if slot.profile.pinDataObjectID != nil {
        if let cached = state.pinRanges[slot.id] { return cached }
        let existing = state.tokens[slot.id]
        let token = existing ?? Token(slot: slot)
        defer { if existing == nil { token.close() } }
        if ensureCard(token) == RV.ok, let card = token.card,
           let lengths = (try? blocking { await card.pinLengths() })
        {
            let range = (min: UInt(lengths.min), max: UInt(lengths.max))
            state.pinRanges[slot.id] = range
            return range
        }
    }
    return (
        min: slot.profile.pinMinLength.map { UInt($0) } ?? UInt.max,
        max: slot.profile.pinMaxLength.map { UInt($0) } ?? UInt.max
    )
}

// MARK: - Objects

private enum Object {
    case certificate(Int)
    case publicKey
    case privateKey
}

private func resolve(_ token: Token, _ handle: UInt) -> Object? {
    guard let certificates = token.certificates else { return nil }
    switch handle {
    case certificateHandleBase..<(certificateHandleBase + UInt(certificates.count)):
        return .certificate(Int(handle - certificateHandleBase))
    case publicKeyHandle where token.hasKey: return .publicKey
    case privateKeyHandle where token.hasKey && token.loggedIn: return .privateKey
    default: return nil
    }
}

private func allHandles(_ token: Token) -> [UInt] {
    let certificates = (token.certificates ?? []).indices.map { certificateHandleBase + UInt($0) }
    return certificates + (token.hasKey ? [publicKeyHandle] + (token.loggedIn ? [privateKeyHandle] : []) : [])
}

private func attribute(_ token: Token, _ handle: UInt, _ type: UInt) -> Data? {
    guard let object = resolve(token, handle), let certificates = token.certificates else { return nil }
    let index: Int
    switch object {
    case .certificate(let i): index = i
    case .publicKey, .privateKey: index = 0
    }
    let certificate = certificates[index]
    let id = Data([UInt8(truncatingIfNeeded: index + 1)])
    let kind: String
    switch (object, certificate.key) {
    case (.certificate, _): kind = "Certificate"
    case (.publicKey, .rsa): kind = "RSA Public Key"
    case (.publicKey, .ec): kind = "EC Public Key"
    case (.privateKey, .rsa): kind = "RSA Private Key"
    case (.privateKey, .ec): kind = "EC Private Key"
    }

    switch type {
    case CKA.class:
        switch object {
        case .certificate: return ulong(1)  // CKO_CERTIFICATE
        case .publicKey: return ulong(2)  // CKO_PUBLIC_KEY
        case .privateKey: return ulong(3)  // CKO_PRIVATE_KEY
        }
    case CKA.token: return bool(true)
    case CKA.modifiable: return bool(false)
    case CKA.label: return Data("\(certificate.role) \(kind)".utf8)
    case CKA.id: return id
    case CKA.private:
        if case .privateKey = object { return bool(true) }
        return bool(false)
    default: break
    }

    switch object {
    case .certificate:
        switch type {
        case CKA.certificateType: return ulong(0)  // CKC_X_509
        case CKA.certificateCategory: return ulong(0)
        case CKA.trusted: return bool(false)
        case CKA.value: return certificate.der
        case CKA.subject: return certificate.subject
        case CKA.issuer: return certificate.issuer
        case CKA.serialNumber: return certificate.serial
        default: return nil
        }
    case .publicKey, .privateKey:
        let isPrivate: Bool
        if case .privateKey = object { isPrivate = true } else { isPrivate = false }
        switch type {
        case CKA.keyType:
            if case .rsa = certificate.key { return ulong(0) }  // CKK_RSA
            return ulong(3)  // CKK_EC
        case CKA.subject: return certificate.subject
        case CKA.derive, CKA.decrypt, CKA.unwrap, CKA.signRecover, CKA.encrypt, CKA.wrap, CKA.verifyRecover:
            return bool(false)
        case CKA.local: return bool(true)
        case CKA.verify: return isPrivate ? nil : bool(true)
        case CKA.sign: return isPrivate ? bool(true) : nil
        case CKA.sensitive, CKA.alwaysSensitive, CKA.neverExtractable: return isPrivate ? bool(true) : nil
        case CKA.extractable, CKA.alwaysAuthenticate: return isPrivate ? bool(false) : nil
        default: break
        }
        switch certificate.key {
        case .rsa(let modulus, let exponent):
            switch type {
            case CKA.modulus: return modulus
            case CKA.publicExponent: return exponent
            case CKA.modulusBits: return isPrivate ? nil : ulong(UInt(modulus.count * 8))
            default: return nil
            }
        case .ec(let curve, let point):
            switch type {
            case CKA.ecParams: return curve
            // DER OCTET STRING wrapping the point (PKCS#11 v2.40 §2.3.3); P-256/P-384 points are < 128 bytes.
            case CKA.ecPoint: return isPrivate ? nil : Data([0x04, UInt8(point.count)]) + point
            default: return nil
            }
        }
    }
}

private func mechanisms(_ profile: CardProfile) -> [UInt] {
    var result: [UInt] = []
    for algorithm in profile.algorithms {
        let mechanism = algorithm == .rsaPkcsSha256 ? CKM.sha256RSAPKCS : CKM.ecdsa
        if !result.contains(mechanism) { result.append(mechanism) }
    }
    return result
}

// MARK: - Entry points

@_cdecl("wsc_initialize")
func wscInitialize() -> UInt {
    module.perform { state in
        if state.initialized { return RV.alreadyInitialized }
        state.initialized = true
        return RV.ok
    }
}

@_cdecl("wsc_finalize")
func wscFinalize() -> UInt {
    module.initialized { state in
        for id in Array(state.tokens.keys) { closeToken(&state, id) }
        state = State()
        return RV.ok
    }
}

@_cdecl("wsc_slot_list")
func wscSlotList(_ ids: UnsafeMutablePointer<UInt>?, _ count: UnsafeMutablePointer<UInt>) -> UInt {
    module.initialized { state in
        refresh(&state)
        return copyOut(state.slots.keys.sorted(), ids, count)
    }
}

@_cdecl("wsc_slot_text")
func wscSlotText(_ slot: UInt, _ field: Int32, _ out: UnsafeMutablePointer<CChar>, _ capacity: Int) -> UInt {
    module.initialized { state in
        guard let slot = state.slots[slot] else { return RV.slotIDInvalid }
        let text = field == 0 ? slot.reader : slot.profile.displayName
        let bytes = Array(text.utf8.prefix(max(capacity - 1, 0)))
        for (index, byte) in bytes.enumerated() { out[index] = CChar(bitPattern: byte) }
        out[bytes.count] = 0
        return RV.ok
    }
}

@_cdecl("wsc_slot_pin_range")
func wscSlotPinRange(_ slot: UInt, _ min: UnsafeMutablePointer<UInt>, _ max: UnsafeMutablePointer<UInt>) -> UInt {
    module.initialized { state in
        guard let slot = state.slots[slot] else { return RV.slotIDInvalid }
        let range = pinRange(&state, slot)
        min.pointee = range.min
        max.pointee = range.max
        return RV.ok
    }
}

@_cdecl("wsc_slot_mechanisms")
func wscSlotMechanisms(_ slot: UInt, _ types: UnsafeMutablePointer<UInt>?, _ count: UnsafeMutablePointer<UInt>) -> UInt {
    module.initialized { state in
        guard let slot = state.slots[slot] else { return RV.slotIDInvalid }
        return copyOut(mechanisms(slot.profile), types, count)
    }
}

@_cdecl("wsc_session_open")
func wscSessionOpen(_ slotID: UInt, _ session: UnsafeMutablePointer<UInt>) -> UInt {
    module.initialized { state in
        guard let slot = state.slots[slotID] else { return RV.slotIDInvalid }
        let existing = state.tokens[slotID]
        let token = existing ?? Token(slot: slot)
        var rv = ensureCard(token)
        if rv == RV.ok, token.certificates == nil { rv = loadCertificates(token, &state) }
        guard rv == RV.ok else {
            if existing == nil { token.close() }
            return rv
        }
        state.tokens[slotID] = token
        let handle = state.nextSession
        state.nextSession += 1
        state.sessions[handle] = Session(slotID: slotID)
        session.pointee = handle
        return RV.ok
    }
}

@_cdecl("wsc_session_close")
func wscSessionClose(_ session: UInt) -> UInt {
    module.initialized { state in
        guard let removed = state.sessions.removeValue(forKey: session) else { return RV.sessionHandleInvalid }
        // The last session ends the token's connection, which also ends its login (PKCS#11 §5.6).
        if !state.sessions.values.contains(where: { $0.slotID == removed.slotID }) { closeToken(&state, removed.slotID) }
        return RV.ok
    }
}

@_cdecl("wsc_session_close_all")
func wscSessionCloseAll(_ slot: UInt) -> UInt {
    module.initialized { state in
        guard state.slots[slot] != nil || state.tokens[slot] != nil else { return RV.slotIDInvalid }
        state.sessions = state.sessions.filter { $0.value.slotID != slot }
        closeToken(&state, slot)
        return RV.ok
    }
}

@_cdecl("wsc_session_info")
func wscSessionInfo(_ session: UInt, _ slot: UnsafeMutablePointer<UInt>, _ loggedIn: UnsafeMutablePointer<Int32>) -> UInt {
    module.initialized { state in
        guard let value = state.sessions[session] else { return RV.sessionHandleInvalid }
        slot.pointee = value.slotID
        loggedIn.pointee = state.tokens[value.slotID]?.loggedIn == true ? 1 : 0
        return RV.ok
    }
}

@_cdecl("wsc_login")
func wscLogin(_ session: UInt, _ userType: UInt, _ pin: UnsafePointer<UInt8>, _ length: UInt) -> UInt {
    module.initialized { state in
        guard let (value, token) = lookup(state, session) else { return lookupFailure(state, session) }
        guard userType == userUserType else { return RV.userTypeInvalid }
        guard !token.loggedIn else { return RV.userAlreadyLoggedIn }
        let rv = ensureCard(token)
        guard rv == RV.ok, let card = token.card else { return rv }
        // The PIN lives only in this stack frame and the card call; it is never stored.
        let pin = String(decoding: UnsafeBufferPointer(start: pin, count: Int(length)), as: UTF8.self)
        do {
            try blocking { try await card.verifyPIN(pin) }
            token.loggedIn = true
            return RV.ok
        } catch {
            return status(error, slot: value.slotID, &state)
        }
    }
}

@_cdecl("wsc_logout")
func wscLogout(_ session: UInt) -> UInt {
    module.initialized { state in
        guard let (value, token) = lookup(state, session) else { return lookupFailure(state, session) }
        guard token.loggedIn else { return RV.userNotLoggedIn }
        // PC/SC cannot un-verify a PIN; dropping the connection resets the card's security state.
        token.close()
        token.loggedIn = false
        for (handle, other) in state.sessions where other.slotID == value.slotID {
            state.sessions[handle]?.signOperation = nil
        }
        return RV.ok
    }
}

@_cdecl("wsc_attribute")
func wscAttribute(
    _ session: UInt, _ handle: UInt, _ type: UInt, _ out: UnsafeMutableRawPointer?, _ length: UnsafeMutablePointer<UInt>
) -> UInt {
    module.initialized { state in
        guard let (_, token) = lookup(state, session) else { return lookupFailure(state, session) }
        guard resolve(token, handle) != nil else { return RV.objectHandleInvalid }
        guard let value = attribute(token, handle, type) else {
            length.pointee = UInt.max
            return RV.attributeTypeInvalid
        }
        let capacity = length.pointee
        length.pointee = UInt(value.count)
        guard let out else { return RV.ok }
        guard capacity >= UInt(value.count) else { return RV.bufferTooSmall }
        value.copyBytes(to: out.assumingMemoryBound(to: UInt8.self), count: value.count)
        return RV.ok
    }
}

@_cdecl("wsc_find_init")
func wscFindInit(_ session: UInt) -> UInt {
    module.initialized { state in
        guard state.sessions[session] != nil else { return RV.sessionHandleInvalid }
        guard state.sessions[session]?.filters == nil else { return RV.operationActive }
        state.sessions[session]?.filters = []
        state.sessions[session]?.matches = nil
        state.sessions[session]?.cursor = 0
        return RV.ok
    }
}

@_cdecl("wsc_find_filter")
func wscFindFilter(_ session: UInt, _ type: UInt, _ value: UnsafeRawPointer?, _ length: UInt) -> UInt {
    module.initialized { state in
        guard state.sessions[session]?.filters != nil else { return RV.operationNotInitialized }
        let data = value.map { Data(bytes: $0, count: Int(length)) } ?? Data()
        state.sessions[session]?.filters?.append((type, data))
        return RV.ok
    }
}

@_cdecl("wsc_find_next")
func wscFindNext(_ session: UInt, _ maximum: UInt, _ objects: UnsafeMutablePointer<UInt>, _ count: UnsafeMutablePointer<UInt>) -> UInt {
    module.initialized { state in
        guard let (value, token) = lookup(state, session) else { return lookupFailure(state, session) }
        guard let filters = value.filters else { return RV.operationNotInitialized }
        let matches =
            value.matches
            ?? allHandles(token).filter { handle in
                filters.allSatisfy { attribute(token, handle, $0.type) == $0.value }
            }
        let taken = Array(matches.dropFirst(value.cursor).prefix(Int(maximum)))
        for (index, handle) in taken.enumerated() { objects[index] = handle }
        count.pointee = UInt(taken.count)
        state.sessions[session]?.matches = matches
        state.sessions[session]?.cursor = value.cursor + taken.count
        return RV.ok
    }
}

@_cdecl("wsc_find_final")
func wscFindFinal(_ session: UInt) -> UInt {
    module.initialized { state in
        guard state.sessions[session] != nil else { return RV.sessionHandleInvalid }
        guard state.sessions[session]?.filters != nil else { return RV.operationNotInitialized }
        state.sessions[session]?.filters = nil
        state.sessions[session]?.matches = nil
        return RV.ok
    }
}

@_cdecl("wsc_sign_init")
func wscSignInit(_ session: UInt, _ mechanism: UInt, _ key: UInt) -> UInt {
    module.initialized { state in
        guard let (value, token) = lookup(state, session) else { return lookupFailure(state, session) }
        guard value.signOperation == nil else { return RV.operationActive }
        guard mechanism == CKM.sha256RSAPKCS || mechanism == CKM.ecdsa else { return RV.mechanismInvalid }
        guard key == privateKeyHandle, case .privateKey? = resolve(token, key), let certificate = token.certificates?.first
        else { return RV.keyHandleInvalid }
        guard token.loggedIn else { return RV.userNotLoggedIn }
        guard let algorithm = certificate.algorithm(in: token.slot.profile) else { return RV.keyTypeInconsistent }

        let isRSA = algorithm == .rsaPkcsSha256
        guard isRSA == (mechanism == CKM.sha256RSAPKCS) else { return RV.keyTypeInconsistent }
        state.sessions[session]?.signOperation = SignOperation(
            algorithm: algorithm,
            hashesMessage: isRSA,
            digestLength: algorithm == .ecdsaP384Sha384 ? 48 : 32,
            ecComponentLength: certificate.ecComponentLength,
            signatureLength: certificate.signatureLength
        )
        return RV.ok
    }
}

@_cdecl("wsc_sign")
func wscSign(
    _ session: UInt, _ data: UnsafePointer<UInt8>, _ dataLength: UInt, _ signature: UnsafeMutablePointer<UInt8>?,
    _ signatureLength: UnsafeMutablePointer<UInt>
) -> UInt {
    module.initialized { state in
        guard let (value, token) = lookup(state, session) else { return lookupFailure(state, session) }
        guard let operation = value.signOperation else { return RV.operationNotInitialized }
        guard token.loggedIn else {
            state.sessions[session]?.signOperation = nil
            return RV.userNotLoggedIn
        }
        let expected = UInt(operation.signatureLength)
        guard let signature else {
            signatureLength.pointee = expected
            return RV.ok
        }
        guard signatureLength.pointee >= expected else {
            signatureLength.pointee = expected
            return RV.bufferTooSmall
        }
        // Past the size checks the operation ends whatever the outcome (PKCS#11 §5.2).
        state.sessions[session]?.signOperation = nil

        let message = Data(bytes: data, count: Int(dataLength))
        let digest: Data
        if operation.hashesMessage {
            digest = Data(SHA256.hash(data: message))
        } else {
            guard message.count == operation.digestLength else { return RV.dataLenRange }
            digest = message
        }
        let rv = ensureCard(token)
        guard rv == RV.ok, let card = token.card else { return rv }
        do {
            let algorithm = operation.algorithm
            var result = try blocking { try await card.sign(digest, algorithm: algorithm) }
            if let size = operation.ecComponentLength {
                guard let raw = ECDSASignature.raw(result, size: size) else { return RV.deviceError }
                result = raw
            }
            guard result.count == operation.signatureLength else { return RV.deviceError }
            result.copyBytes(to: signature, count: result.count)
            signatureLength.pointee = UInt(result.count)
            return RV.ok
        } catch {
            return status(error, slot: value.slotID, &state)
        }
    }
}
