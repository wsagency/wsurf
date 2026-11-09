// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

/// What `SecretClipboard` needs of a pasteboard. `NSPasteboard` is one; a test wraps one to record the calls.
protocol SecretPasteboard: AnyObject {
    var changeCount: Int { get }
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func clearContents() -> Int
}

extension NSPasteboard: SecretPasteboard {}

/// The one way a secret reaches the clipboard: a password, a verification code, a hidden value, an Input History value or the MCP
/// pairing token.
///
/// - The copy stays off other devices: `prepareForNewContents(with: .currentHostOnly)`, then only `setString` and `setData`. Never
///   `declareTypes` after it: that clears the contents, and the option lasts only until the next `prepareForNewContents` or
///   `clearContents`.
/// - The copy carries the concealed marker, which clipboard managers skip.
/// - It leaves the clipboard after `lifetime`, when the vault it came from locks (`vaultLocked`, `inputHistoryLocked`) and at quit
///   (`clearAtQuit`). Each time it clears only if the pasteboard's change count is still the copy's: something copied since is not ours.
/// - The clearing task holds the pasteboard and the clock, not a model, so closing a window does not cancel it.
///
/// One instance holds one copy: a newer copy replaces the older, whose clearing is cancelled. Production uses `shared` on the general
/// pasteboard; a test makes its own instance on a private pasteboard with its own clock. The static hooks reach every live instance.
@MainActor
final class SecretClipboard {
    static let lifetime: Duration = .seconds(60)
    static let shared = SecretClipboard()

    /// Where a copy came from, so a lock clears only its own copies.
    enum Source: Hashable, Sendable {
        case vault(profile: UUID, vault: UUID)
        case inputHistory(profile: UUID)
        /// The MCP pairing configuration: cleared by time and at quit, not by any vault's lock.
        case mcp
    }

    let pasteboard: any SecretPasteboard
    private let clock: any Clock<Duration>
    private var held: (source: Source, changeCount: Int)?
    /// The last copy's clearing, so a test can wait for it after moving the clock.
    private(set) var clearing: Task<Void, Never>?

    private static let instances = NSHashTable<SecretClipboard>.weakObjects()

    init(pasteboard: any SecretPasteboard = NSPasteboard.general, clock: any Clock<Duration> = ContinuousClock()) {
        self.pasteboard = pasteboard
        self.clock = clock
        Self.instances.add(self)
    }

    /// The clipboard for a pasteboard a model was given: the shared one for the general pasteboard, a private one (a test's) otherwise.
    static func clipboard(for pasteboard: NSPasteboard, clock: any Clock<Duration> = ContinuousClock()) -> SecretClipboard {
        pasteboard === NSPasteboard.general ? shared : SecretClipboard(pasteboard: pasteboard, clock: clock)
    }

    /// Puts `text` on the clipboard, concealed and for this Mac only, and schedules its clearing.
    func copy(_ text: String, from source: Source) {
        clearing?.cancel()
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        _ = pasteboard.setString(text, forType: .string)
        _ = pasteboard.setData(Data(), forType: .concealed)
        let changeCount = pasteboard.changeCount
        held = (source, changeCount)
        clearing = Task { [pasteboard, clock] in
            do {
                try await clock.sleep(for: Self.lifetime)
            } catch {
                return
            }
            if pasteboard.changeCount == changeCount {
                _ = pasteboard.clearContents()
            }
        }
    }

    /// Clears the held copy now when it came from `source` and is still the pasteboard's content.
    func clear(source: Source) {
        guard held?.source == source else { return }
        clearHeld()
    }

    /// Clears the held copy now, whatever its source, when it is still the pasteboard's content.
    func clearHeld() {
        guard let held else { return }
        clearing?.cancel()
        self.held = nil
        if pasteboard.changeCount == held.changeCount {
            _ = pasteboard.clearContents()
        }
    }

    // MARK: Hooks

    /// A vault locked: its copies leave the clipboard (`CredentialManager.lock(reason:)`).
    static func vaultLocked(profile: UUID, vault: UUID) {
        for instance in instances.allObjects {
            instance.clear(source: .vault(profile: profile, vault: vault))
        }
    }

    /// A profile's Input History locked (`InputHistory.lock(profileID:)`).
    static func inputHistoryLocked(profile: UUID) {
        for instance in instances.allObjects {
            instance.clear(source: .inputHistory(profile: profile))
        }
    }

    /// The app is quitting (`AppDelegate.applicationWillTerminate`; a test calls this directly).
    static func clearAtQuit() {
        for instance in instances.allObjects {
            instance.clearHeld()
        }
    }
}
