// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WebKit

/// What reading an article aloud needs that is not a state machine: the pace, the sentences of a block, the language to speak
/// them in, and the two scripts that read the article's text out of its view and mark the sentence being spoken in it.
nonisolated enum ReaderSpeech {
    static let rateRange: ClosedRange<Float> = 0.5...1.5
    static let defaultRate: Float = 1

    /// The nearest tenth inside `rateRange`. A value that is not a number is the default.
    static func clampedRate(_ rate: Float) -> Float {
        guard rate.isFinite else { return defaultRate }
        return (min(max(rate, rateRange.lowerBound), rateRange.upperBound) * 10).rounded() / 10
    }

    /// One sentence of a block, and where it is in the block's text, in UTF-16 units as the page counts them.
    struct Sentence: Equatable {
        let text: String
        let range: Range<Int>
    }

    /// The sentence being read: its block (`ReaderPage.titleBlock` is the headline) and its range in that block's text.
    struct Spot: Equatable {
        let block: Int
        let range: Range<Int>
    }

    /// The text of a block as it is shown now, and the code of the language it is in, when that is known.
    struct Passage: Equatable, Sendable {
        let text: String
        let language: String?
    }

    /// The sentences of `text`, in order, without the space between them. A piece with no letter or digit in it (a dash, a row of
    /// dots) has nothing to say and is left out. The boundaries are the system's, which splits after an abbreviation such as
    /// "Dr." when a capital letter follows.
    static func sentences(in text: String) -> [Sentence] {
        var found: [Sentence] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, bounds, _, _ in
            var start = bounds.lowerBound
            var end = bounds.upperBound
            while start < end, text[start].isWhitespace {
                start = text.index(after: start)
            }
            while end > start, text[text.index(before: end)].isWhitespace {
                end = text.index(before: end)
            }
            let sentence = text[start..<end]
            guard sentence.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            let units = NSRange(start..<end, in: text)
            found.append(Sentence(text: String(sentence), range: units.location..<(units.location + units.length)))
        }
        return found
    }

    /// The BCP 47 code a voice is looked up by: `de` is `de-DE`, `zh-Hant` is `zh-TW`. Nil for a language that is not one.
    static func voiceLanguage(_ language: Locale.Language) -> String? {
        let full = Locale.Language(identifier: language.maximalIdentifier)
        guard let code = full.languageCode?.identifier else { return nil }
        guard let region = full.region?.identifier else { return code }
        return "\(code)-\(region)"
    }

    /// What to read for a block. The article's view holds the text as it is shown, translated when the article has been, so that
    /// comes first; the article's own text is for a view that cannot be read. The language follows the text: the translation's
    /// target while the article is being or has been translated, the article's own language before.
    static func passage(
        shown: String?, original: String?, translatedTo target: Locale.Language?, articleLanguage: String
    ) -> Passage? {
        guard let text = [shown, original].lazy.compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        // ponytail: a block the translation has not reached yet is read in the target's voice. NLLanguageRecognizer on each block's
        // text would follow the text exactly, if that turns out to be heard.
        let language = target ?? (articleLanguage.isEmpty ? nil : Locale.Language(identifier: articleLanguage))
        return Passage(text: text, language: language.flatMap(voiceLanguage))
    }
}

// MARK: - In the article's view

@MainActor
extension ReaderSpeech {
    /// The scripts run in the app's own world: the article's view runs no JavaScript of the page's, and the DOM is the same in every
    /// world, so it sees the text a translation has put in. Reader's view is the page `ReaderPage` builds; `titleID` and
    /// `data-reader-block` are its anchors.
    static let world = WKContentWorld.defaultClient

    static let replyCeiling: Duration = .seconds(2)

    /// The name of the highlight, which `ReaderPage` styles with `::highlight()`.
    static let highlightName = "reader-speaking"

    /// The text of a block as the view shows it now, in the form `ReaderArticle.blocks` has: whitespace collapsed and trimmed.
    static func shownText(ofBlock block: Int, in page: BrowserPage) async -> String? {
        await page.callAsyncJavaScript(
            readScript, arguments: ["block": block, "titleID": ReaderPage.titleID],
            in: world, within: replyCeiling, as: String.self
        )
    }

    /// Marks the sentence at `range` of the block in the view, and brings it into sight when it is not. Nil clears the mark.
    static func mark(_ spot: Spot?, in page: BrowserPage) async {
        _ = await page.callAsyncJavaScript(
            spot == nil ? clearScript : markScript,
            arguments: [
                "block": spot?.block ?? 0, "start": spot?.range.lowerBound ?? 0, "end": spot?.range.upperBound ?? 0,
                "titleID": ReaderPage.titleID,
            ],
            in: world, within: replyCeiling, as: Bool.self
        )
    }

    private static let blockElement = """
    const element = block < 0 ? document.getElementById(titleID) : document.querySelector('[data-reader-block="' + block + '"]');
    """

    static let readScript = """
    \(blockElement)
    return element ? (element.textContent || '').replace(/\\s+/g, ' ').trim() : null;
    """

    private static let clearStatement = "if (CSS.highlights) CSS.highlights.delete('\(highlightName)');"

    static let clearScript = """
    \(clearStatement)
    return true;
    """

    /// The offsets count the block's text as `readScript` gives it, so the text nodes are walked with whitespace collapsed the same
    /// way. The mark is a CSS highlight over a range: the article's DOM is not changed, which keeps a screen reader's place in it.
    static let markScript = """
    \(clearStatement)
    \(blockElement)
    if (!element || !CSS.highlights || typeof Highlight !== 'function') return false;
    const positions = [];
    let collapsed = true;
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      for (let offset = 0; offset < node.data.length; offset++) {
        if (/\\s/.test(node.data[offset])) {
          if (collapsed) continue;
          collapsed = true;
        } else {
          collapsed = false;
        }
        positions.push([node, offset]);
      }
    }
    const first = positions[start], last = positions[end - 1];
    if (!first || !last) return false;
    const range = new Range();
    range.setStart(first[0], first[1]);
    range.setEnd(last[0], last[1] + 1);
    CSS.highlights.set('\(highlightName)', new Highlight(range));
    const box = range.getBoundingClientRect();
    if (box.top < 80 || box.bottom > innerHeight - 40) {
      const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
      scrollBy({ top: box.top - innerHeight / 3, behavior: calm ? 'auto' : 'smooth' });
    }
    return true;
    """
}
