// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import os

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
        guard !isRunningTests else {
            AppleSpeechVoiceCatalog.shared.prepare()
            return
        }
        LaunchSignpost.begin()
        // Decrypted vault files an earlier run showed and could not remove (a crash, a forced quit).
        VaultFilePreviewFolder.shared.removeLeftovers()
        NSApp.setActivationPolicy(.regular)
        guard MoveToApplications.offerIfNeeded() != .relaunching else { return }
        Task {
            await application.bootstrap()
            // Nothing speaks before a window is up. Apple's voice lookup warns when it runs inside a Swift task, so it runs from
            // the main queue once launch has drawn its windows.
            DispatchQueue.main.async {
                AppleSpeechVoiceCatalog.shared.prepare()
            }
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

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard !isRunningTests else { return false }
        return self.application.receiveCredentialExchange(userActivity)
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
                await CloudSync.shared?.sendBeforeQuit()
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
        VaultFilePreviewFolder.shared.removeAll()
        application.finishTermination()
    }
}

/// Launch, for Instruments and the log: from `applicationDidFinishLaunching` to the first window ordered front. The interval is
/// "launch" in the pipeline category, next to `db.open`, `history.reload` and `convlog.load` (`BrowserProfileContext`).
@MainActor
enum LaunchSignpost {
    private static var started: (state: OSSignpostIntervalState, at: ContinuousClock.Instant)?

    static func begin() {
        started = (Pipeline.signposter.beginInterval("launch"), .now)
    }

    /// Ends the interval at the first window shown in front; every later one changes nothing.
    static func windowShown() {
        guard let started else { return }
        self.started = nil
        Pipeline.signposter.endInterval("launch", started.state)
        let elapsed = (ContinuousClock.now - started.at).milliseconds
        Pipeline.log.notice("launch: first window in front after \(elapsed, privacy: .public)ms")
    }
}
