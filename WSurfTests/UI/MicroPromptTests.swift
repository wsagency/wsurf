// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Security
import Testing

@testable import WSurf

/// A micro window shows no address until the bar comes down, so a prompt a page raises while the bar is up out of the way
/// would be answered with no site in sight. Every kind of prompt, raised with the bar hidden, brings it down as the prompt
/// appears and keeps it there until the prompt closes.
@MainActor
@Suite(.serialized, .boundedWebViews, .exclusiveExternalApp)
struct MicroPromptTests {
    private struct Rig {
        let app: BrowserApplication
        let micro: AppCoordinator
        let window: NSWindow
        let reveal: MicroReveal
        let tab: BrowserTab
    }

    /// A micro window on a page, with its bar up out of the way and quick delays.
    private func withHiddenBar(_ body: (Rig) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Micro prompts")
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        var failure: (any Error)?
        do {
            let micro = app.newWindow(profile: profile, show: false, kind: .micro)
            let window = try #require(micro.nativeWindow)
            let reveal = micro.microReveal
            reveal.hideDelay = .milliseconds(30)
            reveal.hostFlash = .milliseconds(50)
            let tab = try #require(micro.browser.activeTab)
            tab.urlString = "https://example.com/"
            try #require(await waitUntil { !reveal.isRevealed }, "the page has the window to itself")
            try await body(Rig(app: app, micro: micro, window: window, reveal: reveal, tab: tab))
        } catch {
            failure = error
        }
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    /// Waits for the prompt to open, and checks the bar is down at once, stays down while the prompt is open, and goes up
    /// again once it is closed.
    private func expectBarHolds(
        _ rig: Rig, opened: @MainActor () -> Bool, dismiss: @MainActor () -> Void
    ) async throws {
        try #require(await waitUntil { opened() }, "the prompt never opened")
        #expect(rig.reveal.isRevealed, "the bar is down as the prompt appears")
        #expect(rig.micro.hasPendingPagePrompt, "the one flag says a page is asking")
        #expect(MicroShell.host(of: rig.tab.urlString) != nil, "and the bar has the page's site to show")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.reveal.isRevealed, "and it stays down until the prompt is gone")
        dismiss()
        try #require(await waitUntil { !rig.reveal.isRevealed }, "the bar goes up again once the prompt is closed")
        #expect(!rig.micro.hasPendingPagePrompt)
    }

    private func endSheet(of window: NSWindow) {
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
    }

    // MARK: - Sheets

    @Test func aPageDialogShowsTheSite() async throws {
        try await withHiddenBar { rig in
            let alert = NSAlert()
            alert.messageText = "A message from “example.com”"
            alert.addButton(withTitle: "OK")
            let dialog = Task { await PageDialogs.present(alert, in: rig.window) }

            try await expectBarHolds(rig, opened: { rig.window.attachedSheet != nil }, dismiss: { endSheet(of: rig.window) })
            _ = await dialog.value
        }
    }

    @Test func aRealJavaScriptAlertShowsTheSite() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Alert</title><script>setTimeout(function () { alert('Your session has expired') }, 1_500)</script>"),
        ])
        try await withHiddenBar { rig in
            rig.tab.load(try server.url("/"))
            let page = rig.tab.page
            try #require(await waitUntil { page.window === rig.window }, "the page is in the micro window")
            try #require(await waitUntil { !rig.reveal.isRevealed }, "the new site's moment is over")
            #expect(rig.window.attachedSheet == nil)

            try await expectBarHolds(rig, opened: { rig.window.attachedSheet != nil }, dismiss: { endSheet(of: rig.window) })
        }
        withExtendedLifetime(server) {}
    }

    @Test func anHTTPSignInShowsTheSite() async throws {
        try await withHiddenBar { rig in
            let space = URLProtectionSpace(
                host: "example.com", port: 443, protocol: "https", realm: "Staff",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            )
            let signIn = Task { await AuthChallenge.requestCredential(for: space, previousFailures: 0, in: rig.window) }

            try await expectBarHolds(rig, opened: { rig.window.attachedSheet != nil }, dismiss: { endSheet(of: rig.window) })
            #expect(await signIn.value == nil)
        }
    }

    @Test func aCertificateQuestionShowsTheSite() async throws {
        let trust = try Self.untrustedCertificate()
        try await withHiddenBar { rig in
            let question = Task {
                await CertificateTrust.decideInvalid(host: "example.com", trust: trust, allowsExceptions: true, in: rig.window)
            }

            try await expectBarHolds(rig, opened: { rig.window.attachedSheet != nil }, dismiss: { endSheet(of: rig.window) })
            guard case .cancel = await question.value else {
                Issue.record("a dismissed certificate question must not become an exception")
                return
            }
            CertificateTrust.forgetAll()
        }
    }

    @Test func anAppHandOffShowsTheSite() async throws {
        ExternalApp.resolverForTesting = { _ in
            .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")
        }
        ExternalApp.openerForTesting = { _ in }
        defer {
            ExternalApp.resolverForTesting = nil
            ExternalApp.openerForTesting = nil
        }
        let store = SitePermissions(storageURL: URL.temporaryDirectory.appending(path: "MicroPrompt-\(UUID().uuidString).json"))
        try await withHiddenBar { rig in
            let handOff = Task {
                await ExternalApp.offerToOpen(
                    URL(string: "slack://open")!, from: "https://example.com",
                    policy: TabExternalAppPolicy(store: store, isPrivate: true), in: rig.window, isCurrent: { true }
                )
            }

            try await expectBarHolds(rig, opened: { rig.window.attachedSheet != nil }, dismiss: { endSheet(of: rig.window) })
            await handOff.value
        }
    }

    @Test func aPasskeyStepShowsTheSite() async throws {
        try await withHiddenBar { rig in
            let step = Task {
                await NativeWebAuthnInteraction().offerStart(
                    operation: .create, origin: "https://example.com", topOrigin: nil, locked: false, in: rig.window, until: nil
                )
            }

            try await expectBarHolds(rig, opened: { rig.window.attachedSheet != nil }, dismiss: { endSheet(of: rig.window) })
            #expect(await step.value == .declined)
        }
    }

    @Test func aSheetOnAnotherWindowIsNotThisWindowsBusiness() async throws {
        try await withHiddenBar { rig in
            let other = rig.app.newWindow(profile: rig.micro.profiles.current, show: false)
            let otherWindow = try #require(other.nativeWindow)
            let alert = NSAlert()
            alert.addButton(withTitle: "OK")
            let dialog = Task { await PageDialogs.present(alert, in: otherWindow) }
            try #require(await waitUntil { otherWindow.attachedSheet != nil })

            try? await Task.sleep(for: .milliseconds(200))
            #expect(!rig.reveal.isRevealed && rig.reveal.openPrompts == 0)

            endSheet(of: otherWindow)
            _ = await dialog.value
        }
    }

    // MARK: - Not sheets

    @Test func aPermissionPromptShowsTheSite() async throws {
        try await withHiddenBar { rig in
            rig.tab.permissions.pageChanged(url: URL(string: "https://example.com/"))
            // The answer must not be written to the profile's site permissions.
            rig.tab.permissions.persistsAnswers = false
            try #require(await waitUntil { !rig.reveal.isRevealed })
            async let decision = rig.tab.permissions.decide(.camera)

            try await expectBarHolds(
                rig, opened: { rig.tab.permissions.currentAsk != nil }, dismiss: { rig.tab.permissions.answer(.deny) }
            )
            let granted = await decision
            #expect(!granted)
        }
    }

    @Test func aSaveOfferShowsTheSite() async throws {
        try await withHiddenBar { rig in
            // An offer raises its popover the moment it arrives; that flag is what the badge binds to.
            rig.tab.autofillSave.isPopoverPresented = true
            try await expectBarHolds(
                rig, opened: { rig.tab.autofillSave.isPopoverPresented }, dismiss: { rig.tab.autofillSave.isPopoverPresented = false }
            )
        }
    }

    @Test func aPopoverFromTheWindowShowsTheSite() async throws {
        try await withHiddenBar { rig in
            let popover = NSPopover()
            popover.animates = false
            popover.behavior = .applicationDefined
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
            popover.contentViewController = controller
            let anchor = try #require(rig.window.contentView)
            popover.show(relativeTo: NSRect(x: 10, y: 10, width: 10, height: 10), of: anchor, preferredEdge: .minY)

            try await expectBarHolds(rig, opened: { popover.isShown }, dismiss: { popover.close() })
        }
    }

    /// A panel that hangs from the window (the autofill suggestions) says nothing when it opens and names the site itself, so
    /// it does not bring the bar down; it holds a bar that is down until the panel goes.
    @Test func aPanelThatHangsFromTheWindowHoldsTheBarThatIsDown() async throws {
        try await withHiddenBar { rig in
            let panel = NSPanel(
                contentRect: NSRect(x: 100, y: 100, width: 200, height: 80),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            rig.reveal.pointer(inZone: true)
            #expect(rig.reveal.isRevealed)
            rig.window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            rig.reveal.pointer(inZone: false)

            try? await Task.sleep(for: .milliseconds(300))
            #expect(rig.reveal.isRevealed, "the pointer left, and the panel still hangs from the window")
            rig.window.removeChildWindow(panel)
            panel.orderOut(nil)
            try #require(await waitUntil { !rig.reveal.isRevealed }, "the bar goes up once the panel is gone")
            panel.close()
        }
    }

    // MARK: - Helpers

    private static func untrustedCertificate() throws -> SecTrust {
        let data = try #require(Data(base64Encoded: certificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let result = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(result, [] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(result, true) == errSecSuccess)
        #expect(SecTrustSetNetworkFetchAllowed(result, false) == errSecSuccess)
        #expect(SecTrustSetVerifyDate(result, Date(timeIntervalSince1970: 1_800_000_000) as CFDate) == errSecSuccess)
        return result
    }

    /// The self-signed certificate `CertificateEvaluationTests` uses, with no anchor, so it cannot be trusted.
    private static let certificate = """
        MIIBmzCCAUGgAwIBAgIUdeVwvca0ZsB/WOArBAp8Rd43EbAwCgYIKoZIzj0EAwIwIzEh
        MB8GA1UEAwwYbGluZW4tdHJ1c3QtdGVzdC5pbnZhbGlkMB4XDTI2MDkyMzA4MjUxM1oX
        DTM2MDkyMDA4MjUxM1owIzEhMB8GA1UEAwwYbGluZW4tdHJ1c3QtdGVzdC5pbnZhbGlk
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEAQ5kJDUiBcuROD3HNUBM+HesG2n/yLw+
        1lMRGwzXqvHcK5bPJ2HpngKhPVPpVNh14ajZxddF43B/l9n8+0qLh6NTMFEwHQYDVR0O
        BBYEFArGZPvXudxCdA105Q+6J+upaOooMB8GA1UdIwQYMBaAFArGZPvXudxCdA105Q+6
        J+upaOooMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAKpV/DtnSj4D
        FzBs8RaZI3ErneIJcFka2YsJvdAmw6hUAiBFdTXwJGvAe+N+nlHVAOrC9GEKxZ2exrRZ
        xpBn+P4otg==
        """.replacingOccurrences(of: "\n", with: "")
}
