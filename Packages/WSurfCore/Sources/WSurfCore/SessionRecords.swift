// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

nonisolated public enum DeviceKind: String, Codable, Sendable {
    case mac
    case iphone
    case other

    /// A kind this version does not know reads as `other`, so a newer device never fails to decode.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeviceKind(rawValue: raw) ?? .other
    }
}

nonisolated public struct DeviceInfo: Codable, Equatable, Sendable {
    public var name: String
    public var kind: DeviceKind
    public var appVersion: String

    public init(name: String, kind: DeviceKind, appVersion: String) {
        self.name = name
        self.kind = kind
        self.appVersion = appVersion
    }
}

/// One folder or tab of a session. The ID serves only as view identity and collapse state; it is never used to find a tab.
nonisolated public struct SessionNode: Identifiable, Codable, Equatable, Sendable {
    public static let maxTitleCharacters = 200
    public static let maxURLBytes = 4_096

    public var id: UUID
    public var title: String
    /// A tab's link. Nil for a folder.
    public var url: String?
    /// A folder's contents. Nil for a tab.
    public var children: [SessionNode]?

    public init(id: UUID, title: String, url: String? = nil, children: [SessionNode]? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.children = children
    }

    /// A tab node, or nil unless `url` is an http(s) link of at most 4096 UTF-8 bytes. The title is trimmed and cut to 200 characters.
    public static func tab(id: UUID, title: String, url: String) -> SessionNode? {
        guard url.utf8.count <= maxURLBytes, webURL(from: url) != nil else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionNode(id: id, title: String(trimmed.prefix(maxTitleCharacters)), url: url)
    }

    /// The link to open on this device, or nil unless it is http(s). Remote data is checked again here, at the trust boundary.
    public var webURL: URL? {
        url.flatMap(Self.webURL(from:))
    }

    /// The tabs in this node: itself for a tab, everything inside for a folder.
    public var tabCount: Int {
        guard let children else { return 1 }
        return children.reduce(0) { $0 + $1.tabCount }
    }

    private static func webURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false
        else { return nil }
        return url
    }
}

nonisolated public struct SessionWindow: Codable, Equatable, Sendable {
    public var id: UUID
    public var nodes: [SessionNode]

    public init(id: UUID, nodes: [SessionNode]) {
        self.id = id
        self.nodes = nodes
    }
}

/// What one device publishes for one profile. Later fields must be optional or have a decode default: a decoder ignores keys it
/// does not know, and an older device keeps reading what a newer one wrote.
nonisolated public struct DeviceSessionPayload: Codable, Equatable, Sendable {
    /// Stamped by `TabSync` on every send, so a record always changes.
    public var seq: Int64
    /// A regular window of this profile is open on that device.
    public var running: Bool
    public var favorites: [SessionNode]
    /// Pinned tabs and pinned folders with their children.
    public var pins: [SessionNode]
    public var windows: [SessionWindow]
    /// Tabs left out to fit the size budget.
    public var omittedTabs: Int

    public init(
        seq: Int64 = 0,
        running: Bool,
        favorites: [SessionNode],
        pins: [SessionNode],
        windows: [SessionWindow],
        omittedTabs: Int = 0
    ) {
        self.seq = seq
        self.running = running
        self.favorites = favorites
        self.pins = pins
        self.windows = windows
        self.omittedTabs = omittedTabs
    }
}

nonisolated public enum SessionCodec {
    /// 768 KiB of the 1 MB record limit. The rest is for the system fields and the encryption.
    public static let maxPayloadBytes = 786_432

    public static func encode(_ info: DeviceInfo) throws -> Data {
        try encoder().encode(info)
    }

    public static func decodeDevice(_ data: Data) throws -> DeviceInfo {
        try JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    // ponytail: re-encodes per pass; only runs past ~10k tabs.
    /// `lzfse(JSON)` of the payload within `budget`, or nil when even the pins and Favorites alone do not fit.
    ///
    /// Over the budget, it removes `max(1, items / 10)` top-level items from the ends of the windows, one at a time from the window
    /// with the most items, and counts their tabs in `omittedTabs`. Favorites and pins are never cut.
    public static func encodeFitted(_ payload: DeviceSessionPayload, budget: Int = maxPayloadBytes) -> Data? {
        var working = payload
        while true {
            guard let json = try? encoder().encode(working),
                  let packed = try? (json as NSData).compressed(using: .lzfse)
            else { return nil }
            if packed.length <= budget {
                return packed as Data
            }
            let items = working.windows.reduce(0) { $0 + $1.nodes.count }
            if items == 0 {
                return nil
            }
            for _ in 0..<max(1, items / 10) {
                guard let index = working.windows.indices.max(by: { working.windows[$0].nodes.count < working.windows[$1].nodes.count }),
                      let removed = working.windows[index].nodes.popLast()
                else { break }
                working.omittedTabs += removed.tabCount
            }
        }
    }

    // ponytail: decompression has no output limit. The source is the person's own encrypted iCloud data; add a cap if a
    // record from a second writer is ever accepted.
    public static func decodeSession(_ data: Data) throws -> DeviceSessionPayload {
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        return try JSONDecoder().decode(DeviceSessionPayload.self, from: json)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
