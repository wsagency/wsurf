// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import NaturalLanguage
@preconcurrency import Translation

/// Which language a page is in and which languages the person reads. Detection runs on device with NaturalLanguage.
nonisolated enum TranslationLanguage {
    static var preferred: Locale.Language {
        Locale.preferredLanguages.first.map(Locale.Language.init(identifier:)) ?? Locale.current.language
    }

    /// The language without its region, keeping the script only for Chinese, where it decides what a reader can read.
    static func key(_ language: Locale.Language) -> String {
        let maximal = Locale.Language(identifier: language.maximalIdentifier)
        let code = maximal.languageCode?.identifier ?? language.minimalIdentifier
        guard code == "zh", let script = maximal.script?.identifier else { return code }
        return "\(code)-\(script)"
    }

    static func matches(_ lhs: Locale.Language, _ rhs: Locale.Language) -> Bool {
        key(lhs) == key(rhs)
    }

    static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: key(language)) ?? language.minimalIdentifier
    }

    /// The languages a page can be translated to: none when the person reads the page's language, otherwise the remembered
    /// target first and then the preferred languages, each once.
    static func targets(
        for source: Locale.Language,
        preferring stored: String,
        preferred: [String] = Locale.preferredLanguages
    ) -> [Locale.Language] {
        let readable = preferred.map(Locale.Language.init(identifier:))
        guard !readable.contains(where: { matches($0, source) }) else { return [] }
        var seen = Set<String>()
        let candidates = (stored.isEmpty ? [] : [Locale.Language(identifier: stored)]) + readable
        return candidates.filter { !matches($0, source) && seen.insert(key($0)).inserted }
    }

    static func translatable(
        _ targets: [Locale.Language],
        from source: Locale.Language
    ) async -> [Locale.Language] {
        let availability = LanguageAvailability()
        var result: [Locale.Language] = []
        for target in targets where await availability.status(from: source, to: target) != .unsupported {
            result.append(target)
        }
        return result
    }

    @concurrent
    static func detectInBackground(_ sample: PageTranslationSample) async -> Locale.Language? {
        detect(sample)
    }

    /// The language most of the page's longer lines are in, so a title or a menu in another language does not decide it. When
    /// there is little text, a declared language the text could plausibly be in wins.
    static func detect(_ sample: PageTranslationSample) -> Locale.Language? {
        guard sample.text.count >= 24 else { return nil }
        let lines = sample.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 24 }
        let recognizer = NLLanguageRecognizer()
        var votes: [NLLanguage: Double] = [:]
        for line in lines.isEmpty ? [sample.text] : lines {
            recognizer.reset()
            recognizer.processString(line)
            for (language, probability) in recognizer.languageHypotheses(withMaximum: 1) {
                votes[language, default: 0] += probability * Double(line.count)
            }
        }
        let total = votes.values.reduce(0, +)
        let declared = Locale.Language(identifier: sample.declaredLanguage.trimmingCharacters(in: .whitespaces))
        let declaredLanguage = declared.languageCode == nil ? nil : declared
        if let best = votes.max(by: { $0.value < $1.value }),
           best.key != .undetermined, total > 0, best.value / total >= 0.6 {
            let detected = Locale.Language(identifier: best.key.rawValue)
            if total < 200, let declaredLanguage, !matches(detected, declaredLanguage) {
                recognizer.reset()
                recognizer.processString(sample.text)
                if recognizer.languageHypotheses(withMaximum: 10)[naturalLanguage(declaredLanguage)] ?? 0 >= 0.1 {
                    return declaredLanguage
                }
            }
            return detected
        }
        guard sample.text.count >= 80 else { return nil }
        return declaredLanguage
    }

    static func naturalLanguage(_ language: Locale.Language) -> NLLanguage {
        NLLanguage(rawValue: key(language))
    }

    /// Recognizes a block that is already in the target language, such as a quotation or a menu, so it is left as it is.
    nonisolated struct Skipper: Sendable {
        private let source: NLLanguage
        private let target: NLLanguage

        init(source: Locale.Language, target: Locale.Language) {
            self.source = TranslationLanguage.naturalLanguage(source)
            self.target = TranslationLanguage.naturalLanguage(target)
        }

        @concurrent
        func isAlreadyTarget(_ segments: [PageTranslationSegment]) async -> Bool {
            let text = segments.map(\.text).joined()
            guard text.count >= 16 else { return false }
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [source, target]
            recognizer.processString(text)
            return (recognizer.languageHypotheses(withMaximum: 2)[target] ?? 0) >= 0.8
        }
    }
}
