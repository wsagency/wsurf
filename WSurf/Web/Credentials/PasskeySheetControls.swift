// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// The Touch ID control on the passkey sheet: the sheet names the site and the passkey, and this one biometric
/// answers it, with no system dialog. Its context is new for this sheet, has no reuse window and ends with the sheet, so an
/// unlock or an earlier sign-in never stands in for it. A Mac with no usable sensor gets `nil` and the sheet's button.
@MainActor
final class PasskeySheetTouch: NSObject {
    /// How long a sheet that follows an unlock waits before it listens: a finger still resting on the sensor answers nothing.
    static let afterUnlockDelay: Duration = .milliseconds(700)
    /// The one sheet listening, across all windows: two sheets must never share a touch.
    private static weak var listening: PasskeySheetTouch?

    let view: LAAuthenticationView
    /// True only when this sheet's own evaluation just succeeded.
    private(set) var verified = false
    private let context: LAContext
    private let appIsActive: () -> Bool
    private var ended = false
    private let chooser: NSPopUpButton?
    private let reason: String
    private var started = false
    private var sheet: NSWindow?
    private var anchor: NSWindow?

    init?(
        chooser: NSPopUpButton?, reason: String, context: LAContext = LAContext(), appIsActive: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.context = context
        self.appIsActive = appIsActive
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        view = LAAuthenticationView(context: context, controlSize: .regular)
        self.chooser = chooser
        self.reason = reason
        super.init()
        chooser?.target = self
        chooser?.action = #selector(chooserChanged)
    }

    func begin(sheet: NSWindow, on anchor: NSWindow, after delay: Duration) async {
        try? await Task.sleep(for: delay)
        guard !ended else { return }
        self.sheet = sheet
        self.anchor = anchor
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(stopListening), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(stopListening), name: NSWindow.didResignKeyNotification, object: sheet)
        center.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        evaluate()
    }

    /// Final: a sheet that lost the user's attention stays on its button, and the system's verification follows that.
    func end() {
        guard !ended else { return }
        ended = true
        context.invalidate()
        if Self.listening === self {
            Self.listening = nil
        }
    }

    @objc private func stopListening() {
        end()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window !== sheet, window !== anchor {
            end()
        }
    }

    @objc private func chooserChanged() {
        evaluate()
    }

    /// Waits for a passkey to be picked when several match: a touch may only ever answer for a passkey the sheet is showing. It
    /// stays off unless this is the app, the window (or its sheet, which takes the key from it) and the only sheet the user is
    /// at, where a touch can only be meant for this. One try per sheet: after a failure the button remains, and with it the
    /// system's verification.
    private func evaluate() {
        guard !started, !ended, appIsActive(), Self.listening == nil, let sheet, let anchor,
              anchor.isKeyWindow || sheet.isKeyWindow else { return }
        if let chooser, case .declined = NativeWebAuthnInteraction.decision(from: chooser) {
            return
        }
        started = true
        Self.listening = self
        nonisolated(unsafe) let context = context
        Task { [reason] in
            let touched = (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true
            guard touched, !ended else {
                end()
                return
            }
            verified = true
            anchor.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
    }
}

extension AutofillSuggestions {
    /// A page can focus a field by script and so put the panel under a pointer about to click something else, and the "Use a
    /// Passkey…" row can lead straight to a system sheet that names no site. It answers only once it has been up long enough to read.
    static func passkeyRowIsArmed(since shown: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Bool {
        shown.duration(to: now) >= .milliseconds(500)
    }
}

/// Find on the passkey sheet: searches the vault's other passkeys and says they cannot sign in here. It only reads: WebAuthn binds
/// a passkey to its relying party, so nothing it lists can be chosen. Every passkey that can answer is already on the sheet.
@MainActor
final class PasskeyFindField: NSObject, NSSearchFieldDelegate {
    let view = NSStackView()
    private let others: [WebAuthnPromptOther]
    private let field = NSSearchField()
    private let results = NSTextField(wrappingLabelWithString: "")
    private static let shownLines = 3

    init?(_ others: [WebAuthnPromptOther]) {
        guard !others.isEmpty else { return nil }
        self.others = others
        super.init()
        field.placeholderString = String(localized: "Find a passkey…")
        field.delegate = self
        results.font = .preferredFont(forTextStyle: .caption1)
        results.textColor = .secondaryLabelColor
        results.maximumNumberOfLines = Self.shownLines
        // The alert does not resize while it is up, so the lines are reserved from the start.
        results.heightAnchor.constraint(equalToConstant: CGFloat(Self.shownLines) * 16).isActive = true
        results.widthAnchor.constraint(equalToConstant: 360).isActive = true
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view.orientation = .vertical
        view.alignment = .leading
        view.addArrangedSubview(field)
        view.addArrangedSubview(results)
    }

    func controlTextDidChange(_ notification: Notification) {
        results.stringValue = Self.text(others, query: field.stringValue)
    }

    /// Return in the search must not press the sheet's default button.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        selector == #selector(NSResponder.insertNewline(_:))
    }

    static func matches(_ others: [WebAuthnPromptOther], query: String) -> [WebAuthnPromptOther] {
        others.filter { [$0.title, $0.userName, $0.rpID].contains { $0.localizedStandardContains(query) } }
    }

    static func text(_ others: [WebAuthnPromptOther], query: String) -> String {
        guard !query.isEmpty else { return "" }
        let found = matches(others, query: query)
        guard !found.isEmpty else { return String(localized: "No other passkey matches.") }
        let lines = found.prefix(shownLines - 1).map { "\($0.title) · \($0.userName) — \($0.rpID)" }
        return (lines + [String(localized: "Can’t sign in here: a passkey works only for the website it was made for.")])
            .joined(separator: "\n")
    }
}
