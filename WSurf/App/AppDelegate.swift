// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit

/// WSurf installs no SwiftUI `App` scene. SwiftUI replaces `NSApp.mainMenu`
/// during launch and discards the shortcuts set before it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let application = BrowserApplication.shared
    private var terminationPending = false

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppleSpeechVoiceCatalog.shared.prepare()
        guard !isRunningTests else { return }
        NSApp.setActivationPolicy(.regular)
        guard MoveToApplications.offerIfNeeded() != .relaunching else { return }
        Task {
            await application.bootstrap()
            #if DEBUG
            if let coordinator = application.activeCoordinator {
                AnimationProbe.runIfRequested(coordinator: coordinator)
                AnimationProbe.runSplitProbeIfRequested(coordinator: coordinator)
                StageRun.startIfRequested(coordinator: coordinator)
            }
            #endif
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isRunningTests else { return }
        self.application.openFromAnotherApp(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !isRunningTests else { return true }
        application.showBrowser()
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
        application.prepareToTerminate()
        Task {
            do {
                try await application.clearDataOnQuitIfNeeded()
                await application.closePagesForTermination()
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                terminationPending = false
                application.cancelTermination()
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
        application.finishTermination()
    }
}
