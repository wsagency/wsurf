// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The user-visible computer name recorded by the Mac that first published a profile.
nonisolated public struct ProfilePublicationSource: Codable, Hashable, Sendable {
    public let macName: String?

    public init(macName: String?) {
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let words = (macName ?? "").components(separatedBy: separators).filter { !$0.isEmpty }
        // A bound in Unicode scalars also limits UTF-8 storage for names with combining marks.
        let name = String(words.joined(separator: " ").unicodeScalars.prefix(64)).trimmingCharacters(in: .whitespaces)
        self.macName = name.isEmpty ? nil : name
    }

    private enum CodingKeys: String, CodingKey { case macName }

    public init(from decoder: any Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(macName: try? fields?.decode(String.self, forKey: .macName))
    }
}
