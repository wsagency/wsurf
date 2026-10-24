// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

enum SiteName {
    private static let genericSuffixes: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]

    static func name(forHost host: String) -> String {
        var parts = host.lowercased().split(separator: ".").map(String.init)
        if parts.first == "www" {
            parts.removeFirst()
        }
        guard parts.count > 1 else { return parts.first ?? host }

        var suffixLength = 1
        if parts.count > 2,
           parts[parts.count - 1].count == 2,
           genericSuffixes.contains(parts[parts.count - 2]) {
            suffixLength = 2
        }
        return parts[max(0, parts.count - suffixLength - 1)]
    }

    /// What counts as one website: `news.ycombinator.com` and
    /// `www.ycombinator.com` are both `ycombinator.com`.
    static func domain(forHost host: String) -> String {
        var parts = host.lowercased().split(separator: ".").map(String.init)
        if parts.first == "www" {
            parts.removeFirst()
        }
        guard parts.count > 1 else { return parts.first ?? host.lowercased() }

        var keep = 2
        if parts.count > 2,
           parts[parts.count - 1].count == 2,
           genericSuffixes.contains(parts[parts.count - 2]) {
            keep = 3
        }
        return parts.suffix(keep).joined(separator: ".")
    }

    static func title(forHost host: String) -> String {
        let name = name(forHost: host)
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

struct RemoteSiteBadge: View {
    let host: String
    let size: CGFloat

    @Environment(\.profileFavicons) private var profileFavicons
    /// An icon read from the disk or fetched, with the lookup it answers, so a row reused for another site does not wear this one's.
    @State private var loaded: (lookup: String, icon: NSImage)?

    private var lookup: String {
        "\(host)|\(profileFavicons.map { String(describing: ObjectIdentifier($0)) } ?? "")"
    }

    var body: some View {
        // A row whose icon is in memory draws it with no task of its own: a long list starts none for the icons it already has.
        if let icon = profileFavicons?.memoryCached(for: host) ?? loaded.flatMap({ $0.lookup == lookup ? $0.icon : nil }) {
            FaviconImage(image: icon)
                .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
                .frame(width: size, height: size)
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
                .task(id: lookup) {
                    guard let favicons = profileFavicons else { return }
                    let icon = if let cached = favicons.cached(for: host) {
                        cached
                    } else {
                        await favicons.load(forHost: host)
                    }
                    guard profileFavicons === favicons, let icon else { return }
                    loaded = (lookup, icon)
                }
        }
    }
}
