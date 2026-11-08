// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

/// The main text of a page, as data. `content` is Readability's HTML with scripts, forms and inline handlers removed, and each text
/// block in it carries a `data-reader-block` index into `blocks`. It is still untrusted: whoever shows it must not run it.
nonisolated struct ReaderArticle: Equatable, Sendable {
    let url: URL
    let title: String
    let byline: String
    let siteName: String
    let excerpt: String
    let language: String
    let isRightToLeft: Bool
    let content: String
    let blocks: [String]

    var text: String {
        blocks.joined(separator: "\n\n")
    }

    /// Counted once, when the article is made: Reader's page reads it on every load.
    let wordCount: Int

    var readingMinutes: Int {
        max(1, Int((Double(wordCount) / 230).rounded()))
    }

    init(
        url: URL,
        title: String,
        byline: String = "",
        siteName: String = "",
        excerpt: String = "",
        language: String = "",
        isRightToLeft: Bool = false,
        content: String,
        blocks: [String]
    ) {
        self.url = url
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.excerpt = excerpt
        self.language = language
        self.isRightToLeft = isRightToLeft
        self.content = content
        self.blocks = blocks
        wordCount = blocks.reduce(0) { $0 + Self.words(in: $1) }
    }

    /// The words of `text`, split at white space. A scan over the scalars: splitting into substrings walks grapheme
    /// clusters, which took 18 ms for a long article.
    nonisolated static func words(in text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let isSpace = scalar.value < 0x80
                ? (scalar.value == 0x20 || (0x09...0x0D).contains(scalar.value))
                : scalar.properties.isWhitespace
            if isSpace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["url"] as? String,
              let url = URL(string: address),
              let content = object["content"] as? String,
              let blocks = object["blocks"] as? [String],
              !blocks.isEmpty
        else { return nil }
        func field(_ key: String) -> String {
            (object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.init(
            url: url,
            title: field("title"),
            byline: field("byline"),
            siteName: field("siteName"),
            excerpt: field("excerpt"),
            language: field("lang"),
            isRightToLeft: field("dir").lowercased() == "rtl",
            content: content,
            blocks: blocks
        )
    }
}
