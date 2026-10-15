import CardCore
import CryptoTokenKit
import Foundation

/// APDU transport over the `TKSmartCard` the system hands to a token callback (C17: no PC/SC in the extension).
/// The extension declares no `com.apple.ctk.aid`, so the exclusive card session is ours to begin and end.
final class TKSmartCardTransport: APDUTransport, @unchecked Sendable {
    let atr: Data
    private let lock = NSLock()
    private var card: TKSmartCard
    private var active = false

    init(card: TKSmartCard) {
        self.card = card
        atr = card.slot.atr?.bytes ?? Data()
    }

    /// A `TKSmartCard` is only valid inside one delegate callback; each callback rebinds the current one.
    func bind(_ card: TKSmartCard) {
        lock.withLock {
            self.card = card
            active = false
        }
    }

    func transmit(_ apdu: Data) async throws -> Data {
        let card = try await begin()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                card.transmit(apdu) { response, error in
                    if let response {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: error ?? CardError.transport("no response"))
                    }
                }
            }
        } catch {
            throw card.isValid ? CardError.transport(error.localizedDescription) : CardError.cardRemoved
        }
    }

    func close() async { release() }

    /// Ends the exclusive session so other readers' clients can use the card between operations.
    func release() {
        let card = lock.withLock { () -> TKSmartCard? in
            defer { active = false }
            return active ? self.card : nil
        }
        card?.endSession()
    }

    private func begin() async throws -> TKSmartCard {
        let (card, needsBegin) = lock.withLock { (self.card, !active) }
        if needsBegin {
            let began: Bool = try await withCheckedThrowingContinuation { continuation in
                card.beginSession { success, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: success) }
                }
            }
            guard began else { throw card.isValid ? CardError.transport("session refused") : CardError.cardRemoved }
            lock.withLock { active = true }
        }
        return card
    }
}
