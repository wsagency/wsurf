// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import OSLog

/// "Open In" in the Developer Tools menu: hands the page's address to another browser. The address leaves WSurf, with its
/// query, so two rules hold wherever it is offered or used:
/// - never from a private window, which promises that nothing about the page leaves it;
/// - never to a WSurf build. A Stage, development or test build must not hand an address to the installed WSurf, whose
///   profiles and history are the person's own, so every `io.wsagency.wsurf*` identifier is left out, and the running
///   build's own identifier too.
nonisolated enum DevModeOpenIn {
    static let ownIdentifierPrefix = "io.wsagency.wsurf"

    /// True for any build of WSurf. An application without an identifier cannot be told apart, so it counts as one.
    static func isOwn(_ identifier: String?, running: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let identifier = identifier?.lowercased(), !identifier.isEmpty else { return true }
        return identifier.hasPrefix(ownIdentifierPrefix) || identifier == running?.lowercased()
    }

    /// The address that may leave WSurf: an http(s) address with a host, from a window that is not private. Nil otherwise.
    static func shareableURL(_ address: String, isPrivate: Bool) -> URL? {
        guard !isPrivate, let url = URL(string: address), DevMode.host(of: url) != nil else { return nil }
        return url
    }

    /// One entry per application, WSurf's own builds left out, in the order a person reads names.
    static func browsers(
        among applications: [URL],
        identifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        name: (URL) -> String = { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) }
    ) -> [URL] {
        var seen = Set<String>()
        return applications
            .filter { application in
                guard let id = identifier(application), !isOwn(id) else { return false }
                return seen.insert(id.lowercased()).inserted
            }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// The browsers the system offers for a web address. Empty in a private window, which offers none.
    static func installedBrowsers(isPrivate: Bool) -> [URL] {
        guard !isPrivate, let probe = URL(string: "https://example.com") else { return [] }
        return browsers(among: NSWorkspace.shared.urlsForApplications(toOpen: probe))
    }

    /// Opens `address` in `browser` unless a rule above forbids it. Returns whether it was handed over. `identifier` and `hand`
    /// are the system's answers, replaced in tests.
    @discardableResult
    @MainActor
    static func open(
        _ address: String,
        isPrivate: Bool,
        in browser: URL,
        identifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        hand: (URL, URL) -> Void = { url, browser in
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    DevMode.log.notice("Open In failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    ) -> Bool {
        guard let url = shareableURL(address, isPrivate: isPrivate),
              !isOwn(identifier(browser))
        else { return false }
        hand(url, browser)
        return true
    }
}
