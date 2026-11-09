// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The four formats of the generator sheet.
nonisolated enum PasswordFormat: String, CaseIterable, Sendable {
    /// `xxxxxx-xxxxxx-xxxxxx`: 32 symbols (a-z without `l` and `o`, 2-9), a digit, one capital, hyphens between groups.
    case easyToType
    /// Letters (without `l`, `o`, `I`) and digits 2-9; at least one lowercase, one uppercase and one digit.
    case lettersAndDigits
    /// As letters and digits, plus `- _ . ! @ # $ % * + = ?`; at least one of each class.
    case withSymbols
    /// From the field's `passwordrules`.
    case websiteRules
}

/// The field's own `minlength` and `maxlength`. Where they conflict with the website's rules, these win.
nonisolated struct PasswordFieldLimits: Equatable, Sendable {
    var minLength: Int?
    var maxLength: Int?

    init(minLength: Int? = nil, maxLength: Int? = nil) {
        self.minLength = minLength
        self.maxLength = maxLength
    }
}

/// Makes passwords. The random source is a parameter: the app passes `SystemRandomNumberGenerator` (a CSPRNG, `arc4random_buf`),
/// tests pass a seeded or a counting one, and no other randomness is used. Every draw goes through the standard library's
/// `randomElement(using:)`, which is unbiased for any alphabet size, and a rule is met by drawing again, not by repairing a
/// candidate, so a password is uniform over those that meet the rules.
///
/// It never produces a space or a non-ASCII character, and it returns nil when the rules cannot be met: an empty allowed set, a
/// minimum above the maximum, required sets that do not fit, or the tries run out.
nonisolated enum PasswordGenerator {
    static let defaultLength = 20
    /// The length range the sheet's stepper offers; the field's limits narrow it.
    static let lengthRange = 12...64
    /// What the generator accepts at all, whatever a website asks for.
    static let absoluteLengthRange = 1...128
    /// How many candidates one request may draw before it gives up.
    static let maximumTries = 10_000
    /// Candidates of the default format tried against website rules before the draw from the allowed set.
    private static let defaultFormatTries = 20

    private static let lookAlikes = Set("01loI".utf8)
    private static let easyLetters = Array("abcdefghijkmnpqrstuvwxyz".utf8)
    private static let easyDigits = Array("23456789".utf8)
    private static let easyAlphabet = easyLetters + easyDigits
    private static let upperLetters = PasswordRules.upper.filter { !lookAlikes.contains($0) }
    private static let symbols = Array("-_.!@#$%*+=?".utf8)

    /// A password of `length` characters (clamped to the bounds that apply) or nil.
    static func generate(
        _ format: PasswordFormat,
        length: Int = defaultLength,
        rules: PasswordRules = PasswordRules(),
        field: PasswordFieldLimits = PasswordFieldLimits()
    ) -> GeneratedPassword? {
        var generator = SystemRandomNumberGenerator()
        return generate(format, length: length, rules: rules, field: field, using: &generator)
    }

    static func generate<Source: RandomNumberGenerator>(
        _ format: PasswordFormat,
        length: Int = defaultLength,
        rules: PasswordRules = PasswordRules(),
        field: PasswordFieldLimits = PasswordFieldLimits(),
        using generator: inout Source
    ) -> GeneratedPassword? {
        guard let bounds = lengthBounds(for: format, rules: rules, field: field) else { return nil }
        let count = min(max(length, bounds.lowerBound), bounds.upperBound)
        let characters: [UInt8]?
        switch format {
        case .easyToType:
            characters = easyToType(count, using: &generator)
        case .lettersAndDigits:
            characters = drawUntilEveryClass(count, classes: [easyLetters, upperLetters, easyDigits], using: &generator)
        case .withSymbols:
            characters = drawUntilEveryClass(count, classes: [easyLetters, upperLetters, easyDigits, symbols], using: &generator)
        case .websiteRules:
            characters = fromRules(rules, count: count, using: &generator)
        }
        return characters.map(GeneratedPassword.init)
    }

    /// The lengths a password may have. Only `.websiteRules` reads the website's rules; every format keeps the field's own limits.
    /// A rules bound that conflicts with the field's is dropped, so the field wins; rules that conflict on their own give nil. Nil when no length fits.
    static func lengthBounds(for format: PasswordFormat, rules: PasswordRules, field: PasswordFieldLimits) -> ClosedRange<Int>? {
        var low = field.minLength
        var high = field.maxLength
        if format == .websiteRules {
            let absolute = absoluteLengthRange
            let rulesLow = rules.minLength ?? absolute.lowerBound
            let rulesHigh = rules.maxLength ?? absolute.upperBound
            // Rules that cannot be met on their own (a minimum above the maximum, or above what the generator makes) give nothing.
            guard rulesLow <= rulesHigh, rulesLow <= absolute.upperBound else { return nil }
            let mergedLow = max(rulesLow, field.minLength ?? absolute.lowerBound)
            let mergedHigh = min(rulesHigh, field.maxLength ?? absolute.upperBound)
            if mergedLow <= mergedHigh {
                low = mergedLow
                high = mergedHigh
            }
        }
        let lower = max(low ?? absoluteLengthRange.lowerBound, absoluteLengthRange.lowerBound)
        let upper = min(high ?? absoluteLengthRange.upperBound, absoluteLengthRange.upperBound)
        return lower <= upper ? lower...upper : nil
    }

    // MARK: Formats

    /// Hyphen-separated groups of about six: `xxxxxx-xxxxxx-xxxxxx` at 20, no hyphen below 13, the characters spread evenly
    /// over the groups otherwise.
    private static func easyToType<Source: RandomNumberGenerator>(_ count: Int, using generator: inout Source) -> [UInt8]? {
        guard count >= 2 else { return nil }
        for _ in 0..<maximumTries {
            if let candidate = easyCandidate(count, using: &generator) {
                return candidate
            }
        }
        return nil
    }

    /// One try at the default format: nil when the draw has no digit or no letter that can become a capital.
    private static func easyCandidate<Source: RandomNumberGenerator>(_ count: Int, using generator: inout Source) -> [UInt8]? {
        let groups = max(1, (count + 1) / 7)
        let drawnCount = count - (groups - 1)
        var drawn = (0..<drawnCount).map { _ in easyAlphabet[Int.random(in: 0..<easyAlphabet.count, using: &generator)] }
        guard drawn.contains(where: easyDigits.contains) else { return nil }
        let capitalisable = drawn.indices.filter { drawn[$0] != UInt8(ascii: "i") && easyLetters.contains(drawn[$0]) }
        guard let position = capitalisable.randomElement(using: &generator) else { return nil }
        drawn[position] -= 32
        var result: [UInt8] = []
        var next = 0
        for group in 0..<groups {
            let size = drawnCount / groups + (group < drawnCount % groups ? 1 : 0)
            if group > 0 {
                result.append(UInt8(ascii: "-"))
            }
            result += drawn[next..<(next + size)]
            next += size
        }
        return result
    }

    /// Draws from the union of the classes and draws again until every class appears.
    private static func drawUntilEveryClass<Source: RandomNumberGenerator>(
        _ count: Int,
        classes: [[UInt8]],
        using generator: inout Source
    ) -> [UInt8]? {
        let pool = classes.flatMap { $0 }
        let tables = classes.map(Set.init)
        return draw(count, from: pool, using: &generator) { candidate in
            tables.allSatisfy { set in candidate.contains(where: set.contains) }
        }
    }

    /// The default format when it meets the rules; otherwise a uniform draw from the allowed set (no look-alikes while other
    /// characters remain) until every rule holds.
    private static func fromRules<Source: RandomNumberGenerator>(
        _ rules: PasswordRules,
        count: Int,
        using generator: inout Source
    ) -> [UInt8]? {
        let allowed = rules.allowedCharacters
        guard !allowed.isEmpty, !rules.requiredSets.contains(where: \.isEmpty) else { return nil }
        let matcher = PasswordRules.Matcher(rules)
        for _ in 0..<defaultFormatTries {
            if let candidate = easyCandidate(count, using: &generator), matcher.accepts(candidate) {
                return candidate
            }
        }
        var pool = allowed.filter { !lookAlikes.contains($0) }
        for set in rules.requiredSets where set.allSatisfy(lookAlikes.contains) {
            pool += set
        }
        pool = PasswordRules.normalized(pool.isEmpty ? allowed : pool)
        return draw(count, from: pool, using: &generator, accepting: matcher.accepts)
    }

    private static func draw<Source: RandomNumberGenerator>(
        _ count: Int,
        from pool: [UInt8],
        using generator: inout Source,
        accepting accepts: ([UInt8]) -> Bool
    ) -> [UInt8]? {
        guard !pool.isEmpty else { return nil }
        for _ in 0..<maximumTries {
            let candidate = (0..<count).map { _ in pool[Int.random(in: 0..<pool.count, using: &generator)] }
            if accepts(candidate) {
                return candidate
            }
        }
        return nil
    }
}
