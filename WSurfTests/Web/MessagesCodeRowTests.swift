// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf
@testable import WSurfVault

/// The dropdown's "Code from Messages or Mail…" row: offered on a verification-code field and nowhere else, whatever the vault
/// holds, and never in a private window or a tab an agent controls. The lookup itself needs a key window and an active app to show
/// its panel, as every dropdown test notes; it records the row it built as an action of its request before that, which is what is
/// read here.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MessagesCodeRowTests {
    private static let shop = "https://shop.example"

    @Test func onlyACodeFieldOfAPasswordRequestInANormalWindowUnderNoAgentIsOffered() {
        for kind in AutofillSaveKind.allCases {
            for field in [CredentialAutofillField.password, .totp] {
                for isPrivate in [false, true] {
                    for controlled in [false, true] {
                        let offered = AutofillSuggestions.offersMessagesCode(
                            kind: kind, field: field, isPrivate: isPrivate, underAssistantControl: controlled
                        )
                        #expect(offered == (kind == .password && field == .totp && !isPrivate && !controlled), "\(kind) \(field) private \(isPrivate) controlled \(controlled)")
                    }
                }
            }
        }
    }

    @MainActor
    private final class Rig {
        let tab: BrowserTab
        let page: BrowserPage
        let window: NSWindow
        let main: BrowserFrame

        init(context: BrowserProfileContext) {
            tab = BrowserTab(opensBlank: false, context: context)
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration), context: context)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            AutofillSaveCoordinator.shared.install(in: page, session: tab.autofillSave)
            page.url = URL(string: MessagesCodeRowTests.shop + "/verify")
            page.hasOnlySecureContent = true
            main = BrowserFrame(
                id: "MAIN", documentID: "loader-main", url: URL(string: MessagesCodeRowTests.shop + "/verify")!, isMainFrame: true,
                securityOrigin: BrowserSecurityOrigin(protocol: "https", host: "shop.example", port: 0)
            )
        }

        func request(_ field: CredentialAutofillField) -> AutofillSuggestions.Request {
            AutofillSuggestions.Request(
                page: page, context: page.context, frame: main, token: UUID().uuidString, kind: .password,
                frameURL: URL(string: MessagesCodeRowTests.shop + "/verify")!, topURL: URL(string: MessagesCodeRowTests.shop + "/verify")!,
                world: PasswordAutofill.world, bridge: "__wsurfPasswords", documentID: UUID().uuidString, formID: "1", fieldID: "2",
                field: field, enteredUsername: nil, typeToSearch: false, isWebAuthnField: false
            )
        }

        /// The actions the dropdown's lookup recorded for `request`: what the rows of its panel would do.
        func actions(for request: AutofillSuggestions.Request) async -> [AutofillSuggestions.Request.Action] {
            _ = await AutofillSuggestions.shared.lookUp(request, origin: MessagesCodeRowTests.shop, presentation: UUID(), in: page)
            return Array(request.actions.values)
        }

        func close() async {
            window.contentView = nil
            window.close()
            await page.close()
        }
    }

    private func withRig(vaults: [VaultState], _ body: (Rig, [FixtureVault]) async throws -> Void) async throws {
        try await VaultManagerFixture.with(vaults: vaults) { profile, _, fixtures in
            let rig = Rig(context: BrowserProfileContext(profile: profile))
            do {
                try await body(rig, fixtures)
            } catch {
                await rig.close()
                throw error
            }
            await rig.close()
        }
    }

    private func account(totp: TOTPGenerator?) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: "ada", displayName: nil, origins: [Self.shop], loginURLs: [], password: "dummy-pw", passkeys: [],
            totp: totp, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private static let generator = TOTPGenerator(
        secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 3600, digits: 6, issuer: nil, userName: nil
    )

    @Test(arguments: [[], [VaultState.locked], [.unlocked], [.unlocked, .locked]])
    func aCodeFieldAlwaysGetsTheRowWhateverTheVaultsHold(vaults: [VaultState]) async throws {
        try await withRig(vaults: vaults) { rig, _ in
            let actions = await rig.actions(for: rig.request(.totp))
            #expect(actions.filter { $0 == .messagesCode }.count == 1, "\(vaults)")
        }
    }

    @Test func aVaultWithCodesOrWithoutAnyStillGetsTheRowAlongsideItsOwn() async throws {
        try await withRig(vaults: [.unlocked]) { rig, vaults in
            try await VaultManagerFixture.save([account(totp: nil)], in: vaults[0])
            #expect(await rig.actions(for: rig.request(.totp)).contains(.messagesCode), "a vault without a code")
            try await VaultManagerFixture.save([account(totp: Self.generator)], in: vaults[0])
            #expect(await rig.actions(for: rig.request(.totp)).contains(.messagesCode), "a vault with a code")
        }
    }

    @Test func aPasswordFieldIsNeverOffered() async throws {
        try await withRig(vaults: [.unlocked]) { rig, _ in
            #expect(!(await rig.actions(for: rig.request(.password))).contains(.messagesCode))
        }
    }

    @Test(arguments: ["assistant", "connected app call", "connected app holds"])
    func aTabAnAgentControlsIsNeverOffered(controller: String) async throws {
        try await withRig(vaults: [.unlocked]) { rig, _ in
            let connection = UUID()
            switch controller {
            case "assistant":
                rig.tab.setAgentWorking(true)
            case "connected app call":
                rig.tab.setExternalAutomationWorking(true)
            default:
                rig.tab.processState.setExternalController(connection, holds: true)
            }
            #expect(!(await rig.actions(for: rig.request(.totp))).contains(.messagesCode))
        }
    }

    @Test func aPrivateWindowIsNeverOffered() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let rig = Rig(context: context)
        let actions = await rig.actions(for: rig.request(.totp))
        #expect(!actions.contains(.messagesCode))
        #expect(AutofillSuggestions.messagesCodeRow(kind: .password, field: .totp, origin: Self.shop, in: rig.page) == nil)
        await rig.close()
        await context.endPrivateSession()
    }

    /// The lookup validates its request before it shows the panel. A profile without a vault holds no grant and finds no lock, so a
    /// request is authorized only by the row it offers; the one that offers nothing is refused, as it always was.
    @Test func aRequestOfferingOnlyTheRowIsAuthorizedWhereOneOfferingNothingIsNot() async throws {
        try await withRig(vaults: []) { rig, _ in
            let suggestions = AutofillSuggestions.shared
            let key = ObjectIdentifier(rig.page)
            defer { suggestions.requests[key] = nil }

            let bare = rig.request(.totp)
            suggestions.requests[key] = bare
            #expect(throws: ContactAutofillError.self) { try suggestions.requireAuthority(bare, in: rig.page) }

            let offering = rig.request(.totp)
            offering.actions[UUID()] = .messagesCode
            suggestions.requests[key] = offering
            #expect(throws: Never.self) { try suggestions.requireAuthority(offering, in: rig.page) }

            // Once chosen it stays authorized whatever happens to the vault, and only while it is the page's request.
            let chosen = rig.request(.totp)
            chosen.isMessagesCode = true
            suggestions.requests[key] = chosen
            #expect(throws: Never.self) { try suggestions.requireAuthority(chosen, in: rig.page) }
            #expect(throws: ContactAutofillError.self) { try suggestions.requireAuthority(offering, in: rig.page) }
        }
    }

    @Test func theRowIsNamedAndCarriesNothingElse() async throws {
        try await withRig(vaults: []) { rig, _ in
            let row = try #require(AutofillSuggestions.messagesCodeRow(kind: .password, field: .totp, origin: Self.shop, in: rig.page))
            #expect(row.title == "Code from Messages or Mail…" && row.detail.isEmpty && row.origin == Self.shop)
        }
    }

    @Test func aRefocusRightAfterAFillDoesNotOpenTheDropdownAgainAndOnlyForThatField() async throws {
        try await withRig(vaults: []) { rig, _ in
            let suggestions = AutofillSuggestions.shared
            defer { suggestions.quiet = nil }
            suggestions.quiet = .init(page: ObjectIdentifier(rig.page), documentID: "doc", fieldID: "2", until: .now.advanced(by: .seconds(2)))
            #expect(suggestions.isQuiet(rig.page, documentID: "doc", fieldID: "2"))
            #expect(!suggestions.isQuiet(rig.page, documentID: "doc", fieldID: "3"), "another field")
            #expect(!suggestions.isQuiet(rig.page, documentID: "other", fieldID: "2"), "another document")
            suggestions.quiet = .init(page: ObjectIdentifier(rig.page), documentID: "doc", fieldID: "2", until: .now.advanced(by: .seconds(-1)))
            #expect(!suggestions.isQuiet(rig.page, documentID: "doc", fieldID: "2"), "not for long")
        }
    }
}
