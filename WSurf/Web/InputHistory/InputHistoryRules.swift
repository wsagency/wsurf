// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What Input History may keep, as pure functions. The page script applies the same rules first. Native code applies them again
/// because a message from a page process is never trusted.
nonisolated enum InputHistoryRules {
    /// Commits one page may make in one window. Typing and leaving fields stay far below it, and a flood cannot push real
    /// entries out of the store.
    static let commitBudget = 60
    static let commitWindow: Duration = .seconds(10)

    /// A page or frame where text may be kept: http or https, with a host. Credentials, query and fragment are not part of it.
    nonisolated struct Address: Equatable, Sendable {
        let origin: String
        let host: String
        let path: String

        var location: String {
            origin + path
        }
    }

    static func address(_ url: URL?) -> Address? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let standard = scheme == "https" ? 443 : 80
        let shown = host.contains(":") ? "[\(host)]" : host
        let port = url.port.flatMap { $0 == standard ? nil : $0 }.map { ":\($0)" } ?? ""
        let path = url.path(percentEncoded: true)
        return Address(origin: "\(scheme)://\(shown)\(port)", host: host, path: path.isEmpty ? "/" : path)
    }

    /// Whether the frame WebKit or Chromium reported is the one `url` names. Default ports count as unset.
    static func matches(_ origin: BrowserSecurityOrigin, _ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", origin.protocol == scheme,
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty, origin.host == host else { return false }
        let standard = scheme == "https" ? 443 : 80
        return (origin.port == 0 ? standard : origin.port) == (url.port ?? standard)
    }

    // MARK: - Excluded sites

    /// Host names from what the person listed. A line may be a host, a host with a path or port, or a whole address.
    static func excludedHosts(_ entries: [String]) -> [String] {
        entries.compactMap { entry in
            var text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let range = text.range(of: "://") {
                text = String(text[range.upperBound...])
            }
            text = String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
            if let at = text.lastIndex(of: "@") {
                text = String(text[text.index(after: at)...])
            }
            if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                // A host as URLs report it has no brackets.
                text = String(text[text.index(after: text.startIndex)..<close])
            } else if let colon = text.firstIndex(of: ":") {
                text = String(text[..<colon])
            }
            while text.hasPrefix("*.") || text.hasPrefix(".") {
                text.removeFirst(text.hasPrefix("*.") ? 2 : 1)
            }
            while text.hasSuffix(".") {
                text.removeLast()
            }
            return text.isEmpty ? nil : text
        }
    }

    /// A listed host also covers its subdomains, on a dot boundary: `example.test` covers `www.example.test`, not `badexample.test`.
    static func isExcluded(_ host: String, by hosts: [String]) -> Bool {
        let host = host.lowercased()
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Card numbers

    /// 13 to 19 digits that pass the card number check, with spaces and dashes ignored. Card numbers belong to the card vault.
    static func looksLikeCardNumber(_ text: String) -> Bool {
        guard text.utf8.count <= 40 else { return false }
        return PaymentCard.isValidNumber(text.filter { $0 != " " && $0 != "-" })
    }

    // MARK: - Messages

    /// One commit from the page script, checked for shape and size. A commit with a value is never printed: its description hides it.
    nonisolated struct Commit: CustomStringConvertible, CustomDebugStringConvertible {
        let documentID: String
        let url: URL
        let title: String
        let field: String
        let kind: InputHistoryPayload.Kind
        let label: String
        let value: String
        let username: String?
        let cleared: Bool

        var description: String {
            "InputHistoryCommit(\(kind.rawValue), redacted)"
        }

        var debugDescription: String {
            description
        }

        /// Coalescing key: one field of one document.
        var key: String {
            "\(documentID)#\(field)"
        }
    }

    /// Sizes are bounded before anything is copied or measured by grapheme. Nothing here trusts the page.
    static func commit(from body: [String: Any]) -> Commit? {
        guard let documentID = body["documentID"] as? String, documentID.utf8.count == 36, UUID(uuidString: documentID) != nil,
              let raw = body["url"] as? String, raw.utf8.count <= 4_096, let url = URL(string: raw),
              let field = body["field"] as? String, (1...9).contains(field.utf8.count), field.utf8.allSatisfy({ (48...57).contains($0) }), field != "0",
              let kindName = body["kind"] as? String, let kind = InputHistoryPayload.Kind(rawValue: kindName),
              let value = body["value"] as? String, value.utf8.count <= InputHistoryLimits.value * 4,
              let cleared = body["cleared"] as? Bool, cleared == value.isEmpty else { return nil }
        let title = body["title"] as? String ?? ""
        let label = body["label"] as? String ?? ""
        let username = body["username"] as? String ?? ""
        guard title.utf8.count <= InputHistoryLimits.title * 8, label.utf8.count <= InputHistoryLimits.label * 8,
              username.utf8.count <= InputHistoryLimits.username * 4 else { return nil }
        return Commit(
            documentID: documentID, url: url, title: title, field: field, kind: kind, label: label, value: value,
            username: username.isEmpty ? nil : username, cleared: cleared
        )
    }
}
