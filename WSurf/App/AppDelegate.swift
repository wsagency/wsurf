// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit

/// WSurf installs no SwiftUI `App` scene. SwiftUI replaces `NSApp.mainMenu`
/// during launch and discards the shortcuts set before it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var terminationPending = false

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        NSApp.setActivationPolicy(.regular)
        guard MoveToApplications.offerIfNeeded() != .relaunching else { return }
        Task { await coordinator.bootstrap() }
        #if DEBUG
        AnimationProbe.runIfRequested(coordinator: coordinator)
        AnimationProbe.runSplitProbeIfRequested(coordinator: coordinator)
        StageRun.startIfRequested(coordinator: coordinator)
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isRunningTests else { return }
        coordinator.openFromAnotherApp(urls)
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard !isRunningTests else { return false }
        return coordinator.receiveCredentialExchange(userActivity)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !isRunningTests else { return true }
        coordinator.showBrowser()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningTests else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        coordinator.mcpServer.stop()
        coordinator.browser.saveBlocking()
        Task {
            do {
                try await coordinator.clearDataOnQuitIfNeeded()
                coordinator.agentTurns.cancel()
                coordinator.media.releaseControl()
                let tabs = coordinator.browser.tabs
                coordinator.browser.closeAllTabs(saving: false)
                for tab in tabs {
                    await tab.waitForRetirement()
                }
                await ChromiumRuntime.shared.shutdown()
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                terminationPending = false
                coordinator.mcpServer.resume()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Browsing data could not be cleared. WSurf will stay open.")
                alert.informativeText = error.localizedDescription
                alert.runModal()
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isRunningTests else { return }
        coordinator.conversationLog.saveBlocking()
        coordinator.browser.downloads.clearOnQuitIfNeeded(coordinator.settings.downloadRetention)
    }
}
