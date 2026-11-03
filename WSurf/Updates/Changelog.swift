// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// One WSurf release in `CHANGELOG.md`: its heading `## 0.1.12 (build 12) — 2026-10-24` and the Markdown under it.
nonisolated struct ChangelogSection: Equatable, Identifiable, Sendable {
    let version: String
    let build: Int
    /// Nil for a heading without a date, such as the first one, `## 0.1.0 (build 1)`.
    let date: Date?
    /// Everything under the heading up to the next `##` heading, without the blank lines around it.
    let body: String

    var id: String {
        version
    }

    /// The heading as the file writes it, without the date.
    var title: String {
        "\(version) (build \(build))"
    }
}

/// The release notes WSurf ships: the `## <version> (build <n>)` sections of `CHANGELOG.md`, which the app bundles as a
/// resource. `Tools/check-changelog.sh` guarantees every build has its section, and the file's own order is newest first.
///
/// The file also holds what comes before WSurf's sections (a comment and the provenance paragraph) and, after them, the
/// notes inherited from Linen under `## Upstream Linen history`. Those are not WSurf releases: reading stops at the first
/// `##` heading that is not a WSurf section, which keeps Linen's own `## 0.1.1` and `## 0.1.0` out as well.
nonisolated enum Changelog {
    static let resource = "CHANGELOG"
    static let fileExtension = "md"

    /// The text of the bundled `CHANGELOG.md`, or nil when the app was built without it.
    static func bundledText(in bundle: Bundle = .main) -> String? {
        bundle.url(forResource: resource, withExtension: fileExtension)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// What the notes page shows for `installed`: that version's section and the older ones below it. A build whose
    /// version has no section (a development build) shows the newest section, and the older ones below it.
    static func sections(in markdown: String, installed version: String) -> [ChangelogSection] {
        let all = sections(in: markdown)
        guard let index = all.firstIndex(where: { $0.version == version }) else { return all }
        return Array(all[index...])
    }

    /// Every WSurf section, newest build first.
    static func sections(in markdown: String) -> [ChangelogSection] {
        var found: [ChangelogSection] = []
        var current: (heading: Heading, lines: [String])?
        var isFenced = false

        func close() {
            guard let current else { return }
            let body = current.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(ChangelogSection(
                version: current.heading.version,
                build: current.heading.build,
                date: current.heading.date,
                body: body
            ))
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                isFenced.toggle()
            }
            if !isFenced, line.hasPrefix("## ") {
                guard let heading = Heading(line) else {
                    // The first heading that is not a WSurf section is where the inherited notes begin.
                    break
                }
                close()
                current = (heading, [])
                continue
            }
            current?.lines.append(line)
        }
        close()
        return found.sorted { $0.build > $1.build }
    }

    /// `## 0.1.12 (build 12) — 2026-10-24`, the date optional.
    private nonisolated struct Heading {
        let version: String
        let build: Int
        let date: Date?

        init?(_ line: String) {
            let text = line.dropFirst(3)
            guard let open = text.range(of: " (build "),
                  let close = text[open.upperBound...].firstIndex(of: ")"),
                  let build = Int(text[open.upperBound..<close]) else { return nil }
            let version = String(text[..<open.lowerBound])
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
                return nil
            }
            self.version = version
            self.build = build

            let tail = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if tail.hasPrefix("—") {
                date = Self.day(String(tail.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                date = nil
            }
        }

        private static func day(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: text)
        }
    }
}
