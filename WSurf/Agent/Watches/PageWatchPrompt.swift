// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// What the person is asked to agree to before a page is watched. The sheet lets them change what to wait for, how often to
/// check, and whether this one watch uses their sign-ins.
nonisolated struct PageWatchRequest: Equatable, Sendable {
    let url: URL
    var title: String
    var condition: String
    var minutes: Int
    var access: PageWatch.Access = .anonymous
    /// The site is set to Chromium; the watch reads it with WebKit, without the Chromium sign-ins.
    let readsWithWebKitInstead: Bool

    var place: String {
        PageWatch.place(of: url)
    }
}

/// The trusted sheet for a new watch: native UI that a page cannot draw or click.
@MainActor
enum PageWatchPrompt {
    static let choices = [15, 60, 360, 1440]

    /// The intervals the sheet offers, with the one asked for among them.
    static func minutes(including asked: Int) -> [Int] {
        let clamped = Int(PageWatch.interval(minutes: asked) / 60)
        return Set(choices + [clamped]).sorted()
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case 1440:
            String(localized: "Every day")
        case 60:
            String(localized: "Every hour")
        case let value where value % 60 == 0:
            String(localized: "Every \(value / 60) hours")
        default:
            String(localized: "Every \(minutes) minutes")
        }
    }

    static func explanation(for request: PageWatchRequest, fromAssistant: Bool) -> String {
        var parts = [String]()
        parts.append(String(localized: """
            WSurf reads this page in the background while it’s open and tells you once. The page is judged on this Mac, never \
            by an online model. A watch ends after 30 days.
            """))
        parts.append(String(localized: "Without your sign-ins, WSurf reads the page as a visitor would."))
        if request.readsWithWebKitInstead {
            parts.append(String(localized: PageWatchReader.webKitNote))
        }
        if fromAssistant {
            parts.append(String(localized: "The assistant asked for this watch. Webpages can carry hidden instructions aimed at the assistant. Allow this only if it’s what you asked for."))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The person's answer, or nil when they cancel. Never shown in automated tests.
    static func ask(_ request: PageWatchRequest, in window: NSWindow, fromAssistant: Bool) async -> PageWatchRequest? {
        guard !AgentActionConsent.isRunningTests, !Task.isCancelled else { return nil }
        let width: CGFloat = 300
        let condition = NSTextField(frame: NSRect(x: 0, y: 58, width: width, height: 24))
        condition.stringValue = request.condition
        condition.placeholderString = String(localized: "Waiting for: any change")
        condition.setAccessibilityLabel(String(localized: "What you’re waiting for"))
        let offered = minutes(including: request.minutes)
        let interval = NSPopUpButton(frame: NSRect(x: 0, y: 26, width: width, height: 26), pullsDown: false)
        interval.addItems(withTitles: offered.map(label(minutes:)))
        interval.selectItem(at: offered.firstIndex(of: Int(PageWatch.interval(minutes: request.minutes) / 60)) ?? 0)
        interval.setAccessibilityLabel(String(localized: "How often to check"))
        let signIns = NSButton(checkboxWithTitle: String(localized: "Use my sign-ins for this page"), target: nil, action: nil)
        signIns.frame = NSRect(x: 0, y: 0, width: width, height: 20)
        signIns.state = request.access == .signedIn ? .on : .off
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 82))
        for field in [condition, interval, signIns] as [NSView] {
            fields.addSubview(field)
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Watch \(request.place)?")
        alert.informativeText = explanation(for: request, fromAssistant: fromAssistant)
        alert.accessoryView = fields
        alert.addButton(withTitle: String(localized: "Watch"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = condition
        let response = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return NSApplication.ModalResponse.abort }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in window.endSheet(alert.window, returnCode: .abort) }
        }
        guard !Task.isCancelled, response == .alertFirstButtonReturn else { return nil }
        var answer = request
        answer.condition = condition.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        answer.minutes = offered[max(interval.indexOfSelectedItem, 0)]
        answer.access = signIns.state == .on ? .signedIn : .anonymous
        return answer
    }
}

extension AgentActionConsent {
    struct WatchStub: @unchecked Sendable {
        let decide: @MainActor (PageWatchRequest) async -> PageWatchRequest?
    }

    @TaskLocal static var watchDecisionForTesting: WatchStub?

    /// The assistant watches a page only after the person's yes in the trusted sheet, asked every time: no answer is
    /// remembered and there is no "always allow". Nil when they decline, the task ends, or the window changed meanwhile.
    static func permitWatch(_ request: PageWatchRequest) async -> PageWatchRequest? {
        guard !Task.isCancelled, hasCurrentWindow else { return nil }
        let window = scopedWindow?.nativeWindow
        let answer: PageWatchRequest?
        if let stub = watchDecisionForTesting {
            answer = await stub.decide(request)
        } else {
            guard let window else { return nil }
            answer = await PageWatchPrompt.ask(request, in: window, fromAssistant: true)
        }
        guard !Task.isCancelled, hasCurrentWindow, scopedWindow?.nativeWindow === window else { return nil }
        return answer
    }
}

/// What follows the person's yes, from the menu or the assistant.
@MainActor
enum PageWatchCreation {
    /// A condition needs Apple Intelligence on this Mac. Notifications are asked for here, in context, before the first reading.
    static func start(_ request: PageWatchRequest, in center: PageWatchCenter) async -> PageWatchCenter.Start {
        if let refusal = center.refusal(url: request.url, condition: request.condition) {
            return refusal
        }
        guard request.condition.isEmpty || PageWatchJudge.isAvailable else { return .noModel }
        _ = await NotificationBridge.shared.requestAlerts()
        return await center.start(
            url: request.url,
            title: request.title,
            condition: request.condition,
            everyMinutes: request.minutes,
            access: request.access
        )
    }

    /// The window's notice after the person asked from the menu.
    static func notice(for start: PageWatchCenter.Start) -> String {
        switch start {
        case .watching(let watch):
            String(localized: "Watching \(watch.place).")
        case .alreadyMet:
            String(localized: "The page already shows that, so no watch was set.")
        case .unreadable:
            String(localized: "WSurf couldn’t read this page in the background, so it can’t watch it.")
        case .noModel:
            String(localized: "Waiting for something specific needs Apple Intelligence on this Mac. Leave it empty to watch for any change.")
        case .undecided:
            String(localized: "Apple Intelligence couldn’t check this page right now. Try again later.")
        case .duplicate:
            String(localized: "This page is already watched for that.")
        case .full:
            String(localized: "WSurf watches up to \(PageWatch.limit) pages. Stop one in the Watches tab first.")
        case .denied:
            String(localized: "This website’s Assistant Access is No Access, so WSurf doesn’t read it.")
        }
    }
}
