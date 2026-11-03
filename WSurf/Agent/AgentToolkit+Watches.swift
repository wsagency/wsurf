// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

/// Page watches for the in-app assistant only: connected apps have no path to them. A watch starts only after the person's yes
/// in the trusted sheet, asked every time, and the limit of twenty holds whatever the assistant asks.
extension AgentToolkit {
    func watchPage(condition rawCondition: String, everyMinutes: Int) async -> String {
        let condition = rawCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        let step = beginTool(name: "watchPage", title: AgentDiagnosticPrivacy.title(for: "watchPage"))
        if let output = cancellationOutput(for: step) {
            return output
        }
        func fail(_ output: String) -> String {
            completeTool(step, output: output, failed: true)
            return output
        }
        guard let center = browserContext.pageWatches else {
            return fail("Private windows can’t watch pages. Tell the person to ask again in a regular window.")
        }
        guard center.isScheduling else {
            return fail(AppDatabase.ownsSession
                ? "This profile can’t watch pages right now."
                : "Another copy of WSurf is running, so this one can’t watch pages. Tell the person to ask in the other copy.")
        }
        guard let view = targetWebView, let url = view.url, PageWatchReader.canWatch(url) else {
            return fail("Open the page to watch first. Only websites can be watched.")
        }
        let permissions = browserContext.sitePermissions
        if let refusal = center.refusal(url: url, condition: condition) {
            return fail(output(for: refusal, showsState: false))
        }
        guard permissions.assistantAccess(for: SitePermissions.origin(for: url)) != .deny else {
            return fail(output(for: .denied, showsState: false))
        }
        guard condition.isEmpty || PageWatchJudge.isAvailable else {
            return fail(output(for: .noModel, showsState: false))
        }
        let request = PageWatchRequest(
            url: url,
            title: view.title ?? "",
            condition: condition,
            minutes: everyMinutes,
            readsWithWebKitInstead: PageWatchReader.readsWithWebKitInstead(url, permissions: permissions)
        )
        guard let answer = await AgentActionConsent.permitWatch(request) else {
            if let output = cancellationOutput(for: step) {
                return output
            }
            return fail("The person didn’t agree to watch this page. Don’t ask again unless they do.")
        }
        let started = await PageWatchCreation.start(answer, in: center)
        if let output = cancellationOutput(for: step) {
            if case .watching(let watch) = started {
                center.stop(watch.id)
            }
            return output
        }
        let result = output(for: started, showsState: Self.showsState(of: url, in: permissions))
        guard case .watching = started else { return fail(result) }
        completeTool(step, output: result)
        return result
    }

    func listWatches() -> String {
        let step = beginTool(name: "listWatches", title: AgentDiagnosticPrivacy.title(for: "listWatches"))
        if let output = cancellationOutput(for: step) {
            return output
        }
        let watches = browserContext.pageWatches?.watches ?? []
        let permissions = browserContext.sitePermissions
        let output = browserContext.pageWatches == nil
            ? "Private windows have no page watches."
            : watches.isEmpty ? "No pages are being watched." : watches.map { describe($0, permissions: permissions) }.joined(separator: "\n")
        completeTool(step, output: output)
        return output
    }

    func stopWatch(matching reference: String) -> String {
        let step = beginTool(name: "stopWatch", title: AgentDiagnosticPrivacy.title(for: "stopWatch"))
        if let output = cancellationOutput(for: step) {
            return output
        }
        func fail(_ output: String) -> String {
            completeTool(step, output: output, failed: true)
            return output
        }
        guard let center = browserContext.pageWatches else { return fail("Private windows have no page watches.") }
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail("Pass a watch ID, or part of the page title, address or condition.")
        }
        let matches = center.matching(reference)
        guard let watch = matches.first else { return fail("No watch matches. Use listWatches to see them.") }
        guard matches.count == 1 else {
            let permissions = browserContext.sitePermissions
            return fail("More than one watch matches. Pass a watch ID:\n" + matches.map { describe($0, permissions: permissions) }.joined(separator: "\n"))
        }
        center.stop(watch.id)
        let output = "Stopped watching \(watch.place)."
        completeTool(step, output: output)
        return output
    }

    /// A watch's title and last state are page text: they reach the chat model, which may be a cloud model, only where the site
    /// lets the assistant read, and always fenced like any page text the assistant reads.
    private static func showsState(of url: URL, in permissions: SitePermissions) -> Bool {
        [AssistantAccessPolicy.readOnly, .control].contains(permissions.assistantAccess(for: SitePermissions.origin(for: url)))
    }

    private func output(for start: PageWatchCenter.Start, showsState: Bool) -> String {
        switch start {
        case .watching(let watch):
            let now = showsState ? watch.state.map { "Now:\n" + fencedPageOutput($0) + "\n" } ?? "" : ""
            let access = watch.access == .signedIn ? "with the person’s sign-ins" : "without the person’s sign-ins"
            return """
                Watching \(watch.place) every \(Self.interval(watch.period)), \(access). Watch ID: \(watch.id.uuidString)
                Waiting for: \(watch.condition.isEmpty ? "any change to the main content" : watch.condition)
                \(now)The person gets one notification when it happens, and then the watch ends. WSurf checks the page only \
                while it is open, on this Mac. The watch also ends after 30 days.
                """
        case .alreadyMet(let verdict):
            return "No watch was set: the page already shows it." + (showsState ? "\n" + fencedPageOutput(verdict.message) : "")
        case .unreadable:
            return "WSurf couldn’t read this page in the background, so it can’t watch it."
        case .noModel:
            return "Waiting for something specific needs Apple Intelligence on this Mac, which isn’t available. Offer to watch for any change instead."
        case .undecided:
            return "Apple Intelligence couldn’t check this page right now, so no watch was set. Tell the person to try again later."
        case .duplicate(let existing):
            return "Already watching this page for that. Watch ID: \(existing.id.uuidString)"
        case .full:
            return "WSurf watches up to \(PageWatch.limit) pages. Ask the person which watch to stop first."
        case .denied:
            return "The person set this website to No Access for the assistant, so it can’t be watched."
        }
    }

    private func describe(_ watch: PageWatch, permissions: SitePermissions) -> String {
        let condition = watch.condition.isEmpty ? "any change" : watch.condition
        let status = watch.isPausedByPerson ? " Paused by the person." : watch.isUnreachable ? " Paused: the page can’t be read." : ""
        var page = ""
        if Self.showsState(of: watch.url, in: permissions) {
            if !watch.title.isEmpty {
                page += " Title:\n" + fencedPageOutput(watch.title)
            }
            if let state = watch.state {
                page += " Last seen:\n" + fencedPageOutput(state)
            }
        }
        return "[\(watch.id.uuidString)] \(watch.place) (\(watch.url.absoluteString)), every \(Self.interval(watch.period)), "
            + "waiting for: \(condition).\(status)\(page)"
    }

    private static func interval(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 60 else { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "hour" : "\(hours) hours"
    }
}
