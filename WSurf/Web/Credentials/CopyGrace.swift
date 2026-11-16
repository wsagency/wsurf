// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The 30 seconds after one Touch ID or password confirmation in which the Passwords popover and window copy a password or a code from
/// the same vault without asking again, because a login needs two copies in a row.
///
/// - Memory only. It begins when a copy's own confirmation succeeds and is fixed: a copy inside it does not extend it, so 30 s after
///   the confirmation the next password or code asks again.
/// - It is bound to the vault's authorization epoch and also ended by name: every lock of the vault (Lock Now, auto-lock, a profile
///   switch, and the whole-session events sleep, display sleep, screen lock, fast user switch and quit, which lock each vault) ends it
///   in `CredentialManager.lock`, and a new unlock is a new epoch the old window does not match. Nothing is stored: a quit ends it.
/// - `CredentialSettingsModel.verifyOwnerForCopy` is the only reader, and only a model given a `CopyGrace` (the popover's and the
///   Passwords window's) has one. Autofill, MCP, the assistant, Show, export, health, cards and the editor never read or begin it.
/// - A reused `LAContext` was not used: the verifier is a seam that returns nothing, the system's own reuse window cannot be ended by
///   our lock events, and a window of our own can.
@MainActor
final class CopyGrace {
    static let duration: Duration = .seconds(30)
    /// The one window of the app's own Passwords UI: the popover's and the window's models share it.
    static let shared = CopyGrace()

    private let now: @MainActor () -> ContinuousClock.Instant
    private var windows: [UUID: (epoch: UInt64, until: ContinuousClock.Instant)] = [:]
    private static let instances = NSHashTable<CopyGrace>.weakObjects()

    init(now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
        Self.instances.add(self)
    }

    /// The vault's authorization epoch while its window runs and the vault is still under that unlock; nil otherwise.
    func openEpoch(for manager: CredentialManager) -> UInt64? {
        guard let window = windows[manager.vaultID] else { return nil }
        guard now() < window.until, manager.authorizationEpoch == window.epoch else {
            windows[manager.vaultID] = nil
            return nil
        }
        return window.epoch
    }

    /// Whether a window runs for `vault`, whether or not it has expired by the clock.
    func holds(_ vault: UUID) -> Bool {
        windows[vault] != nil
    }

    /// Starts the window for `manager` under `epoch`, the unlock its confirmation was given under.
    func begin(for manager: CredentialManager, epoch: UInt64) {
        windows[manager.vaultID] = (epoch, now().advanced(by: Self.duration))
    }

    // MARK: Hooks

    /// One vault locked (`CredentialManager.lock(reason:)`): its window ends in every instance. Every whole-session event (Lock Now,
    /// sleep, display sleep, screen lock, fast user switch, quit) locks each vault through it, so none needs a hook of its own.
    static func vaultLocked(_ vault: UUID) {
        for instance in instances.allObjects {
            instance.windows[vault] = nil
        }
    }
}
