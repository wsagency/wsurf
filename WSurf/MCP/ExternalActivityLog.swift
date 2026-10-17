// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Observation

/// What one external connection did, for the Agent Activity panel.
///
/// The log lives in memory for the app session. It has no storage format on purpose, so nothing here reaches disk. An entry
/// holds a tool name, a tab title, what the call acted on (an element number or a label), a host and counts. It never holds
/// tool arguments, typed text, page content or tool output, so a secret an agent typed cannot reach the log through it.
@MainActor
@Observable
final class ExternalActivityLog: Identifiable {
    struct Entry: Identifiable, Equatable {
        enum Event: Equatable {
            case tool(String)
            /// The user ended the connection with Stop.
            case stopped
        }

        enum Outcome: Equatable {
            case succeeded
            case failed
            /// The connection ended while the call was running.
            case stopped
        }

        let id = UUID()
        let date: Date
        let event: Event
        let tabID: UUID?
        let tabTitle: String?
        /// What the call acted on, such as "element 3". Bounded and stripped of control characters.
        let target: String?
        /// A short, non-sensitive note such as the host a tab was sent to. Bounded and stripped of control characters.
        let detail: String?
        let outcome: Outcome
        let milliseconds: Int
        let bytes: Int
    }

    static let capacity = 1_000
    static let detailLimit = 200
    static let targetLimit = 80
    static let titleLimit = 80

    let id = UUID()
    /// The client's name as the user sees it. The session keeps it current because a client names itself after connecting.
    var client: String
    private(set) var entries: [Entry] = []

    init(client: String = "") {
        self.client = client
    }

    func record(
        tool: String, tab: BrowserTab? = nil, target: String? = nil, outcome: Entry.Outcome, detail: String? = nil,
        milliseconds: Int = 0, bytes: Int = 0
    ) {
        append(
            .init(
                date: Date(), event: .tool(tool), tabID: tab?.id, tabTitle: Self.clean(tab?.title, limit: Self.titleLimit),
                target: Self.clean(target, limit: Self.targetLimit),
                detail: Self.clean(detail, limit: Self.detailLimit), outcome: outcome, milliseconds: milliseconds, bytes: bytes))
    }

    func recordStop() {
        append(
            .init(
                date: Date(), event: .stopped, tabID: nil, tabTitle: nil, target: nil, detail: nil, outcome: .stopped, milliseconds: 0, bytes: 0))
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Entries the panel shows for `tabID`: the ones that name the tab, plus the connection-level ones around them. Empty when
    /// the connection never touched the tab.
    func entries(forTab tabID: UUID) -> [Entry] {
        guard entries.contains(where: { $0.tabID == tabID }) else { return [] }
        return entries.filter { $0.tabID == tabID || $0.tabID == nil }
    }

    /// Text length only: image blocks count their base64 size, which is what the reply line carries.
    static func bytes(of result: CallTool.Result) -> Int {
        result.content.reduce(0) { total, block in
            switch block {
            case .text(let text, _, _):
                total + text.utf8.count
            case .image(let data, _, _, _):
                total + data.utf8.count
            default:
                total
            }
        }
    }

    /// Page titles and notes come from websites. Control characters and newlines would break the one-line rows.
    private static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let trimmed = scalars.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
