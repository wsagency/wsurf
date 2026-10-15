import CardCore
import CryptoKit
import CryptoTokenKit
import Foundation

final class SmartCardPINOperation: TKTokenSmartCardPINAuthOperation {
    var verify: ((String) throws -> Void)?

    override func finish() throws {
        guard let pin, let verify else { throw TKError(.authenticationFailed) }
        try verify(pin)
    }
}

final class SmartCardTokenSession: TKSmartCardTokenSession, TKTokenSessionDelegate {
    private let smartCardToken: SmartCardToken
    private var transport: TKSmartCardTransport?
    private var card: CardSession?
    private var authenticated = false

    init(smartCardToken: SmartCardToken) {
        self.smartCardToken = smartCardToken
        super.init(token: smartCardToken)
        delegate = self
    }

    private enum Input { case digest, message }

    private static let algorithms: [(SecKeyAlgorithm, CardProfile.Algorithm, Input)] = [
        (.rsaSignatureDigestPKCS1v15SHA256, .rsaPkcsSha256, .digest),
        (.rsaSignatureMessagePKCS1v15SHA256, .rsaPkcsSha256, .message),
        (.ecdsaSignatureDigestX962SHA256, .ecdsaP256Sha256, .digest),
        (.ecdsaSignatureMessageX962SHA256, .ecdsaP256Sha256, .message),
        (.ecdsaSignatureDigestX962SHA384, .ecdsaP384Sha384, .digest),
        (.ecdsaSignatureMessageX962SHA384, .ecdsaP384Sha384, .message),
    ]

    private func classify(_ algorithm: TKTokenKeyAlgorithm) -> (CardProfile.Algorithm, Input)? {
        guard let match = Self.algorithms.first(where: { algorithm.isAlgorithm($0.0) }),
              match.1 == smartCardToken.certificates[0].algorithm(in: smartCardToken.profile)
        else { return nil }
        return (match.1, match.2)
    }

    /// One CardSession for the token session so the applet selected for the PIN is the one that signs.
    private func cardSession() throws -> CardSession {
        let smartCard = try getSmartCard()
        let transport = transport ?? TKSmartCardTransport(card: smartCard)
        transport.bind(smartCard)
        self.transport = transport
        let card = card ?? CardSession(transport: transport, profile: smartCardToken.profile)
        self.card = card
        return card
    }

    func tokenSession(_ session: TKTokenSession, beginAuthFor operation: TKTokenOperation, constraint: Any) throws -> TKTokenAuthOperation {
        guard operation == .signData, constraint as? String == "PIN" else { throw TKError(.notImplemented) }
        if authenticated { return TKTokenAuthOperation() }
        let pinOperation = SmartCardPINOperation()
        if let min = smartCardToken.profile.pinMinLength { pinOperation.pinFormat.minPINLength = min }
        if let max = smartCardToken.profile.pinMaxLength { pinOperation.pinFormat.maxPINLength = max }
        pinOperation.verify = { [weak self] pin in
            guard let self else { throw TKError(.authenticationFailed) }
            let card = try cardSession()
            defer { transport?.release() }
            do {
                try blocking { try await card.verifyPIN(pin) }
                authenticated = true
            } catch {
                throw tkError(error)
            }
        }
        return pinOperation
    }

    func tokenSession(_ session: TKTokenSession, supports operation: TKTokenOperation, keyObjectID: Any, algorithm: TKTokenKeyAlgorithm) -> Bool {
        operation == .signData && keyObjectID as? String == SmartCardToken.leafKeyID && classify(algorithm) != nil
    }

    func tokenSession(_ session: TKTokenSession, sign dataToSign: Data, keyObjectID: Any, algorithm: TKTokenKeyAlgorithm) throws -> Data {
        guard keyObjectID as? String == SmartCardToken.leafKeyID else { throw TKError(.objectNotFound) }
        guard let (cardAlgorithm, input) = classify(algorithm) else { throw TKError(.notImplemented) }

        let digest: Data
        switch (input, cardAlgorithm) {
        case (.digest, _): digest = dataToSign
        case (.message, .ecdsaP384Sha384): digest = Data(SHA384.hash(data: dataToSign))
        case (.message, _): digest = Data(SHA256.hash(data: dataToSign))
        }
        // CardSession traps on a wrong digest size, so reject it here.
        guard digest.count == (cardAlgorithm == .ecdsaP384Sha384 ? 48 : 32) else { throw TKError(.badParameter) }

        let card = try cardSession()
        defer { transport?.release() }
        do {
            let signature = try blocking { try await card.sign(digest, algorithm: cardAlgorithm) }
            guard let size = smartCardToken.certificates[0].ecComponentLength else { return signature }
            // SecKey ECDSA algorithms return the X9.62 DER form; the card's output format is normalised first.
            guard let raw = ECDSASignature.raw(signature, size: size) else { throw TKError(.corruptedData) }
            return ECDSASignature.der(raw)
        } catch {
            if case CardError.unexpectedStatus(0x6982) = error { authenticated = false }
            throw tkError(error)
        }
    }
}
