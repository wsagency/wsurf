// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// U1: the `passwordrules` parser. Apple's examples, joined sets, the `[-...]`, `[...]]` and `[]...]` sets, an unknown property skipped
/// alone, input over 1,000 characters ignored, and random input never crashing.
@Suite
struct PasswordRulesTests {
    private func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    @Test
    func appleExamplesParse() {
        let first = PasswordRules(parsing: "required: upper; required: lower; required: digit; required: [-]; minlength: 8; maxlength: 20")
        #expect(first.requiredSets.count == 4)
        #expect(first.requiredSets[3] == Array("-".utf8))
        #expect(first.minLength == 8)
        #expect(first.maxLength == 20)

        let second = PasswordRules(parsing: "minlength: 8; required: lower, upper; required: digit; max-consecutive: 2")
        #expect(second.requiredSets == [PasswordRules.lower, PasswordRules.upper, PasswordRules.digit])
        #expect(second.maxConsecutive == 2)

        let third = PasswordRules(parsing: "allowed: ascii-printable")
        #expect(third.allowedCharacters == PasswordRules.asciiPrintable)

        let fourth = PasswordRules(parsing: "Required : UPPER ;ALLOWED:Special,Digit")
        #expect(fourth.requiredSets == [PasswordRules.upper])
        #expect(fourth.allowedSets == [PasswordRules.special, PasswordRules.digit])
    }

    @Test
    func setsAreJoinedAndRequiredIsAllowed() {
        let rules = PasswordRules(parsing: "allowed: upper; allowed: [!?]; required: digit")
        let expected = PasswordRules.normalized(PasswordRules.upper + Array("!?".utf8) + PasswordRules.digit)
        #expect(rules.allowedCharacters == expected)

        // Apple's reference parser: `required: upper` alone allows upper and nothing else; ascii-printable only when neither is named.
        let onlyRequired = PasswordRules(parsing: "required: [é]; required: lower")
        #expect(onlyRequired.allowedCharacters == PasswordRules.lower)
        #expect(onlyRequired.requiredSets.first == [])
        #expect(PasswordRules(parsing: "required: upper").allowedCharacters == PasswordRules.upper)
        let lettersAndDigits = PasswordRules(parsing: "required: lower; required: upper; required: digit")
        #expect(lettersAndDigits.allowedCharacters == PasswordRules.normalized(PasswordRules.lower + PasswordRules.upper + PasswordRules.digit))
        #expect(PasswordRules(parsing: "required: upper; allowed: digit").allowedCharacters == PasswordRules.normalized(PasswordRules.upper + PasswordRules.digit))

        let explicitlyEmpty = PasswordRules(parsing: "allowed: []")
        #expect(explicitlyEmpty.allowedCharacters.isEmpty)

        let none = PasswordRules(parsing: "minlength: 8")
        #expect(none.allowedCharacters == PasswordRules.asciiPrintable)
    }

    @Test
    func lengthsTakeTheStrictestValue() {
        let rules = PasswordRules(parsing: "minlength: 8; minlength: 12; maxlength: 30; maxlength: 16; max-consecutive: 3; max-consecutive: 2")
        #expect(rules.minLength == 12)
        #expect(rules.maxLength == 16)
        #expect(rules.maxConsecutive == 2)
    }

    @Test
    func customSetsKeepTheirHyphenAndBracket() {
        #expect(text(PasswordRules(parsing: "allowed: [-abc]").allowedCharacters) == "-abc")
        // Apple counts a `-` only as the first character of a set; any other is dropped.
        #expect(text(PasswordRules(parsing: "allowed: [abc-]").allowedCharacters) == "abc")
        #expect(text(PasswordRules(parsing: "allowed: [a-z0-9]").allowedCharacters) == "09az")
        #expect(text(PasswordRules(parsing: "allowed: [abc]]").allowedCharacters) == "]abc")
        #expect(text(PasswordRules(parsing: "allowed: []abc]").allowedCharacters) == "]abc")
        #expect(text(PasswordRules(parsing: "allowed: [a;b,c]; maxlength: 9").allowedCharacters) == ",;abc")
        #expect(PasswordRules(parsing: "allowed: [a;b,c]; maxlength: 9").maxLength == 9)
        #expect(PasswordRules(parsing: "required: [ab], [cd]").requiredSets.count == 2)
        #expect(text(PasswordRules(parsing: "allowed: [aé 😀b]").allowedCharacters) == "ab")
    }

    @Test
    func anUnknownOrBrokenPropertyIsSkippedAlone() {
        let unknown = PasswordRules(parsing: "frobnicate: 3; maxlength: 16; required: upper")
        #expect(unknown.maxLength == 16)
        #expect(unknown.requiredSets == [PasswordRules.upper])

        let brokenNumber = PasswordRules(parsing: "maxlength: abc; minlength: 8; max-consecutive: 0; maxlength: -4")
        #expect(brokenNumber.maxLength == nil)
        #expect(brokenNumber.minLength == 8)
        #expect(brokenNumber.maxConsecutive == nil)

        let unbalanced = PasswordRules(parsing: "required: [abc; maxlength: 12")
        #expect(unbalanced.requiredSets.isEmpty)
        #expect(unbalanced.maxLength == 12)

        let unknownClass = PasswordRules(parsing: "required: upper, bogus; minlength: 6")
        #expect(unknownClass.requiredSets == [PasswordRules.upper])
        #expect(unknownClass.minLength == 6)

        let noColon = PasswordRules(parsing: "nonsense; maxlength: 10")
        #expect(noColon.maxLength == 10)
    }

    @Test
    func unicodeReadsAsAsciiPrintable() {
        let rules = PasswordRules(parsing: "allowed: unicode")
        #expect(rules.allowedCharacters == PasswordRules.asciiPrintable)
        #expect(!rules.allowedCharacters.contains(32))
    }

    @Test
    func theNewerLimitsParse() {
        let rules = PasswordRules(parsing: "max-repeating: 3; max-sequential: 2")
        #expect(rules.maxRepeating == 3)
        #expect(rules.maxSequential == 2)
        // Apple's reading: `max-repeating` is a run of identical characters in a row, not one character's total.
        #expect(rules.accepts(Array("aXaYaZa".utf8)))
        #expect(rules.accepts(Array("aaaX".utf8)))
        #expect(rules.accepts(Array("aaaaX".utf8)) == false)
        #expect(rules.accepts(Array("abc".utf8)) == false)
        #expect(rules.accepts(Array("abXab".utf8)))
        #expect(PasswordRules(parsing: "max-repeating: 2").accepts(Array("aXaYaZa".utf8)))
        #expect(PasswordRules(parsing: "max-repeating: 2").accepts(Array("abcdef".utf8)), "max-repeating leaves sequences alone")
        #expect(PasswordRules(parsing: "max-sequential: 2").accepts(Array("aaaa".utf8)), "max-sequential leaves repeats alone")
        // `max-consecutive` is an alias for both limits.
        let alias = PasswordRules(parsing: "max-consecutive: 2")
        #expect(alias.accepts(Array("aab".utf8)))
        #expect(alias.accepts(Array("aaab".utf8)) == false)
        #expect(alias.accepts(Array("abXbc".utf8)))
        #expect(alias.accepts(Array("abc".utf8)) == false)
        #expect(alias.accepts(Array("Xcba".utf8)) == false)
        // The smaller limit of the two applies to each kind of run.
        let both = PasswordRules(parsing: "max-consecutive: 2; max-repeating: 1")
        #expect(both.accepts(Array("aab".utf8)) == false)
        #expect(both.accepts(Array("abXbc".utf8)))
        #expect(rules.accepts(Array("acegi".utf8)))
        #expect(PasswordRules(parsing: "max-sequential: 2").accepts(Array("xcba".utf8)) == false)
    }

    @Test
    func inputOverAThousandCharactersIsIgnored() {
        let rule = "maxlength: 10;"
        let exactly = rule + String(repeating: " ", count: PasswordRules.maximumInputLength - rule.count)
        #expect(exactly.count == 1_000)
        #expect(PasswordRules(parsing: exactly).maxLength == 10)
        let over = exactly + " "
        #expect(PasswordRules(parsing: over).isEmpty)
        #expect(PasswordRules(parsing: String(repeating: "required: upper;", count: 100)).isEmpty)
        // The cap counts bytes: a short string of combining marks is long to parse.
        let marks = "a" + String(repeating: "\u{0301}", count: 600)
        #expect(marks.count == 1)
        #expect(PasswordRules(parsing: "maxlength: 9; " + marks).maxLength == nil)
        #expect(PasswordRules(parsing: "maxlength: 9; ").maxLength == 9)
    }

    @Test
    func randomInputNeverCrashes() {
        var generator = SplitMix64(seed: 7)
        let pieces = ["required", "allowed", "minlength", "maxlength", "max-consecutive", "max-repeating", "max-sequential", "upper", "lower",
                      "digit", "special", "ascii-printable", "unicode", "[", "]", "[-", "]]", ":", ";", ",", " ", "-", "9", "0", "é", "😀",
                      "\n", "\u{0}", "99999999999999999999", "abc",
        ]
        for _ in 0..<3_000 {
            let count = Int.random(in: 0...40, using: &generator)
            let input = (0..<count).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &generator)] }.joined()
            let rules = PasswordRules(parsing: input)
            #expect(rules.allowedCharacters.allSatisfy { (33...126).contains($0) })
            #expect(rules.allowedCharacters == rules.allowedCharacters.sorted())
            _ = rules.accepts(Array("Aa1-Aa1-".utf8))
        }
        for bytes in 0..<500 {
            var raw = [UInt8](repeating: 0, count: bytes % 60)
            for index in raw.indices {
                raw[index] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = PasswordRules(parsing: String(decoding: raw, as: UTF8.self))
        }
    }
}
