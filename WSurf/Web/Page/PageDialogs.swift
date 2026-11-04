// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import WebKit

@MainActor
enum PageDialogs {
    // MARK: - JavaScript dialogs

    /// While an external connection controls the tab, `queue` holds each dialog for that connection first. Without one,
    /// or once the connection lets it go, the sheet below is the only path. It waits until the user can see the tab, and a
    /// page that goes away first gets Cancel.
    static func alert(_ message: String, from frame: WKFrameInfo, over view: NSView, queue: PageDialogQueue? = nil) async {
        let request = PageDialogQueue.Request(kind: .alert, message: message, origin: origin(of: frame))
        _ = await routed(request, via: queue) {
            let alert = makeAlert(message, from: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            _ = await present(alert, over: view, queue: queue)
            return .init(accepted: true)
        }
    }

    static func confirm(_ message: String, from frame: WKFrameInfo, over view: NSView, queue: PageDialogQueue? = nil) async -> Bool {
        let request = PageDialogQueue.Request(kind: .confirm, message: message, origin: origin(of: frame))
        let answer = await routed(request, via: queue) {
            let alert = makeAlert(message, from: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            return .init(accepted: await present(alert, over: view, queue: queue) == .alertFirstButtonReturn)
        }
        return answer?.accepted ?? false
    }

    static func prompt(
        _ message: String,
        defaultText:
            String?,
        from frame: WKFrameInfo,
        over view: NSView,
        queue: PageDialogQueue? = nil
    ) async -> String? {
        let request = PageDialogQueue.Request(kind: .prompt, message: message, origin: origin(of: frame), defaultText: defaultText)
        let answer = await routed(request, via: queue) {
            let alert = makeAlert(message, from: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard await present(alert, over: view, queue: queue) == .alertFirstButtonReturn else { return .init(accepted: false) }
            return .init(accepted: true, text: field.stringValue)
        }
        guard let answer, answer.accepted else { return nil }
        return answer.text ?? ""
    }

    /// Asks `queue` to hold `request` for a controlling connection, else runs `native` at once.
    static func routed(
        _ request: PageDialogQueue.Request,
        via queue: PageDialogQueue?,
        native: @MainActor () async -> PageDialogQueue.Answer
    ) async -> PageDialogQueue.Answer? {
        guard let queue, queue.isIntercepting else { return await native() }
        return await queue.run(request, native: native)
    }

    private static func origin(of frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        return PageDialogText.origin(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    // MARK: - File upload

    static func chooseFiles(
        _ parameters: PageFileSelection.Parameters,
        in window: NSWindow?,
        onPanel: ((NSOpenPanel) -> Void)? = nil
    ) async -> [URL]? {
        guard let window else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        onPanel?(panel)
        return await presentFilePanel(panel, in: window)
    }

    static func presentFilePanel(_ panel: NSSavePanel, in window: NSWindow?) async -> [URL]? {
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else {
                    continuation.resume(returning: nil)
                    return
                }
                if let open = panel as? NSOpenPanel {
                    continuation.resume(returning: open.urls)
                } else {
                    continuation.resume(returning: panel.url.map { [$0] })
                }
            }
        }
    }

    // MARK: - Building blocks

    private static func makeAlert(_ message: String, from frame: WKFrameInfo) -> NSAlert {
        let host = frame.securityOrigin.host
        let alert = NSAlert()
        alert.messageText = host.isEmpty
            ? String(localized: "A message from this page")
            : String(localized: "A message from “\(host)”")
        alert.informativeText = capped(message)
        return alert
    }

    static func capped(_ text: String, limit: Int = 1500) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Shows `alert` on the window of `view`'s page once the user can see its tab (`PageDialogQueue.untilShown`), so it never
    /// covers another tab; without a tab's queue, at once. Nil, and nothing shown, when the page went away or was sent
    /// elsewhere first, or has no window.
    static func present(_ alert: NSAlert, over view: NSView?, queue: PageDialogQueue?) async -> NSApplication.ModalResponse? {
        guard let view else { return nil }
        let window: NSWindow?
        if let queue {
            window = await queue.untilShown(view)
        } else {
            window = view.window
        }
        guard let window else { return nil }
        return await present(alert, in: window)
    }

    static func present(_ alert: NSAlert, in window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
