// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// The Passwords window: the page of Settings › Autofill (`CredentialSettings`) in a window of its own, so the vault can be opened
/// without a browser window. There is one; later requests bring it to the front. It is native and outside every tab, so no page,
/// assistant or connected app can open or read it.
///
/// Its content is built on each open and dropped when the window closes: SwiftUI's `onDisappear` does not reliably run when an
/// `NSWindow` closes, and the page's `onDisappear` is what forgets the unlocked session (`CredentialSettingsModel.close()`).
@MainActor
final class PasswordsWindow: NSObject, NSWindowDelegate {
    /// A test swaps it for a window with its own content, so the menu's ⌥⌘K and ⌘W can be driven without opening a vault.
    static var shared = PasswordsWindow()
    /// The window ⌘W and its menu item act on. A test swaps it: a test host in the background never has a key window.
    static var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    nonisolated static let frameAutosaveName = "WSurfPasswordsWindow"
    static let defaultContentSize = NSSize(width: 760, height: 640)
    static let minimumContentSize = NSSize(width: 560, height: 480)

    private let profiles: ProfileStore
    private let makeContent: (Profile) -> NSViewController
    private let autosaveName: String?
    private(set) var window: NSWindow?
    /// The profile the content is bound to. A profile switch locks the profile being left, so `show()` rebinds when it changed.
    private(set) var boundProfileID: UUID?

    /// The parameters are seams for tests, which must not open a real vault or write the window's frame to the preferences.
    init(
        profiles: ProfileStore = .shared,
        autosaveName: String? = PasswordsWindow.frameAutosaveName,
        makeContent: @escaping (Profile) -> NSViewController = { profile in
            let controller = NSHostingController(rootView: PasswordsWindowContent(profile: profile))
            // The window's size is the person's (and the autosaved frame's), not what the page asks for.
            controller.sizingOptions = []
            return controller
        }
    ) {
        self.profiles = profiles
        self.autosaveName = autosaveName
        self.makeContent = makeContent
        super.init()
    }

    /// Any Passwords window, found by its delegate, so the menu needs no reference to the one in use.
    static func isPasswordsWindow(_ window: NSWindow?) -> Bool {
        window?.delegate is PasswordsWindow
    }

    /// The profile whose vault the window shows: never a private one, which keeps no vault.
    var profile: Profile {
        profiles.isPrivate ? profiles.profileToReturnTo : profiles.current
    }

    /// Opens the window, or brings it to the front. Opens no browser window and never goes through `MainMenu.coordinator`.
    func show() {
        let shown = profile
        let window = window ?? makeWindow()
        if window.contentViewController == nil || boundProfileID != shown.id {
            // Setting the content resizes a window to it; keep the frame the window has.
            let frame = window.frame
            window.contentViewController = makeContent(shown)
            window.setFrame(frame, display: false)
            boundProfileID = shown.id
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        boundProfileID = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Passwords")
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .normal
        window.contentMinSize = Self.minimumContentSize
        if let autosaveName {
            if !window.setFrameUsingName(autosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(autosaveName)
        } else {
            window.center()
        }
        self.window = window
        return window
    }
}
