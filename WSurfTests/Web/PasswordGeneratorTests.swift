// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import os
import Testing

@testable import WSurf

/// U2-U6: the default format, every format against a corpus of rule sets, the length bounds, the random source, and the redacted value.
@Suite
struct PasswordGeneratorTests {
    private static let lookAlikes = Set("01loI".utf8)

    private func make(
        _ format: PasswordFormat,
        _ rules: String = "",
        length: Int = PasswordGenerator.defaultLength,
        field: PasswordFieldLimits = PasswordFieldLimits(),
        seed: UInt64
    ) -> [UInt8]? {
        var generator = SplitMix64(seed: seed)
        return PasswordGenerator.generate(format, length: length, rules: PasswordRules(parsing: rules), field: field, using: &generator)
            .map { Array($0.revealed.utf8) }
    }

    private func isPlainAscii(_ password: [UInt8]) -> Bool {
        password.allSatisfy { (33...126).contains($0) }
    }

    // MARK: U2

    @Test
    func defaultFormatHasItsShape() throws {
        for seed in 0..<2_000 as Range<UInt64> {
            let password = try #require(make(.easyToType, seed: seed))
            let text = String(decoding: password, as: UTF8.self)
            #expect(password.count == 20)
            #expect(text.split(separator: "-", omittingEmptySubsequences: false).map(\.count) == [6, 6, 6])
            let letters = password.filter { (65...90).contains($0) || (97...122).contains($0) }
            let capitals = password.filter { (65...90).contains($0) }
            #expect(capitals.count == 1)
            #expect(capitals.first != UInt8(ascii: "I"))
            #expect(letters.count == capitals.count + password.filter { (97...122).contains($0) }.count)
            #expect(password.contains { (50...57).contains($0) })
            #expect(!password.contains { Self.lookAlikes.contains($0) })
            #expect(password.filter { $0 == UInt8(ascii: "-") }.count == 2)
            let others = password.filter { $0 != UInt8(ascii: "-") && !(65...90).contains($0) }
            #expect(others.allSatisfy { (97...122).contains($0) || (50...57).contains($0) })
        }
    }

    @Test
    func defaultFormatScalesItsGroupsWithTheLength() throws {
        for length in 2...64 {
            // Below the sheet's 12 only the field's own limit asks for a length.
            let field = length < PasswordGenerator.lengthRange.lowerBound ? PasswordFieldLimits(maxLength: length) : PasswordFieldLimits()
            let password = try #require(make(.easyToType, length: length, field: field, seed: UInt64(length)))
            #expect(password.count == length)
            let groups = String(decoding: password, as: UTF8.self).split(separator: "-", omittingEmptySubsequences: false)
            #expect(groups.count == max(1, (length + 1) / 7))
            #expect(groups.allSatisfy { !$0.isEmpty })
        }
        // One character cannot hold the digit and the capital the format needs; only a site's own limit gets below the sheet's 12.
        #expect(make(.easyToType, field: PasswordFieldLimits(maxLength: 1), seed: 1) == nil)
        #expect(make(.easyToType, length: 4, seed: 1)?.count == 12)
        #expect(make(.lettersAndDigits, length: 500, seed: 1)?.count == 64)
    }

    // MARK: U3

    @Test
    func everyFormatMeetsItsClasses() throws {
        for seed in 0..<10_000 as Range<UInt64> {
            let letters = try #require(make(.lettersAndDigits, seed: seed))
            #expect(letters.count == 20)
            #expect(letters.contains { PasswordRules.lower.contains($0) })
            #expect(letters.contains { PasswordRules.upper.contains($0) })
            #expect(letters.contains { PasswordRules.digit.contains($0) })
            #expect(letters.allSatisfy { PasswordRules.lower.contains($0) || PasswordRules.upper.contains($0) || PasswordRules.digit.contains($0) })
            #expect(!letters.contains { Self.lookAlikes.contains($0) })

            let symbols = try #require(make(.withSymbols, seed: seed))
            #expect(symbols.count == 20)
            #expect(symbols.contains { PasswordRules.lower.contains($0) })
            #expect(symbols.contains { PasswordRules.upper.contains($0) })
            #expect(symbols.contains { PasswordRules.digit.contains($0) })
            #expect(symbols.contains { Array("-_.!@#$%*+=?".utf8).contains($0) })
            #expect(symbols.allSatisfy { isPlainAscii([$0]) && !Self.lookAlikes.contains($0) })
        }
    }

    /// Checks a password against the rules text on its own, without the parser's matcher.
    private func violations(_ password: [UInt8], allowed: Set<UInt8>, required: [Set<UInt8>], consecutive: Int?, repeating: Int?, sequential: Int?) -> [String] {
        var found: [String] = []
        if !isPlainAscii(password) { found.append("not plain ascii") }
        if !password.allSatisfy(allowed.contains) { found.append("character not allowed") }
        for set in required where !password.contains(where: set.contains) {
            found.append("required set missing")
        }
        var run = 1
        var up = 1
        var down = 1
        var longest = (run: 1, up: 1, down: 1)
        for index in 1..<max(password.count, 1) {
            let delta = Int(password[index]) - Int(password[index - 1])
            run = delta == 0 ? run + 1 : 1
            up = delta == 1 ? up + 1 : 1
            down = delta == -1 ? down + 1 : 1
            longest = (max(longest.run, run), max(longest.up, up), max(longest.down, down))
        }
        // Apple: max-repeating limits identical runs, max-sequential sequences, and max-consecutive is an alias for both.
        let identical = [consecutive, repeating].compactMap { $0 }.min()
        let sequence = [consecutive, sequential].compactMap { $0 }.min()
        if let identical, longest.run > identical { found.append("identical run") }
        if let sequence, max(longest.up, longest.down) > sequence { found.append("sequential run") }
        return found
    }

    private struct CorpusEntry {
        let rules: String
        let allowed: Set<UInt8>
        let required: [Set<UInt8>]
        let lengths: ClosedRange<Int>
        var consecutive: Int?
        var repeating: Int?
        var sequential: Int?

        init(_ rules: String, _ allowed: Set<UInt8>, _ required: [Set<UInt8>], _ lengths: ClosedRange<Int>,
             consecutive: Int? = nil, repeating: Int? = nil, sequential: Int? = nil) {
            self.rules = rules
            self.allowed = allowed
            self.required = required
            self.lengths = lengths
            self.consecutive = consecutive
            self.repeating = repeating
            self.sequential = sequential
        }
    }

    @Test
    func rulesCorpusIsAlwaysMet() throws {
        let upper = Set(PasswordRules.upper)
        let lower = Set(PasswordRules.lower)
        let digit = Set(PasswordRules.digit)
        let special = Set(PasswordRules.special)
        let printable = Set(PasswordRules.asciiPrintable)
        let dash = Set([UInt8(ascii: "-")])
        let corpus: [CorpusEntry] = [
            CorpusEntry("required: lower; required: upper; required: digit; required: [-]; minlength: 8; maxlength: 20",
                        lower.union(upper).union(digit).union(dash), [lower, upper, digit, dash], 8...20),
            CorpusEntry("allowed: lower, digit; maxlength: 12", lower.union(digit), [], 1...12),
            CorpusEntry("required: upper; required: lower; required: digit; required: special; max-consecutive: 2; minlength: 10; maxlength: 16",
                        upper.union(lower).union(digit).union(special), [upper, lower, digit, special], 10...16, consecutive: 2),
            CorpusEntry("allowed: [abcdefghij]; max-repeating: 3; minlength: 12", Set("abcdefghij".utf8), [], 12...20, repeating: 3),
            CorpusEntry("required: digit; allowed: lower; minlength: 6; maxlength: 6", lower.union(digit), [digit], 6...6),
            CorpusEntry("required: [!@#]; required: upper; allowed: lower, digit; max-sequential: 2",
                        lower.union(digit).union(upper).union(Set("!@#".utf8)), [Set("!@#".utf8), upper], 1...20, sequential: 2),
            CorpusEntry("required: upper; required: lower; required: digit; required: [-_]; maxlength: 8",
                        upper.union(lower).union(digit).union(Set("-_".utf8)), [upper, lower, digit, Set("-_".utf8)], 1...8),
            CorpusEntry("minlength: 30; allowed: ascii-printable; max-consecutive: 1", printable, [], 30...30, consecutive: 1),
            CorpusEntry("required: [0]; allowed: lower", lower.union([UInt8(ascii: "0")]), [Set([UInt8(ascii: "0")])], 1...20),
            CorpusEntry("", printable, [], 20...20),
            CorpusEntry("max-sequential: 1; max-consecutive: 1", printable, [], 20...20, consecutive: 1, sequential: 1),
            CorpusEntry("required: upper; required: lower; required: digit; allowed: [-]; minlength: 8; maxlength: 64",
                        upper.union(lower).union(digit).union(dash), [upper, lower, digit], 8...64),
        ]
        for entry in corpus {
            let rules = PasswordRules(parsing: entry.rules)
            for seed in 0..<1_500 as Range<UInt64> {
                let password = try #require(make(.websiteRules, entry.rules, seed: seed), "no password for \(entry.rules)")
                #expect(entry.lengths.contains(password.count), "length \(password.count) for \(entry.rules)")
                let problems = violations(password, allowed: entry.allowed, required: entry.required, consecutive: entry.consecutive,
                                          repeating: entry.repeating, sequential: entry.sequential)
                #expect(problems.isEmpty, "\(problems) for \(entry.rules)")
                #expect(rules.accepts(password))
            }
        }
    }

    // MARK: U4

    @Test
    func boundsSetTheLength() throws {
        #expect(try #require(make(.websiteRules, "maxlength: 12", seed: 1)).count == 12)
        #expect(try #require(make(.websiteRules, "minlength: 40", seed: 1)).count == 40)
        #expect(try #require(make(.websiteRules, "minlength: 8; maxlength: 64", seed: 1)).count == 20)
        for format in PasswordFormat.allCases {
            #expect(try #require(make(format, field: PasswordFieldLimits(maxLength: 12), seed: 2)).count == 12)
            #expect(try #require(make(format, field: PasswordFieldLimits(maxLength: 8), seed: 2)).count == 8)
            #expect(try #require(make(format, field: PasswordFieldLimits(minLength: 40), seed: 2)).count == 40)
            #expect(try #require(make(format, length: 64, seed: 3)).count == 64)
            #expect(try #require(make(format, length: 12, seed: 3)).count == 12)
        }
        // A bound of the field narrows the website's.
        #expect(try #require(make(.websiteRules, "maxlength: 16", field: PasswordFieldLimits(maxLength: 10), seed: 4)).count == 10)
        #expect(try #require(make(.websiteRules, "minlength: 10", field: PasswordFieldLimits(minLength: 30), seed: 4)).count == 30)
    }

    @Test
    func theFieldWinsAConflictWithTheRules() throws {
        // Rules want at most 8, the field at least 10: the field's limit stands.
        #expect(try #require(make(.websiteRules, "maxlength: 8", field: PasswordFieldLimits(minLength: 10), seed: 5)).count == 20)
        // Rules want at least 30, the field at most 16.
        #expect(try #require(make(.websiteRules, "minlength: 30", field: PasswordFieldLimits(maxLength: 16), seed: 5)).count == 16)
    }

    @Test
    func impossibleRulesGiveNothing() {
        #expect(make(.websiteRules, "allowed: []", seed: 1) == nil)
        #expect(make(.websiteRules, "required: [é]", seed: 1) == nil)
        #expect(make(.websiteRules, "minlength: 40; maxlength: 10", seed: 1) == nil)
        #expect(make(.websiteRules, "minlength: 200", seed: 1) == nil)
        // The field wins wherever it and the rules conflict, also when the rules cannot be met on their own.
        #expect(make(.websiteRules, "minlength: 200", field: PasswordFieldLimits(maxLength: 16), seed: 1)?.count == 16)
        #expect(make(.websiteRules, "minlength: 30", field: PasswordFieldLimits(maxLength: 16), seed: 1)?.count == 16)
        #expect(make(.websiteRules, "required: upper; required: lower; required: digit; required: special; maxlength: 3", seed: 1) == nil)
        #expect(make(.websiteRules, "allowed: [a]; max-repeating: 2; minlength: 20", seed: 1) == nil)
        #expect(make(.websiteRules, "required: [a]; required: [b]; maxlength: 1", seed: 1) == nil)
        #expect(make(.websiteRules, field: PasswordFieldLimits(minLength: 40, maxLength: 16), seed: 1) == nil)
        #expect(make(.easyToType, field: PasswordFieldLimits(minLength: 40, maxLength: 16), seed: 1) == nil)
        // Another format ignores the rules but keeps the field's own maxlength.
        #expect(make(.easyToType, "allowed: []", field: PasswordFieldLimits(maxLength: 9), seed: 1)?.count == 9)
        #expect(make(.withSymbols, "minlength: 40; maxlength: 10", field: PasswordFieldLimits(maxLength: 14), seed: 1)?.count == 14)
    }

    // MARK: U5

    private struct CountingGenerator: RandomNumberGenerator {
        var inner = SystemRandomNumberGenerator()
        var calls = 0

        mutating func next() -> UInt64 {
            calls += 1
            return inner.next()
        }
    }

    @Test
    func onlyThePassedSourceIsUsed() {
        for format in PasswordFormat.allCases {
            var counting = CountingGenerator()
            #expect(PasswordGenerator.generate(format, rules: PasswordRules(parsing: "required: digit"), using: &counting) != nil)
            #expect(counting.calls > 0)

            let first = make(format, "required: digit; required: upper", seed: 99)
            let second = make(format, "required: digit; required: upper", seed: 99)
            let other = make(format, "required: digit; required: upper", seed: 100)
            #expect(first != nil)
            #expect(first == second)
            #expect(first != other)
        }
    }

    @Test
    func theSystemSourceMakesDifferentPasswords() throws {
        let first = try #require(PasswordGenerator.generate(.easyToType)).revealed
        let second = try #require(PasswordGenerator.generate(.easyToType)).revealed
        #expect(first != second)
        #expect(first.count == 20)
    }

    private func chiSquare(_ counts: [Int]) -> Double {
        let total = Double(counts.reduce(0, +))
        let expected = total / Double(counts.count)
        return counts.reduce(0.0) { $0 + ($1.asDouble - expected) * ($1.asDouble - expected) / expected }
    }

    @Test
    func symbolFrequenciesAreUniform() throws {
        // Ten symbols (not a power of two), no other rule: the draw is plain, so every symbol is as likely as any other.
        let symbols = Array("abcdefghij".utf8)
        var counts = [Int](repeating: 0, count: symbols.count)
        for seed in 0..<5_000 as Range<UInt64> {
            for byte in try #require(make(.websiteRules, "allowed: [abcdefghij]", seed: seed)) {
                counts[symbols.firstIndex(of: byte) ?? 0] += 1
            }
        }
        // 9 degrees of freedom: 27.88 is the 0.1 % point.
        #expect(chiSquare(counts) < 27.88)

        // The default format's 32 symbols, letters folded to lowercase. 31 degrees of freedom: 61.10 is the 0.1 % point.
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789".utf8)
        var easy = [Int](repeating: 0, count: alphabet.count)
        for seed in 0..<6_000 as Range<UInt64> {
            for byte in try #require(make(.easyToType, seed: 1_000_000 + seed)) where byte != UInt8(ascii: "-") {
                easy[alphabet.firstIndex(of: byte | 0x20) ?? 0] += 1
            }
        }
        #expect(chiSquare(easy) < 61.10)
    }

    // MARK: Review fixes

    @Test func requiredWithoutAllowedAllowsOnlyTheRequiredClasses() throws {
        // "Letters and digits only", as written on real sites: never a hyphen or a symbol.
        for seed in 0..<1_000 as Range<UInt64> {
            let password = try #require(make(.websiteRules, "minlength: 8; maxlength: 25; required: lower; required: upper; required: digit", seed: seed))
            #expect(password.allSatisfy { PasswordRules.lower.contains($0) || PasswordRules.upper.contains($0) || PasswordRules.digit.contains($0) })
            let symbolsOnly = try #require(make(.websiteRules, "required: [!#$%&()*,.:<>?@^{|}]", seed: seed))
            #expect(symbolsOnly.allSatisfy { Array("!#$%&()*,.:<>?@^{|}".utf8).contains($0) })
        }
    }

    @Test func aNegativeFieldLimitIsAnAbsentOne() throws {
        let absent = PasswordFieldLimits(minLength: -1, maxLength: -1)
        for format in PasswordFormat.allCases {
            #expect(try #require(make(format, field: absent, seed: 8)).count == 20)
        }
    }

    @Test func aSmallAllowedSetKeepsItsLookAlikes() throws {
        var seen = Set<UInt8>()
        for seed in 0..<50 as Range<UInt64> {
            seen.formUnion(try #require(make(.websiteRules, "allowed: [0o1lIa]", seed: seed)))
        }
        #expect(seen == Set("0o1lIa".utf8))
        var digits = Set<UInt8>()
        for seed in 0..<200 as Range<UInt64> {
            digits.formUnion(try #require(make(.websiteRules, "allowed: digit", seed: seed)))
        }
        #expect(digits == Set(PasswordRules.digit))
        // Any permutation of the ten digits meets this, though two of them are look-alikes.
        let permutation = try #require(make(.websiteRules, "allowed: digit; minlength: 10; maxlength: 10; max-repeating: 1", seed: 3))
        #expect(permutation.count == 10)
        #expect(zip(permutation, permutation.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test func everyFormatKeepsTheWebsitesMaxlength() throws {
        for format in PasswordFormat.allCases {
            #expect(try #require(make(format, "maxlength: 16", seed: 6)).count == 16)
            #expect(try #require(make(format, "maxlength: 16", field: PasswordFieldLimits(maxLength: 10), seed: 6)).count == 10)
        }
        // A website's rules that contradict themselves are ignored by the formats that ignore its characters.
        #expect(make(.easyToType, "minlength: 40; maxlength: 10", seed: 6)?.count == 20)
        #expect(make(.websiteRules, "minlength: 40; maxlength: 10", seed: 6) == nil)
    }

    @Test func requiredCharactersLandAnywhere() throws {
        // A repair such as "put the digit first when none was drawn" would pile the digits up at the start. 19 degrees of freedom:
        // 43.82 is the 0.1 % point.
        var digitsAt = [Int](repeating: 0, count: 20)
        for seed in 0..<6_000 as Range<UInt64> {
            let password = try #require(make(.withSymbols, seed: 2_000_000 + seed))
            for (index, byte) in password.enumerated() where PasswordRules.digit.contains(byte) {
                digitsAt[index] += 1
            }
        }
        #expect(chiSquare(digitsAt) < 43.82)

        // The capital of the default format over its 18 drawn slots (the hyphens are not slots): the draws are exchangeable, so every
        // slot is as likely. 17 degrees of freedom: 40.79 is the 0.1 % point.
        var capitalAt = [Int](repeating: 0, count: 18)
        for seed in 0..<6_000 as Range<UInt64> {
            let password = try #require(make(.easyToType, seed: 3_000_000 + seed))
            let slots = password.filter { $0 != UInt8(ascii: "-") }
            capitalAt[try #require(slots.firstIndex { PasswordRules.upper.contains($0) })] += 1
        }
        #expect(capitalAt.allSatisfy { $0 > 0 })
        #expect(chiSquare(capitalAt) < 40.79, "the capital's slot is skewed: \(capitalAt)")
    }

    // MARK: U6

    @Test
    func aGeneratedPasswordHidesItsValue() throws {
        let value = "Zq7-hidden-Value-93"
        let password = GeneratedPassword(Array(value.utf8))
        #expect(password.revealed == value)

        var texts: [String] = [
            password.description,
            password.debugDescription,
            "\(password)",
            "value: \(password)",
            String(describing: password),
            String(reflecting: password),
            String(describing: Optional(password) as Any),
            String(describing: [password]),
            String(describing: ["key": password]),
        ]
        var dumped = ""
        dump(password, to: &dumped)
        texts.append(dumped)
        var dumpedWrapped = ""
        dump([Optional(password)], to: &dumpedWrapped)
        texts.append(dumpedWrapped)
        var printed = ""
        print(password, to: &printed)
        debugPrint(password, to: &printed)
        texts.append(printed)
        texts.append(Mirror(reflecting: password).children.map { "\($0.label ?? "") \($0.value)" }.joined())

        for text in texts {
            #expect(!text.contains("Zq7"))
            #expect(!text.contains("hidden"))
            #expect(!text.contains(value))
        }
        #expect(password.description == "GeneratedPassword")
        #expect(Mirror(reflecting: password).children.isEmpty)

        // A Logger interpolation takes a CustomStringConvertible and reads `description`: the generic call below has the same constraint,
        // so what it returns is what a public interpolation would log. The Logger line proves the type still compiles there.
        func logged<Value: CustomStringConvertible>(_ value: Value) -> String {
            value.description
        }
        #expect(logged(password) == "GeneratedPassword")
        Logger(subsystem: "app.wsurf.tests", category: "password-generator").debug("\(password, privacy: .public)")
    }
}

private extension Int {
    var asDouble: Double {
        Double(self)
    }
}
