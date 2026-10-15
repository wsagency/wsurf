import CardCore
import CryptoKit
import CryptoTokenKit
import Foundation

func tkError(_ error: Error) -> Error {
    guard let error = error as? CardError else { return TKError(.communicationError) }
    switch error {
    case .pinWrong, .pinBlocked: return TKError(.authenticationFailed)
    case .unexpectedStatus(0x6982), .unexpectedStatus(0x6985): return TKError(.authenticationNeeded)
    case .cardRemoved: return TKError(.tokenNotFound)
    case .unsupportedCard: return TKError(.tokenNotFound)
    case .invalidPIN: return TKError(.badParameter)
    default: return TKError(.communicationError)
    }
}

final class SmartCardToken: TKSmartCardToken, TKTokenDelegate {
    static let leafKeyID = "key-0"

    let profile: CardProfile
    let certificates: [Certificate]

    init(smartCard: TKSmartCard, aid: Data?, driver: TKSmartCardTokenDriver) throws {
        let transport = TKSmartCardTransport(card: smartCard)
        defer { transport.release() }
        guard let profile = CardDetector.profile(for: transport.atr, in: CardSession.library) else {
            throw TKError(.tokenNotFound)
        }
        let session = CardSession(transport: transport, profile: profile)
        let parsed: [Certificate?]
        do {
            parsed = try blocking { try await session.readCertificates() }.map { Certificate(der: $0) }
        } catch {
            throw tkError(error)
        }
        let certificates = parsed.compactMap { $0 }
        guard certificates.count == parsed.count else { throw TKError(.corruptedData) }
        // Certificate[0] is the end-entity certificate (CardCore table convention); it is the only one with a key.
        guard let leaf = certificates.first else { throw TKError(.corruptedData) }

        self.profile = profile
        self.certificates = certificates
        let fingerprint = SHA256.hash(data: leaf.der).prefix(8).map { String(format: "%02x", $0) }.joined()
        super.init(smartCard: smartCard, aid: aid, instanceID: "\(profile.id):\(fingerprint)", tokenDriver: driver)
        delegate = self

        var items: [TKTokenKeychainItem] = []
        for (index, certificate) in certificates.enumerated() {
            guard let secCertificate = SecCertificateCreateWithData(nil, certificate.der as CFData),
                  let item = TKTokenKeychainCertificate(certificate: secCertificate, objectID: "cert-\(index)")
            else { throw TKError(.corruptedData) }
            items.append(item)
            if index == 0, leaf.algorithm(in: profile) != nil,
               let key = TKTokenKeychainKey(certificate: secCertificate, objectID: Self.leafKeyID)
            {
                key.canSign = true
                key.constraints = [NSNumber(value: TKTokenOperation.signData.rawValue): "PIN"]
                items.append(key)
            }
        }
        keychainContents?.fill(with: items)
    }

    func createSession(_ token: TKToken) throws -> TKTokenSession {
        SmartCardTokenSession(smartCardToken: self)
    }
}
