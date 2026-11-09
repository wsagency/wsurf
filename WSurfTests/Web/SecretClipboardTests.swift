// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// `SecretClipboard`, the one way a secret reaches the clipboard: this Mac only, concealed, and gone after a minute, when its vault
/// locks and at quit, each time only if the copy is still the pasteboard's content. The pasteboards are private ones and the clock
/// is the test's; the general pasteboard is never touched.
@MainActor
struct SecretClipboardTests {
    /// Forwards to a private pasteboard and records what was asked of it.
    final class RecordingPasteboard: SecretPasteboard {
        let inner: NSPasteboard
        private(set) var preparedOptions: [NSPasteboard.ContentsOptions] = []
        private(set) var calls: [String] = []

        init() {
            inner = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.secret.\(UUID().uuidString)"))
        }

        var changeCount: Int {
            inner.changeCount
        }

        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            preparedOptions.append(options)
            calls.append("prepare")
            return inner.prepareForNewContents(with: options)
        }

        func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
            calls.append("setString")
            return inner.setString(string, forType: dataType)
        }

        func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
            calls.append("setData")
            return inner.setData(data, forType: dataType)
        }

        func clearContents() -> Int {
            calls.append("clear")
            return inner.clearContents()
        }

        var text: String? {
            inner.string(forType: .string)
        }
    }

    private struct Rig {
        let pasteboard = RecordingPasteboard()
        let clock = TestClock()
        let clipboard: SecretClipboard

        init() {
            clipboard = SecretClipboard(pasteboard: pasteboard, clock: clock)
        }

        func release() {
            pasteboard.inner.releaseGlobally()
        }
    }

    private static let vault = SecretClipboard.Source.vault(profile: UUID(), vault: UUID())
    private static let otherVault = SecretClipboard.Source.vault(profile: UUID(), vault: UUID())

    @Test func aCopyIsForThisMacOnlyAndConcealed() async {
        let rig = Rig()
        defer { rig.release() }
        rig.clipboard.copy("dummy-secret", from: Self.vault)
        #expect(rig.pasteboard.preparedOptions == [.currentHostOnly])
        // Nothing declares types after the option was set: that would clear the contents and the option with them.
        #expect(rig.pasteboard.calls == ["prepare", "setString", "setData"])
        #expect(rig.pasteboard.text == "dummy-secret")
        #expect(rig.pasteboard.inner.types?.contains(.concealed) == true)
    }

    @Test func itClearsAfterAMinute() async {
        let rig = Rig()
        defer { rig.release() }
        rig.clipboard.copy("dummy-secret", from: Self.vault)
        #expect(await waitUntil { rig.clock.pendingCount == 1 })
        rig.clock.advance(by: SecretClipboard.lifetime - .seconds(1))
        #expect(rig.pasteboard.text == "dummy-secret")
        rig.clock.advance(by: .seconds(1))
        await rig.clipboard.clearing?.value
        #expect(rig.pasteboard.text == nil)
    }

    @Test func itLeavesWhateverWasCopiedLaterAlone() async {
        let rig = Rig()
        defer { rig.release() }
        rig.clipboard.copy("dummy-secret", from: Self.vault)
        #expect(await waitUntil { rig.clock.pendingCount == 1 })
        rig.pasteboard.inner.clearContents()
        rig.pasteboard.inner.setString("copied later", forType: .string)
        rig.clock.advance(by: SecretClipboard.lifetime)
        await rig.clipboard.clearing?.value
        #expect(rig.pasteboard.text == "copied later")
    }

    @Test func aNewerSecretReplacesTheOlderAndItsClearing() async {
        let rig = Rig()
        defer { rig.release() }
        rig.clipboard.copy("first-secret", from: Self.vault)
        #expect(await waitUntil { rig.clock.pendingCount == 1 })
        rig.clock.advance(by: .seconds(40))
        rig.clipboard.copy("second-secret", from: Self.vault)
        #expect(await waitUntil { rig.clock.pendingCount == 1 })
        // The first copy's minute ends here, the second's does not.
        rig.clock.advance(by: .seconds(30))
        #expect(rig.pasteboard.text == "second-secret")
        rig.clock.advance(by: .seconds(30))
        await rig.clipboard.clearing?.value
        #expect(rig.pasteboard.text == nil)
    }

    @Test func itClearsWhenItsOwnVaultLocksAndNotAnotherVaults() {
        let rig = Rig()
        defer { rig.release() }
        rig.clipboard.copy("dummy-secret", from: Self.vault)
        SecretClipboard.vaultLocked(profile: UUID(), vault: UUID())
        guard case let .vault(profile, vault) = Self.otherVault else { return }
        SecretClipboard.vaultLocked(profile: profile, vault: vault)
        #expect(rig.pasteboard.text == "dummy-secret")
        guard case let .vault(ownProfile, ownVault) = Self.vault else { return }
        SecretClipboard.vaultLocked(profile: ownProfile, vault: ownVault)
        #expect(rig.pasteboard.text == nil)
    }

    @Test func aLockDoesNotClearSomethingCopiedSince() {
        let rig = Rig()
        defer { rig.release() }
        rig.clipboard.copy("dummy-secret", from: Self.vault)
        rig.pasteboard.inner.clearContents()
        rig.pasteboard.inner.setString("copied later", forType: .string)
        guard case let .vault(profile, vault) = Self.vault else { return }
        SecretClipboard.vaultLocked(profile: profile, vault: vault)
        #expect(rig.pasteboard.text == "copied later")
    }

    @Test func inputHistoryLocksClearOnlyThatProfilesCopy() {
        let rig = Rig()
        defer { rig.release() }
        let profile = UUID()
        rig.clipboard.copy("dummy-history-value", from: .inputHistory(profile: profile))
        SecretClipboard.inputHistoryLocked(profile: UUID())
        #expect(rig.pasteboard.text == "dummy-history-value")
        SecretClipboard.vaultLocked(profile: profile, vault: UUID())
        #expect(rig.pasteboard.text == "dummy-history-value")
        SecretClipboard.inputHistoryLocked(profile: profile)
        #expect(rig.pasteboard.text == nil)
    }

    @Test func quitClearsEveryCopyThatIsStillOurs() {
        let mine = Rig()
        let stale = Rig()
        defer {
            mine.release()
            stale.release()
        }
        mine.clipboard.copy("dummy-token", from: .mcp)
        stale.clipboard.copy("dummy-secret", from: Self.vault)
        stale.pasteboard.inner.clearContents()
        stale.pasteboard.inner.setString("copied later", forType: .string)
        SecretClipboard.clearAtQuit()
        #expect(mine.pasteboard.text == nil)
        #expect(stale.pasteboard.text == "copied later")
    }

    @Test func aMcpCopyIsNotClearedByAnyLock() {
        let rig = Rig()
        defer { rig.release() }
        rig.clipboard.copy("dummy-token", from: .mcp)
        SecretClipboard.vaultLocked(profile: UUID(), vault: UUID())
        SecretClipboard.inputHistoryLocked(profile: UUID())
        #expect(rig.pasteboard.text == "dummy-token")
    }
}
