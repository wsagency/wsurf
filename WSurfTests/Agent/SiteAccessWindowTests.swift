// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct SiteAccessWindowTests {
    private struct Owner {
        let coordinator: AppCoordinator
        let window: NSWindow
        let adapter: ExtensionWindowAdapter

        @MainActor func close() {
            coordinator.closeWindow()
            window.close()
        }
    }

    private func makeOwner(in app: BrowserApplication, privately: Bool = false) -> Owner {
        let profile = privately ? Profile.privateBrowsing() : .original()
        let context = BrowserProfileContext.shared(for: profile)
        let coordinator = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID()))
        app.register(coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let adapter = coordinator.extensions.register(browser: coordinator.browser, window: window)
        window.orderFrontRegardless()
        return Owner(coordinator: coordinator, window: window, adapter: adapter)
    }

    private func makeAccess() -> (TabAssistantAccessCenter, SitePermissions) {
        let store = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("SiteAccessWindowTests-\(UUID().uuidString).json")
        )
        let access = TabAssistantAccessCenter(store: store)
        access.pageChanged(url: URL(string: "https://example.com/page"))
        return (access, store)
    }

    private func attachedSheet(to window: NSWindow) async -> NSWindow? {
        for _ in 0..<1_000 {
            if let sheet = window.attachedSheet {
                return sheet
            }
            await Task.yield()
        }
        return nil
    }

    @Test func nativeGrantStaysOnOriginWindowAfterRegularAndPrivateFocusChanges() async throws {
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let app = BrowserApplication()
        let origin = makeOwner(in: app)
        let regular = makeOwner(in: app)
        let privateWindow = makeOwner(in: app, privately: true)
        defer {
            origin.close()
            regular.close()
            privateWindow.close()
        }
        let tab = origin.coordinator.browser.newTab()
        origin.window.makeKeyAndOrderFront(nil)
        regular.window.makeKeyAndOrderFront(nil)
        app.focus(regular.coordinator)
        privateWindow.window.makeKeyAndOrderFront(nil)
        app.focus(privateWindow.coordinator)
        #expect(await waitUntil { NSApp.isActive && NSApp.keyWindow === privateWindow.window },
                "Frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        let (access, store) = makeAccess()

        let authorization = Task {
            await AgentActionConsent.$scopedWindow.withValue(origin.adapter) {
                await TabAssistantAccessCenter.$presentsNativeSheetForTesting.withValue(true) {
                    await access.authorize(.read, in: tab.page)
                }
            }
        }
        let sheet = try #require(await attachedSheet(to: origin.window))
        #expect(regular.window.attachedSheet == nil)
        #expect(privateWindow.window.attachedSheet == nil)

        regular.window.makeKeyAndOrderFront(nil)
        app.focus(regular.coordinator)
        privateWindow.window.makeKeyAndOrderFront(nil)
        app.focus(privateWindow.coordinator)
        #expect(await waitUntil { NSApp.isActive && NSApp.keyWindow === privateWindow.window },
                "Frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        origin.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

        #expect(await authorization.value)
        #expect(store.assistantAccess(for: "https://example.com") == .readOnly)
    }

    @Test func closingOriginWhileNativeConsentIsPendingDoesNotPersistGrant() async throws {
        let app = BrowserApplication()
        let origin = makeOwner(in: app)
        defer { origin.close() }
        let (access, store) = makeAccess()

        let authorization = Task {
            await AgentActionConsent.$scopedWindow.withValue(origin.adapter) {
                await TabAssistantAccessCenter.$presentsNativeSheetForTesting.withValue(true) {
                    await access.authorize(.read)
                }
            }
        }
        let sheet = try #require(await attachedSheet(to: origin.window))
        origin.coordinator.extensions.unregister(browser: origin.coordinator.browser)
        origin.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

        #expect(!(await authorization.value))
        #expect(store.assistantAccess(for: "https://example.com") == .ask)
    }

    @Test func cancellingDuringNativeConsentDoesNotPersistGrant() async throws {
        let app = BrowserApplication()
        let origin = makeOwner(in: app)
        defer { origin.close() }
        let (access, store) = makeAccess()

        let authorization = Task {
            await AgentActionConsent.$scopedWindow.withValue(origin.adapter) {
                await TabAssistantAccessCenter.$presentsNativeSheetForTesting.withValue(true) {
                    await access.authorize(.read)
                }
            }
        }
        let sheet = try #require(await attachedSheet(to: origin.window))
        authorization.cancel()
        origin.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

        #expect(!(await authorization.value))
        #expect(store.assistantAccess(for: "https://example.com") == .ask)
    }

    @Test func movingOriginTabDuringNativeConsentDoesNotPersistGrant() async throws {
        let app = BrowserApplication()
        let origin = makeOwner(in: app)
        let destination = makeOwner(in: app)
        defer {
            origin.close()
            destination.close()
        }
        let tab = origin.coordinator.browser.newTab()
        let (access, store) = makeAccess()

        let authorization = Task {
            await AgentActionConsent.$scopedWindow.withValue(origin.adapter) {
                await TabAssistantAccessCenter.$presentsNativeSheetForTesting.withValue(true) {
                    await access.authorize(.read, in: tab.page)
                }
            }
        }
        let sheet = try #require(await attachedSheet(to: origin.window))
        #expect(destination.coordinator.browser.adoptTab(tab, from: origin.coordinator.browser))
        origin.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

        #expect(!(await authorization.value))
        #expect(store.assistantAccess(for: "https://example.com") == .ask)
    }
    @Test func movedPageIsNotAuthorizedByItsFormerWindowOwner() async {
        let app = BrowserApplication()
        let formerOwner = makeOwner(in: app)
        let destination = makeOwner(in: app)
        defer {
            formerOwner.close()
            destination.close()
        }
        let tab = formerOwner.coordinator.browser.newTab()
        #expect(destination.coordinator.browser.adoptTab(tab, from: formerOwner.coordinator.browser))
        let movedPage = tab.page
        let (access, store) = makeAccess()

        let allowed = await AgentActionConsent.$scopedWindow.withValue(formerOwner.adapter) {
            await access.authorize(.read, in: movedPage)
        }

        #expect(!allowed)
        #expect(store.assistantAccess(for: "https://example.com") == .ask)
    }
}
