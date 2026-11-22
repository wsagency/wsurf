// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Testing

@testable import WSurf
@testable import WSurfVault

extension WebsiteAuthenticatorCeremonyTests {
    @Test(.boundedWebViews) func aRestoredSpaceUsesOnlyItsChosenVaultForPasskeys() async throws {
        try await withFixture { fixture in
            try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { owner, _, vaults in
                let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let profiles = ProfileStore(file: directory.appending(path: "profiles.json"))
                for profile in [owner, fixture.profile] {
                    _ = try #require(profiles.adopt(id: profile.id, name: profile.name, symbol: profile.symbol, color: profile.color))
                }
                let spaceID = UUID()
                let spaceFile = directory.appending(path: "Spaces.json")
                let space: [String: Any] = [
                    "id": spaceID.uuidString, "name": "Work", "symbol": "briefcase", "color": "blue",
                    "vault": ["profileID": owner.id.uuidString, "vaultID": vaults[1].vaultID.uuidString],
                ]
                let saved = [space]
                try JSONSerialization.data(withJSONObject: saved).write(to: spaceFile, options: .atomic)
                let spaces = SpaceStore(profile: fixture.profile, file: spaceFile)
                let browser = BrowserModel(context: fixture.page.context)
                let coordinator = AppCoordinator(browser: browser, profiles: .selection(profile: fixture.profile, catalog: profiles))
                defer { withExtendedLifetime(coordinator) {} }
                browser.adoptSpaces(from: spaces)
                browser.bindCallbacks(to: fixture.tab)
                fixture.tab.spaceID = spaceID

                let user = User()
                let context = try await fixture.context(.create)
                for denied in [fixture.manager, vaults[0].manager] {
                    await #expect(throws: WebsiteAuthenticatorError.self) {
                        try await WebsiteAuthenticator.perform(creation(), context: context, manager: denied, in: fixture.window, interaction: user)
                    }
                }
                #expect(user.prompts.isEmpty)
                let manager = vaults[1].manager
                let registration = try await WebsiteAuthenticator.perform(creation(), context: context, manager: manager, in: fixture.window, interaction: user)
                user.respond = { .approved(choice: $0.choices.first?.id) }
                let assertion = try await WebsiteAuthenticator.perform(
                    assertion(allow: [registration.result.credentialID]), context: fixture.context(.get), manager: manager, in: fixture.window, interaction: user
                )
                #expect(assertion.result.signature != nil)
                #expect(try await fixture.manager.snapshot().accounts.isEmpty)
                #expect(try await vaults[0].manager.snapshot().accounts.isEmpty)
            }
        }
    }
}
