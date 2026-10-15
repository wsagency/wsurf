import CardCore
import CryptoTokenKit

final class SmartCardTokenDriver: TKSmartCardTokenDriver, TKSmartCardTokenDriverDelegate {
    override init() {
        super.init()
        delegate = self
    }

    func tokenDriver(_ driver: TKSmartCardTokenDriver, createTokenFor smartCard: TKSmartCard, aid AID: Data?) throws -> TKSmartCardToken {
        try SmartCardToken(smartCard: smartCard, aid: AID, driver: driver)
    }
}
