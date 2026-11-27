// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import MCP
import Testing

@testable import WSurf

extension MCPv2CoreTests {
    @Test func clientPolicyControlsPasswordAndVaultAccessOnExistingConnections() async throws {
        try await withRig(ownerPath: "/login") { rig in
            let client = try rig.trust.pair(token: SyntheticToken.first, name: "Editor", kind: nil)
            try rig.trust.setAllowsPasswordEntry(true)
            var consentCalls = 0
            var disableDuringConsent = false
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true }, consent: { _, _, _ in .control },
                loginConsent: { _, _, accounts, _, _ in
                    consentCalls += 1
                    if disableDuringConsent {
                        try? rig.trust.setClientPolicy(\.allowsVaultFill, to: false, for: client.id)
                        return .fill(accountID: accounts.first?.id)
                    }
                    #expect(accounts.isEmpty)
                    return .takeOver
                },
                vaultProvider: fakeVault())
            session.pairedClient = client
            defer { session.revoke() }
            _ = try await call(session, "requestAccess")
            let read = try await call(session, "readPage", tab: rig.owner)
            let args: [String: Value] = ["ref": .int(try fieldRef("Password", in: read)), "text": .string(Self.controlPassword), "secret": true]
            let refused = try await call(session, "typeOnPage", tab: rig.owner, args)
            #expect(refused.structuredContent?.objectValue?["code"] == "accessDenied")
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == "")
            try rig.trust.setClientPolicy(\.allowsPasswordEntry, to: true, for: client.id)
            let allowed = try await call(session, "typeOnPage", tab: rig.owner, args)
            #expect(allowed.isError == false, "\(everything(allowed))")
            #expect(!everything(allowed).contains(Self.controlPassword))
            try rig.trust.setAllowsPasswordEntry(false)
            #expect(!session.allowsPasswordEntry(for: rig.owner))

            disableDuringConsent = true
            let changed = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(changed.structuredContent?.objectValue?["code"] == "accessDenied")
            #expect(!rig.owner.isMCPCredentialTainted)
            let blocked = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(blocked.structuredContent?.objectValue?["code"] == "accessDenied")
            #expect(consentCalls == 1)
            let after = try await call(session, "readPage", tab: rig.owner)
            #expect(after.structuredContent?.objectValue?["vaultHint"]?.objectValue?["hasSavedLogin"] == false)
            disableDuringConsent = false
            let manual = try await call(session, "requestUserLogin", tab: rig.owner)
            #expect(manual.structuredContent?.objectValue?["code"] == "waitingForUser")
            #expect(consentCalls == 2)
        }
    }

    @Test func clientEngineAndCleanupFollowTheOpeningConnection() async throws {
        try await withRig { rig in
            let client = try rig.trust.pair(token: SyntheticToken.first, name: "Editor", kind: nil)
            try rig.trust.setClientPolicy(\.defaultEngine, to: .webKit, for: client.id)
            let first = MCPBrowserSession(browser: rig.browser, trust: rig.trust, available: { true }, openConsent: { _, _ in true })
            let second = MCPBrowserSession(browser: rig.browser, trust: rig.trust, available: { true }, openConsent: { _, _ in true })
            first.pairedClient = client
            first.clientName = client.name
            second.pairedClient = client
            defer {
                first.revoke()
                second.revoke()
            }
            let url = try rig.server.url("/other")
            let args: [String: Value] = ["url": .string(url.absoluteString), "waitAndRead": false]
            let firstResult = try await call(first, "newTab", args)
            #expect(firstResult.structuredContent?.objectValue?["engine"] == "webkit")
            let opened = try #require(rig.browser.agentTabs(openedBy: first.id).first)
            #expect(opened.mcpAgentTabOrigin?.pairedClientID == client.id)
            #expect(opened.mcpAgentTabOrigin?.clientName == client.name)
            #expect(rig.owner.mcpAgentTabOrigin == nil)

            _ = try await call(first, "newTab", args)
            let nowShared = try #require(rig.browser.agentTabs(openedBy: first.id).first { $0 !== opened })
            nowShared.spaceTabID = UUID()
            _ = try await call(first, "newTab", args)
            let takenOver = try #require(rig.browser.agentTabs(openedBy: first.id).first { $0 !== opened })
            first.handBack(takenOver)
            _ = try await call(second, "newTab", args)
            let otherSession = try #require(rig.browser.agentTabs(openedBy: second.id).first)
            try rig.trust.setClientPolicy(\.defaultEngine, to: .chromium, for: client.id)
            try await checkRestrictedEngine(for: url, session: first)

            first.revoke()
            rig.browser.closeAgentTabs(openedBy: first.id)
            #expect(opened.isClosed)
            for tab in [rig.owner, nowShared, takenOver, otherSession] {
                #expect(!tab.isClosed)
            }
            #expect(rig.browser.agentTabs(openedBy: first.id).isEmpty)
        }
    }

    private func checkRestrictedEngine(for url: URL, session: MCPBrowserSession) async throws {
        try await SitePermissions.withWebKitOnlyOriginForTesting(SitePermissions.origin(for: url)) {
            let args: [String: Value] = ["url": .string(url.absoluteString), "waitAndRead": false]
            let implicitEngine = try await call(session, "newTab", args)
            #expect(implicitEngine.structuredContent?.objectValue?["engine"] == "webkit")
            let explicitEngine = try await call(session, "newTab", args.merging(["engine": "chromium"]) { _, new in new })
            #expect(explicitEngine.structuredContent?.objectValue?["code"] == "webKitRequired")
        }
    }

    @Test func structuredCodesPreserveToolStatusAndMessage() async throws {
        try await withRig(ownerPath: "/login") { rig in
            var vault = emptyVault()
            vault.isLocked = { _, _ in true }
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true }, consent: { _, _, _ in .control }, vaultProvider: vault)
            defer { session.revoke() }
            #expect(!rig.trust.allowsPasswordEntry)
            let missing = try await call(session, "readPage", ["tabID": .string(UUID().uuidString)])
            #expect(missing.structuredContent?.objectValue?["code"] == "tabNotFound")
            #expect(MCPBrowserSession.text(of: missing) == "This tab is not shared with this connection.")
            _ = try await call(session, "requestAccess")
            let invalid = try await call(session, "newTab", ["url": "file:///tmp/synthetic"])
            #expect(invalid.structuredContent?.objectValue?["code"] == "invalidInput")
            let locked = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(locked.structuredContent?.objectValue?["code"] == "vaultLocked")
            #expect(locked.structuredContent?.objectValue?["status"] == "noSavedLogin")
            let timedOut = try await call(session, "waitForPage", tab: rig.owner, ["condition": "text", "value": "absent marker", "timeout": 1])
            #expect(timedOut.structuredContent?.objectValue?["code"] == "timeout", "\(everything(timedOut))")
            let unsupported = try await call(session, "browser_file_upload")
            #expect(unsupported.structuredContent?.objectValue?["code"] == "unsupported")
        }
    }
}
