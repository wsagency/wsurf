// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

extension MCPv2CoreTests {
    // MARK: 7. Security Review Hardening Coverage

    @Test func originChangeDuringLoginApprovalSheetAbortsWithoutInjectingCredentials() async throws {
        try await withRig(ownerPath: "/login") { rig in
            let otherOrigin = try await HTTPFixtureServer.start(routes: [
                "/login": .html(Self.loginHTML),
            ])
            defer { _ = otherOrigin }
            let otherURL = try otherOrigin.url("/login")
            var blindFillCalled = false
            let summary = MCPVaultProvider.AccountSummary(
                id: UUID(), label: "alice@example.test", vaultID: UUID(), revision: 1, epoch: 1)
            let provider = MCPVaultProvider(
                savedAccounts: { _, _, _ in [summary] },
                blindFill: { _, view, url, _, submit, registerSecret in
                    blindFillCalled = true
                    _ = registerSecret(Self.vaultPassword)
                    return await PageDriver.fillVaultLogin(
                        username: "alice@example.test", password: Self.vaultPassword, submit: submit,
                        expectedOrigin: SitePermissions.origin(for: url), in: view)
                })
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                loginConsent: { _, _, accounts, _, _ in
                    // Page navigates to a completely different origin while the approval sheet is open.
                    _ = rig.owner.load(otherURL, transition: .agent)
                    _ = await waitUntil { rig.owner.page.url == otherURL && !rig.owner.page.isLoading }
                    return .fill(accountID: accounts.first?.id)
                },
                vaultProvider: provider)
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            let result = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(result.isError == true)
            #expect(!blindFillCalled, "blindFill must not run after origin changed during consent")
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == "")

            // Defense in depth: even calling PageDriver.fillVaultLogin directly with a mismatched origin refuses cleanly.
            let direct = await PageAutomationGuard.$current.withValue(
                PageAutomationGuard(documentURL: otherURL.absoluteString, snapshot: nil, validate: { true })
            ) {
                await PageDriver.fillVaultLogin(
                    username: "alice@example.test", password: Self.vaultPassword, submit: false,
                    expectedOrigin: "https://original.invalid", in: rig.owner.page)
            }
            #expect(!direct.ok)
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == "")
        }
    }

    @Test func vaultBlindFillNeverTargetsCrossOriginOrSameOriginIframes() async throws {
        let frameServer = try await HTTPFixtureServer.start(routes: [
            "/frame": .html("<!doctype html><input id=inner type=password aria-label=\"Password\">"),
        ])
        defer { _ = frameServer }
        let frameURL = try frameServer.url("/frame")
        let hostServer = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <!doctype html><title>Framed Login</title>
                <iframe id=xo src="\(frameURL.absoluteString)" style="width:320px;height:80px"></iframe>
                <iframe id=same srcdoc="<input id=samepw type=password aria-label='Same frame password'>" style="width:320px;height:80px"></iframe>
                """),
        ])
        defer { _ = hostServer }
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPv2Frame-\(UUID().uuidString).json")))
        let url = try hostServer.url()
        let tab = browser.newTab(url: url)
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 640, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        root.addSubview(WebViewParkingShelf(frame: .zero))
        let container = WebViewContainer(page: tab.page)
        container.frame = root.bounds
        root.addSubview(container)
        window.contentView = root
        window.orderBack(nil)
        browser.context.extensions.register(browser: browser, window: window)
        defer {
            browser.closeAllTabs(saving: false)
            browser.context.extensions.unregister(browser: browser)
            window.contentView = nil
            window.close()
        }
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading && tab.page.mainDocumentID != nil })
        try #require(await waitUntil {
            (try? await tab.page.evaluateJavaScript("!!document.getElementById('same').contentDocument?.getElementById('samepw')")) as? Bool == true
        })

        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true },
            consent: { _, _, _ in .control },
            loginConsent: { _, _, accounts, _, _ in .fill(accountID: accounts.first?.id) },
            vaultProvider: fakeVault())
        defer { session.revoke() }

        _ = try await call(session, "requestAccess")
        let result = try await call(session, "requestUserLogin", tab: tab, ["mode": "vaultFill"])
        #expect(result.isError == true, "iframe-only login forms must be refused by blind fill: \(everything(result))")
        #expect(everything(result).contains("No visible login fields"))
        let sameVal = try await tab.page.evaluateJavaScript("document.getElementById('same').contentDocument.getElementById('samepw').value") as? String
        #expect(sameVal == "", "same-origin iframe password input must remain empty")
    }

    @Test func agentSecretCapCannotExhaustVaultScrubbingAndRegistrationFailureAbortsFill() async throws {
        try await withRig(ownerPath: "/login") { rig in
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                loginConsent: { _, _, accounts, _, _ in .fill(accountID: accounts.first?.id) },
                vaultProvider: fakeVault())
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")

            // Exhaust all 32 agent-typed secret slots first.
            for index in 0..<MCPSecretScrubber.maximumSecrets {
                #expect(session.secrets.register("dummy-agent-secret-\(index)") == .registered)
            }
            #expect(session.secrets.register("dummy-agent-secret-overflow") == .tooMany)

            // Vault blind fill uses its dedicated exempt bucket and still registers and scrubs cleanly.
            let filled = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(filled.isError == false, "\(everything(filled))")
            #expect(session.secrets.vaultSecretCount == 1)
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == Self.vaultPassword)
            #expect(session.scrubbed("echo: \(Self.vaultPassword)") == "echo: \(Self.hidden)")

            // If Vault secret registration fails (e.g. < 4 bytes cannot be safely scrubbed), fill aborts BEFORE touching DOM.
            _ = try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value = ''; 0")
            session.vaultProvider = fakeVault(password: "abc")
            let rejected = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(rejected.isError == true, "unscrubbable Vault password must refuse before DOM fill")
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == "")
        }
    }

    @Test func keychainUnavailableFailsClosedForPasswordEntry() async throws {
        try await withRig(ownerPath: "/login") { rig in
            let refusedTrust = MCPTrustStore(storage: MemoryTrustStorage(refusesReads: true))
            refusedTrust.loadIfNeeded()
            #expect(!refusedTrust.isAvailable)
            #expect(!refusedTrust.allowsPasswordEntry)

            let nilTrust = MCPTrustStore(storage: nil)
            nilTrust.loadIfNeeded()
            #expect(!nilTrust.isAvailable)
            #expect(!nilTrust.allowsPasswordEntry)

            let session = MCPBrowserSession(
                browser: rig.browser, trust: refusedTrust, available: { true },
                consent: { _, _, _ in .control })
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            #expect(!session.allowsPasswordEntry(for: rig.owner))
            let read = try await call(session, "readPage", tab: rig.owner)
            let pwRef = try fieldRef("Password", in: read)
            let blocked = try await call(session, "typeOnPage", tab: rig.owner, [
                "observationID": .string(try observation(read)), "ref": .int(pwRef), "text": .string(Self.controlPassword),
            ])
            #expect(blocked.isError == true)
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == "")

            _ = try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value = 'UserManual-77!'; 0")
            let blockedShot = try await call(session, "screenshotPage", tab: rig.owner)
            #expect(blockedShot.isError == true)
            #expect(everything(blockedShot).contains("Screenshot refused"))
        }
    }

    @Test func showPasswordToggleKeepsUserTypedAndVaultFilledPasswordsHiddenBlockedAndMasked() async throws {
        let toggleHTML = """
            <!doctype html><title>Toggle</title>
            <style>
              body { margin: 0; }
              input { display: block; width: 240px; height: 32px; border: 0; padding: 0; background: #f00; color: #fff; }
              #plain { width: 240px; height: 32px; background: #00f; }
            </style>
            <input type=password>
            <div id=plain></div>
            <button onclick="document.querySelector('input').type = 'text'">Show</button>
            """
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(toggleHTML)])
        defer { _ = server }
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(.developer, for: client.id)
        try trust.setDeveloperProfile(Profile.originalID)
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPv2Toggle-\(UUID().uuidString).json")))
        let url = try server.url()
        let tab = browser.newTab(url: url)
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 640, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        root.addSubview(WebViewParkingShelf(frame: .zero))
        let container = WebViewContainer(page: tab.page)
        container.frame = root.bounds
        root.addSubview(container)
        window.contentView = root
        window.orderBack(nil)
        browser.context.extensions.register(browser: browser, window: window)
        defer {
            browser.closeAllTabs(saving: false)
            browser.context.extensions.unregister(browser: browser)
            window.contentView = nil
            window.close()
        }
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading && tab.page.mainDocumentID != nil })

        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true },
            consent: { _, _, _ in .developer },
            loginConsent: { _, _, accounts, _, _ in .fill(accountID: accounts.first?.id) },
            vaultProvider: fakeVault())
        session.pairedClient = trust.client(id: client.id)
        defer { session.revoke() }
        _ = try await call(session, "requestAccess")

        // Case A: User manually types into an unlabeled/nameless/id-less <input type=password>, then agent clicks "Show".
        let userSecret = "UnlabeledUserPw-99!"
        _ = try await tab.page.evaluateJavaScript("""
            (() => {
              const i = document.querySelector('input');
              i.value = '\(userSecret)';
              i.dispatchEvent(new Event('input', { bubbles: true }));
              return true;
            })()
            """)
        try #require(await waitUntil {
            (try? await tab.page.evaluateJavaScript("document.querySelector('input').hasAttribute('data-wsurf-password')")) as? Bool == true
        })
        let readBefore = try await call(session, "readPage", tab: tab)
        let showBtn = try buttonRef("Show", in: readBefore)
        let clickedShow = try await call(session, "clickOnPage", tab: tab, [
            "observationID": .string(try observation(readBefore)), "ref": .int(showBtn),
        ])
        #expect(clickedShow.isError == false)
        #expect(try await tab.page.evaluateJavaScript("document.querySelector('input').type") as? String == "text")

        let readAfter = try await call(session, "readPage", tab: tab)
        #expect(!everything(readAfter).contains(userSecret), "toggled user password must stay hidden in readPage")
        #expect(everything(readAfter).contains("(filled, hidden)"))
        let evalBlocked = try await call(session, "evaluateScript", tab: tab, ["source": "document.querySelector('input').value"])
        #expect(evalBlocked.isError == true && evalBlocked.structuredContent?.objectValue?["code"]?.stringValue == "protectedSecretPresent")

        let shot = try await call(session, "screenshotPage", tab: tab)
        #expect(shot.isError == false)
        let width = try #require(try await tab.page.evaluateJavaScript("window.innerWidth") as? Int)
        let imageData = try #require(shot.content.compactMap { block -> Data? in
            guard case .image(let base64, _, _, _) = block else { return nil }
            return Data(base64Encoded: base64)
        }.first)
        let scale = CGFloat(try #require(NSBitmapImageRep(data: imageData)).pixelsWide) / CGFloat(width)
        let box = try #require(try await tab.page.evaluateJavaScript(
            "(() => { const r = document.querySelector('input').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()") as? [Double])
        let pwColor = try sampleColor(in: shot, at: CGPoint(x: box[0], y: box[1]), scale: scale)
        #expect(pwColor.red < 0.15 && pwColor.green < 0.15 && pwColor.blue < 0.15, "toggled password box stays masked black: \(pwColor)")

        // Case B: Reload fresh, Vault-fill, click "Show" -> stays hidden, blocked, and masked.
        _ = tab.load(url, transition: .agent)
        try #require(await waitUntil {
            guard !tab.page.isLoading else { return false }
            return (try? await tab.page.evaluateJavaScript("document.querySelector('input').type")) as? String == "password"
        })
        let filled = try await call(session, "requestUserLogin", tab: tab, ["mode": "vaultFill"])
        #expect(filled.isError == false)
        let readVault = try await call(session, "readPage", tab: tab)
        _ = try await call(session, "clickOnPage", tab: tab, [
            "observationID": .string(try observation(readVault)), "ref": .int(try buttonRef("Show", in: readVault)),
        ])
        #expect(try await tab.page.evaluateJavaScript("document.querySelector('input').type") as? String == "text")
        let readVaultAfter = try await call(session, "readPage", tab: tab)
        #expect(!everything(readVaultAfter).contains(Self.vaultPassword))
        let evalVaultBlocked = try await call(session, "evaluateScript", tab: tab, ["source": "document.querySelector('input').value"])
        #expect(evalVaultBlocked.isError == true && evalVaultBlocked.structuredContent?.objectValue?["code"]?.stringValue == "protectedSecretPresent")
    }

    @Test func credentialTaintSurvivesPushStateAndHashChangesAndPureReadsAndNilMainDocumentID() async throws {
        try await withRig(ownerPath: "/login") { rig in
            let client = try rig.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
            try rig.trust.setStanding(.developer, for: client.id)
            try rig.trust.setDeveloperProfile(Profile.originalID)
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .developer },
                loginConsent: { _, _, accounts, _, _ in .fill(accountID: accounts.first?.id) },
                vaultProvider: fakeVault())
            session.pairedClient = rig.trust.client(id: client.id)
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            let filled = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(filled.isError == false)
            _ = try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value = ''; 0")

            // Querying with an unrelated documentID must be a pure read and MUST NOT clear taint.
            #expect(!session.isMainDocumentCredentialTainted(tab: rig.owner, mainDocumentID: "unrelated-doc"))
            #expect(session.credentialTaintedDocuments[rig.owner.id] != nil)

            // SPA history.pushState and hash changes keep the same documentCommitEpoch -> taint survives!
            _ = try await rig.owner.page.evaluateJavaScript("history.pushState(null, '', '/login?step=2'); location.hash = '#verify'; 0")
            #expect(await session.isDocumentCredentialProtected(tab: rig.owner, view: rig.owner.page))
            let denied = try await call(session, "evaluateScript", tab: rig.owner, ["source": "location.href"])
            #expect(denied.isError == true && denied.structuredContent?.objectValue?["code"]?.stringValue == "protectedSecretPresent")

            // Conservative nil mainDocumentID handling: stays tainted for current commit epoch until real navigation commits.
            session.markCredentialTainted(tab: rig.owner, runtimeDocumentID: "rt-nil-main", mainDocumentID: nil)
            #expect(session.isMainDocumentCredentialTainted(tab: rig.owner, mainDocumentID: rig.owner.page.mainDocumentID ?? "any"))

            // Real main-frame document commit clears taint cleanly via BrowserTab commit observer.
            let dashURL = try rig.server.url("/dashboard")
            _ = try await call(session, "navigate", tab: rig.owner, ["url": .string(dashURL.absoluteString), "inPlace": true])
            try #require(await waitUntil { rig.owner.page.url == dashURL && !rig.owner.page.isLoading && rig.owner.page.mainDocumentID != nil })
            #expect(session.credentialTaintedDocuments[rig.owner.id] == nil)
            #expect(try await call(session, "evaluateScript", tab: rig.owner, ["source": "document.title"]).isError == false)
        }
    }

    @Test func multiAccountLoginSheetFillsUserChosenAccountOverAgentHint() async throws {
        try await withRig(ownerPath: "/login") { rig in
            let first = MCPVaultProvider.AccountSummary(id: UUID(), label: "hinted@example.test", vaultID: UUID(), revision: 1, epoch: 1)
            let second = MCPVaultProvider.AccountSummary(id: UUID(), label: "chosen@example.test", vaultID: UUID(), revision: 1, epoch: 1)
            let creds: [UUID: (String, String)] = [
                first.id: ("hinted@example.test", "FirstSecret-11!"),
                second.id: ("chosen@example.test", "SecondSecret-22!"),
            ]
            let provider = MCPVaultProvider(
                savedAccounts: { _, _, _ in [first, second] },
                blindFill: { _, view, url, account, submit, registerSecret in
                    guard let (user, pass) = creds[account.id] else { return nil }
                    guard registerSecret(pass) else { return nil }
                    return await PageDriver.fillVaultLogin(
                        username: user, password: pass, submit: submit,
                        expectedOrigin: SitePermissions.origin(for: url), in: view)
                })
            var offeredIDs: [UUID] = []
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                loginConsent: { _, _, accounts, _, _ in
                    offeredIDs = accounts.map(\.id)
                    // User picks the SECOND account in the picker, overriding the agent's accountHint.
                    return .fill(accountID: second.id)
                },
                vaultProvider: provider)
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            let result = try await call(session, "requestUserLogin", tab: rig.owner, [
                "mode": "vaultOrManual", "accountHint": "hinted",
            ])
            #expect(result.isError == false, "\(everything(result))")
            #expect(offeredIDs == [first.id, second.id])
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('user').value") as? String == "chosen@example.test")
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == "SecondSecret-22!")
            #expect(!everything(result).contains("SecondSecret-22!"))
            #expect(session.scrubbed("SecondSecret-22!") == Self.hidden)
        }
    }

    @Test func setTabEngineRefusesUserOwnedTabWithoutInPlaceAndHasZeroSideEffects() async throws {
        try await withRig(ownerPath: "/other", ownerEngine: .webKit) { rig in
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control })
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            let generationBefore = rig.owner.pageGeneration
            #expect(rig.owner.engine == .webKit)
            #expect(rig.owner.engineOverride == nil)

            let refused = try await call(session, "setTabEngine", tab: rig.owner, ["engine": "chromium"])
            #expect(refused.isError == true)
            #expect(everything(refused).contains("inPlace: true"))
            #expect(rig.owner.engine == .webKit, "engine must not change on refusal")
            #expect(rig.owner.engineOverride == nil, "engineOverride must not mutate on refusal")
            #expect(rig.owner.pageGeneration == generationBefore, "page must not reload on refusal")

            let allowed = try await call(session, "setTabEngine", tab: rig.owner, ["engine": "chromium", "inPlace": true])
            #expect(allowed.isError == false, "\(everything(allowed))")
            #expect(rig.owner.engine == .chromium)
            #expect(rig.owner.engineOverride == .chromium)
        }
    }

    @Test func evaluateScriptBlocksFilledAutofilledUsernameAndContactFields() async throws {
        try await withRig(ownerPath: "/autofill") { rig in
            let client = try rig.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
            try rig.trust.setStanding(.developer, for: client.id)
            try rig.trust.setDeveloperProfile(Profile.originalID)
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .developer })
            session.pairedClient = rig.trust.client(id: client.id)
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            // Clear password only; autofilled username & contact address remain filled -> evaluateScript MUST still deny.
            _ = try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value = ''; 0")
            let denied = try await call(session, "evaluateScript", tab: rig.owner, ["source": "document.getElementById('email').value"])
            #expect(denied.isError == true)
            #expect(denied.structuredContent?.objectValue?["code"]?.stringValue == "protectedSecretPresent")
            #expect(!everything(denied).contains("saved-user@example.test"))
        }
    }
}
