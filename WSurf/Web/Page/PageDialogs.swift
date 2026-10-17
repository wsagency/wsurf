// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import WebKit

@MainActor
enum PageDialogs {
    // MARK: - JavaScript dialogs

    /// While an external connection controls the tab, `queue` holds each dialog for that connection first. Without one,
    /// or once the connection lets it go, the sheet below is the only path.
    static func alert(_ message: String, from frame: WKFrameInfo, in window: NSWindow?, queue: PageDialogQueue? = nil) async {
        guard let window else { return }
        let request = PageDialogQueue.Request(kind: .alert, message: message, origin: origin(of: frame))
        _ = await routed(request, via: queue) {
            let alert = makeAlert(message, from: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            _ = await present(alert, in: window)
            return .init(accepted: true)
        }
    }

    static func confirm(_ message: String, from frame: WKFrameInfo, in window: NSWindow?, queue: PageDialogQueue? = nil) async -> Bool {
        guard let window else { return false }
        let request = PageDialogQueue.Request(kind: .confirm, message: message, origin: origin(of: frame))
        let answer = await routed(request, via: queue) {
            let alert = makeAlert(message, from: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            return .init(accepted: await present(alert, in: window) == .alertFirstButtonReturn)
        }
        return answer?.accepted ?? false
    }

    static func prompt(
        _ message: String,
        defaultText:
            String?,
        from frame: WKFrameInfo,
        in window: NSWindow?,
        queue: PageDialogQueue? = nil
    ) async -> String? {
        guard let window else { return nil }
        let request = PageDialogQueue.Request(kind: .prompt, message: message, origin: origin(of: frame), defaultText: defaultText)
        let answer = await routed(request, via: queue) {
            let alert = makeAlert(message, from: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard await present(alert, in: window) == .alertFirstButtonReturn else { return .init(accepted: false) }
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

    static func present(_ alert: NSAlert, in window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
