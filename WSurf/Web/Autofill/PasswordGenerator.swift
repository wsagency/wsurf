// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The four formats of the generator sheet.
nonisolated enum PasswordFormat: String, CaseIterable, Sendable {
    /// `xxxxxx-xxxxxx-xxxxxx`: 32 symbols (a-z without `l` and `o`, 2-9), a digit, one capital, hyphens between groups.
    case easyToType
    /// Letters (without `l`, `o`, `I`, `O`) and digits 2-9; at least one lowercase, one uppercase and one digit.
    case lettersAndDigits
    /// As letters and digits, plus `- _ . ! @ # $ % * + = ?`; at least one of each class.
    case withSymbols
    /// From the field's `passwordrules`.
    case websiteRules
}

/// The field's own `minlength` and `maxlength`. Where they conflict with the website's rules, these win. A negative value counts as
/// absent: the DOM reports -1 for an attribute the field does not have.
nonisolated struct PasswordFieldLimits: Equatable, Sendable {
    var minLength: Int?
    var maxLength: Int?

    /// The limits that are real: a negative one is the DOM's "none".
    fileprivate var bounds: (low: Int?, high: Int?) {
        (minLength.flatMap { $0 >= 0 ? $0 : nil }, maxLength.flatMap { $0 >= 0 ? $0 : nil })
    }
}

/// Makes passwords. The app's entry point draws from `SystemRandomNumberGenerator` (a CSPRNG, `arc4random_buf`) and takes no other
/// source: the overload that accepts one exists in Debug builds only, for tests, so a Release build cannot compile an app call that
/// injects a source. No other randomness is used. Every pick is `Int.random(in:using:)` or `randomElement(using:)`, the standard
/// library's unbiased draw for any alphabet size, and a rule is met by drawing again, not by repairing a candidate. A draw from the
/// allowed set (the fixed formats and Website's Rules after the default format fails) is therefore uniform over the passwords that
/// meet the rules. The default format is not exactly uniform (its capital is picked among the draw's letters, so a password with fewer of them is slightly more likely), and
/// Website's Rules tries it first when it meets the rules.
///
/// It never produces a space or a non-ASCII character, and it returns nil when the rules cannot be met: an empty allowed set, a
/// minimum above the maximum, required sets that do not fit, or the tries run out.
nonisolated enum PasswordGenerator {
    static let defaultLength = 20
    /// The length range the sheet's stepper offers. A requested length is clamped into it; only the site's own limits go beyond.
    static let lengthRange = 12...64
    /// What the generator accepts at all, whatever a website asks for.
    static let absoluteLengthRange = 1...128
    /// How many candidates one request may draw before it gives up. Whole-candidate rejection can run out of tries for rules that
    /// could be met, with a small pool, a long length and max-consecutive 1 (24 one-case letters at 128 characters, digits at 32 or
    /// more): the sheet then says it cannot make a password that meets the website's rules, and another format still works.
    static let maximumTries = 10_000
    /// Easy to Type has no hyphen below this many characters, which makes it the weakest format there (8 characters: about 40 bits,
    /// against about 46 for Letters and Digits), so the sheet starts with Letters and Digits for a field that allows fewer.
    static let easyToTypeShortest = 13
    /// The sheet notes a password estimated below this many bits (`estimatedBits`): the field's limits made it short.
    static let weakBits = 60.0
    /// Candidates of the default format tried against website rules before the draw from the allowed set.
    private static let defaultFormatTries = 20

    /// Characters that read alike in many typefaces. O joins the plan's `0 1 l o I`: it is the classic pair of 0.
    private static let lookAlikes = Set("01loIO".utf8)
    /// A pool that would drop below this many symbols without its look-alikes keeps them: a small allowed set stays itself.
    private static let smallestReducedPool = 16
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
        return make(format, length: length, rules: rules, field: field, using: &generator)
    }

    #if DEBUG
    /// Tests only: the same with a seeded or counting source.
    static func generate<Source: RandomNumberGenerator>(
        _ format: PasswordFormat,
        length: Int = defaultLength,
        rules: PasswordRules = PasswordRules(),
        field: PasswordFieldLimits = PasswordFieldLimits(),
        using generator: inout Source
    ) -> GeneratedPassword? {
        make(format, length: length, rules: rules, field: field, using: &generator)
    }
    #endif

    private static func make<Source: RandomNumberGenerator>(
        _ format: PasswordFormat,
        length: Int,
        rules: PasswordRules,
        field: PasswordFieldLimits,
        using generator: inout Source
    ) -> GeneratedPassword? {
        guard let bounds = lengthBounds(for: format, rules: rules, field: field) else { return nil }
        // Only the site's own limits may push a password below the sheet's 12 characters (or above its 64).
        let wanted = min(max(length, lengthRange.lowerBound), lengthRange.upperBound)
        let count = min(max(wanted, bounds.lowerBound), bounds.upperBound)
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

    /// The lengths a password may have. Every format keeps the field's own limits and the website's length limits, because a site
    /// that cuts a value to its `maxlength` would otherwise store a different password than the vault. A rules bound that conflicts
    /// with the field's is dropped, so the field wins. Rules that conflict on their own (a minimum above the maximum, or above what
    /// the generator makes) leave the field's limits alone: `.websiteRules` then needs the field's maxlength and gives nil without one,
    /// and the other formats ignore the rules' bounds. Nil when no length fits.
    static func lengthBounds(for format: PasswordFormat, rules: PasswordRules, field: PasswordFieldLimits) -> ClosedRange<Int>? {
        let absolute = absoluteLengthRange
        var low = field.bounds.low
        var high = field.bounds.high
        let rulesLow = rules.minLength ?? absolute.lowerBound
        let rulesHigh = rules.maxLength ?? absolute.upperBound
        if rulesLow <= rulesHigh, rulesLow <= absolute.upperBound {
            let mergedLow = max(rulesLow, low ?? absolute.lowerBound)
            let mergedHigh = min(rulesHigh, high ?? absolute.upperBound)
            if mergedLow <= mergedHigh {
                low = mergedLow
                high = mergedHigh
            }
        } else if format == .websiteRules, high == nil {
            // Rules that cannot be met on their own. Only the field's maxlength, the limit the browser enforces, is a bound to fall
            // back on: with it, the field wins, as it does wherever the two conflict. Without it there is nothing to generate for.
            return nil
        }
        let lower = max(low ?? absolute.lowerBound, absolute.lowerBound)
        let upper = min(high ?? absolute.upperBound, absolute.upperBound)
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
        // Without look-alikes while the pool stays large; a small allowed set (`digit`, `[0o1lIa]`) is used whole.
        let reduced = allowed.filter { !lookAlikes.contains($0) }
        if reduced.count >= smallestReducedPool {
            var pool = reduced
            for set in rules.requiredSets where set.allSatisfy(lookAlikes.contains) {
                pool += set
            }
            if let password = draw(count, from: PasswordRules.normalized(pool), using: &generator, accepting: matcher.accepts) {
                return password
            }
        }
        return draw(count, from: allowed, using: &generator, accepting: matcher.accepts)
    }

    /// About how many bits a password of `format` at `count` characters has: the alphabet of its draw, before the rules that make it
    /// draw again (which take away a little). Website's Rules may give the default format when that meets the rules, so its estimate is
    /// the smaller of that and the allowed set's.
    static func estimatedBits(_ format: PasswordFormat, count: Int, rules: PasswordRules = PasswordRules()) -> Double {
        func bits(_ symbols: Int, _ length: Int) -> Double {
            symbols > 1 && length > 0 ? Double(length) * log2(Double(symbols)) : 0
        }
        let easy = bits(easyAlphabet.count, count - (max(1, (count + 1) / 7) - 1))
        switch format {
        case .easyToType:
            return easy
        case .lettersAndDigits:
            return bits(easyLetters.count + upperLetters.count + easyDigits.count, count)
        case .withSymbols:
            return bits(easyLetters.count + upperLetters.count + easyDigits.count + symbols.count, count)
        case .websiteRules:
            let allowed = rules.allowedCharacters
            let reduced = allowed.filter { !lookAlikes.contains($0) }.count
            return min(easy, bits(reduced >= smallestReducedPool ? reduced : allowed.count, count))
        }
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
