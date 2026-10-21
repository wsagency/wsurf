// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import Testing

@testable import WSurf

// The Credentials page appears before its model has read the vault. A vault whose lease is still valid is not locked, so the page must
// not say "locked" in that moment, and nothing of the vault may be shown before it really is unlocked.

@MainActor
struct CredentialSettingsOpeningTests {
    typealias Presentation = CredentialSettingsModel.Presentation

    /// Every state the page could have drawn, in order, with whether the vault was unlocked at that moment. Recorded after each change
    /// has landed (a render sees the settled state, never the middle of a turn).
    @MainActor
    private final class Frames {
        private(set) var drawn: [(presentation: Presentation, unlocked: Bool)] = []
        private let model: CredentialSettingsModel

        init(_ model: CredentialSettingsModel) {
            self.model = model
            record()
        }

        var presentations: [Presentation] {
            drawn.map(\.presentation)
        }

        /// Content while the vault was locked, ever.
        var showedContentWhileLocked: Bool {
            drawn.contains { $0.presentation == .content && !$0.unlocked }
        }

        private func record() {
            drawn.append((model.presentation, model.isUnlocked))
            withObservationTracking {
                _ = model.presentation
                _ = model.isUnlocked
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.record() }
            }
        }
    }

    @Test func aValidLeaseIsNeverShownAsLockedWhileThePageOpens() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, _ in
            let model = CredentialSettingsModel(profile: profile)
            let frames = Frames(model)
            #expect(model.presentation == .opening)
            #expect(!model.isLoaded, "opening shows nothing of the vault")

            await model.load()

            #expect(model.presentation == .content)
            #expect(model.isUnlocked)
            #expect(await waitUntil { frames.presentations.last == .content })
            #expect(frames.presentations.first == .opening)
            #expect(!frames.presentations.contains(.locked))
            #expect(!frames.showedContentWhileLocked)
        }
    }

    @Test func aLockedVaultEndsOnLockedAndNeverShowsContent() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, _, vaults in
            let model = CredentialSettingsModel(profile: profile)
            let frames = Frames(model)
            #expect(model.presentation == .opening)

            await model.load()

            #expect(model.presentation == .locked)
            #expect(!model.isUnlocked)

            // Unlocked elsewhere: still no content until this page has read the vault under the new authorization.
            try await VaultManagerFixture.unlock(vaults[0])
            #expect(model.presentation == .locked)
            await model.load()
            #expect(model.presentation == .content)

            // A lock is a lock at once, not another "opening".
            model.lock()
            #expect(model.presentation == .locked)
            #expect(await waitUntil { frames.presentations.last == .locked })
            #expect(!frames.showedContentWhileLocked)
            #expect(!frames.presentations.dropFirst().contains(.opening))
        }
    }

    @Test func aPageThatComesBackAfterClosingIsNotLockedInBetween() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, _ in
            let model = CredentialSettingsModel(profile: profile)
            await model.load()
            let frames = Frames(model)
            #expect(frames.presentations == [.content])

            // The page disappears (the session is dropped) and appears again before its next load has read the vault.
            model.close()
            #expect(model.presentation == .opening)
            await model.load()

            #expect(model.presentation == .content)
            #expect(await waitUntil { frames.presentations.last == .content })
            #expect(!frames.presentations.contains(.locked))
            #expect(!frames.showedContentWhileLocked)
        }
    }

    @Test func aLoadThatWasCancelledHasNotSeenTheVaultSoThePageKeepsOpening() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, _, _ in
            let model = CredentialSettingsModel(profile: profile)
            let load = Task { await model.load() }
            load.cancel()
            await load.value
            #expect(model.presentation == .opening)

            await model.load()

            #expect(model.presentation == .locked)
        }
    }

    @Test func aPageThatNeverFinishesOpeningFallsBackToLockedNeverToContent() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, _ in
            let model = CredentialSettingsModel(profile: profile, openingDuration: .milliseconds(50))
            let frames = Frames(model)
            #expect(model.presentation == .opening)

            #expect(await waitUntil { model.presentation == .locked })

            #expect(!model.isLoaded)
            #expect(!frames.showedContentWhileLocked)
            #expect(!frames.presentations.contains(.content))
        }
    }

    @Test func aManagerGivenAtCreationIsReadAtOnce() async throws {
        try await VaultManagerFixture.with(vaults: [.locked, .unlocked]) { profile, _, vaults in
            let locked = CredentialSettingsModel(profile: profile, manager: vaults[0].manager)
            #expect(locked.presentation == .locked, "a locked manager has nothing to wait for")

            let unlocked = CredentialSettingsModel(profile: profile, manager: vaults[1].manager)
            #expect(unlocked.presentation == .opening, "a valid lease is not locked, and is not content before it is read")
            await unlocked.load()
            #expect(unlocked.presentation == .content)
        }
    }
}
