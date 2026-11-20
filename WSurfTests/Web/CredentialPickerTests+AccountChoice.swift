// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf
@testable import WSurfVault

extension CredentialPickerTests {
    @Test(.boundedWebViews, arguments: [false, true])
    func theManualPickerPrioritizesTheGoogleAccountAndOffersOnlyLoginsOnItsPasswordStep(fromEdit: Bool) async throws {
        let site = "https://accounts.google.com"
        try await withFlow(vaults: [.unlocked, .unlocked]) { flow, vaults in
            let earlier = account("earlier@example.test", origins: [site], totp: Self.generator)
            let chosen = account("later@EXAMPLE.TEST", origins: [site])
            try await VaultManagerFixture.save([earlier, chosen], in: vaults[0])
            try await VaultManagerFixture.save([chosen], in: vaults[1])
            try await flow.load(#"""
            <span id="profileIdentifier">later@example.test</span>
            <form><input id="pass" type="password" autocomplete="current-password"></form>
            """#, at: site + "/v3/signin/challenge/pwd")
            let useKey = try await vaults[0].manager.importMemoryKey()
            flow.page.context.autofillLastUsed.record(useKey, account: earlier.id, origin: site)
            let target: CredentialPicker.Target
            if fromEdit {
                flow.session.selectAccount(chosen.id, username: chosen.username, in: flow.page, origin: site, epoch: vaults[1].manager.authorizationEpoch)
                try await flow.focus("pass")
                try #require(await CredentialPicker.shared.noteFocusedField(in: flow.page))
                target = try #require(CredentialPicker.shared.target(for: flow.page, menu: .init(opened: .now)))
            } else {
                target = try await flow.rightClick("pass")
            }
            _ = await flow.pick(target) { rows in
                #expect(rows.map(\.accountID) == [chosen.id, chosen.id, earlier.id])
                if fromEdit {
                    #expect(rows.first?.vaultID == vaults[1].vaultID)
                }
                #expect(rows.allSatisfy { $0.fill == .login })
                return nil
            }
        }
    }

    @Test(.boundedWebViews) func aLockedVaultCanBeUnlockedBesideTheOtherAccountOnThePage() async throws {
        try await withFlow(vaults: [.unlocked, .unlocked]) { flow, vaults in
            let open = account("open@example.test"), locked = account("locked@example.test")
            try await VaultManagerFixture.save([open], in: vaults[0])
            try await VaultManagerFixture.save([locked], in: vaults[1])
            try await flow.load(#"""
            <form><input type="hidden" autocomplete="username" value="locked@example.test">
            <input id="pass" type="password" autocomplete="current-password" style="position:fixed;inset:0;width:100%;height:100%;box-sizing:border-box"></form>
            """#)
            flow.session.selectAccount(locked.id, username: locked.username, in: flow.page, origin: Self.site, epoch: vaults[1].manager.authorizationEpoch)
            vaults[1].manager.lock(reason: .manual)
            var selected: BrowserScriptMessage?
            flow.page.addScriptMessageHandler(name: "wsurfPasswords", in: PasswordAutofill.world) { message in
                if let report = message.body as? [String: Any], report["action"] as? String == "select" { selected = message }
                PasswordAutofill.shared.receive(message)
            }
            try await flow.focus("pass")
            try #require(await waitUntil { selected != nil })
            let message = try #require(selected), body = try #require(message.body as? [String: Any]), url = try #require(flow.page.url)
            let request = AutofillSuggestions.Request(
                page: flow.page, context: flow.page.context, frame: message.frameInfo, token: try #require(body["token"] as? String),
                kind: .password, frameURL: url, topURL: url, world: PasswordAutofill.world, bridge: "__wsurfPasswords",
                documentID: try #require(body["documentID"] as? String), formID: try #require(body["formID"] as? String),
                fieldID: try #require(body["fieldID"] as? String), field: .password, enteredUsername: locked.username,
                typeToSearch: false, isWebAuthnField: false
            )
            let suggestions = AutofillSuggestions.shared, key = ObjectIdentifier(flow.page)
            request.rect = flow.page.bounds
            suggestions.requests[key] = request
            defer { suggestions.requests[key] = nil }
            _ = await suggestions.lookUp(request, origin: Self.site, presentation: suggestions.presentationID, in: flow.page)
            #expect(request.rows.values.map(\.accountID) == [open.id])
            #expect(request.actions.values.contains(.unlock))
            #expect(!vaults[1].manager.isUnlocked)
        }
    }
}
