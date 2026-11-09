// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// A website's `passwordrules` attribute, parsed natively in Apple's syntax (`required: upper; allowed: [-_.]; minlength: 8`).
///
/// Properties are `required`, `allowed`, `minlength`, `maxlength`, `max-consecutive` and, newer, `max-repeating` and `max-sequential`.
/// Character classes are `upper`, `lower`, `digit`, `special`, `ascii-printable`, `unicode` and custom `[...]` sets. The rules combine as
/// Apple's reference parser combines them: `allowed` sets are joined, each `required` set is its own rule and is also allowed (so
/// `required: upper` alone allows only upper), ascii-printable is allowed only when there is neither an `allowed` nor a `required` set,
/// `minlength` takes the largest value and `maxlength` the smallest.
///
/// Deliberate differences from Apple's parser:
/// - An unknown or broken property, or an unknown class inside a list, is skipped on its own. Apple drops the whole string, and with
///   it a `maxlength`, which is the dangerous loss: a value set by script is not cut to `maxlength`.
/// - WSurf never produces a space or a non-ASCII character, even when the site allows one. Every set is reduced to the ASCII
///   characters 33...126, and `unicode` reads as ascii-printable.
/// - `special` is a subset of Apple's class (which also has `/` and `\`): a password never gets a character the site disallows.
///   Property names are case-insensitive (Apple's are not), which only keeps a rule Apple would drop.
///
/// As in Apple's parser, a `-` in a custom set counts only as its first character; any other is dropped.
///
/// `max-consecutive`, `max-repeating` and `max-sequential` have no published definition: Apple's parser reads them and its tests call
/// them run-length rules. WSurf reads `max-consecutive` as the longest run of one identical character, `max-sequential` as the longest
/// run of neighbouring code points, ascending or descending (`abc`, `321`), and `max-repeating` as how often any one character may
/// occur in the whole password, the strictest reading, so a password that meets it meets a per-run reading too.
nonisolated struct PasswordRules: Equatable, Sendable {
    /// Input longer than this (in UTF-8 bytes, which bounds the parse work however the text is built) is ignored as a whole: the rules are empty.
    static let maximumInputLength = 1_000

    static let asciiPrintable: [UInt8] = Array(33...126)
    static let upper: [UInt8] = Array(65...90)
    static let lower: [UInt8] = Array(97...122)
    static let digit: [UInt8] = Array(48...57)
    /// Apple's documented `special` list (`-~!@#$%^&*_+=`|(){}[:;"'<>,.? ]`) without its space. The reference parser's class also has
    /// `/` and `\`; this subset never produces a character a site's `special` would not allow.
    static let special: [UInt8] = Array("-~!@#$%^&*_+=`|(){}[:;\"'<>,.?]".utf8)

    /// Each `allowed` set, in order. Empty when the rules name none.
    private(set) var allowedSets: [[UInt8]] = []
    /// Each `required` set, in order. A password must hold at least one character of every one of them.
    private(set) var requiredSets: [[UInt8]] = []
    private(set) var minLength: Int?
    private(set) var maxLength: Int?
    private(set) var maxConsecutive: Int?
    private(set) var maxRepeating: Int?
    private(set) var maxSequential: Int?

    /// True when no property was read.
    var isEmpty: Bool {
        self == PasswordRules()
    }

    /// Every character a password may hold, ascending and without repeats: the `allowed` sets and the `required` sets joined, or
    /// ascii-printable when the rules name neither.
    var allowedCharacters: [UInt8] {
        let sets = allowedSets + requiredSets
        return sets.isEmpty ? Self.asciiPrintable : Self.normalized(sets.flatMap { $0 })
    }

    init() {}

    init(parsing text: String) {
        guard text.utf8.count <= Self.maximumInputLength else { return }
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index] == ";" || characters[index].isWhitespace {
                index += 1
            }
            guard index < characters.count else { break }
            let nameStart = index
            while index < characters.count, characters[index] != ":", characters[index] != ";" {
                index += 1
            }
            guard index < characters.count, characters[index] == ":" else { continue }
            let name = String(characters[nameStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let read = Self.readValues(characters, from: index + 1)
            index = read.end
            apply(name, read.values)
        }
    }

    /// True when the password uses only allowed characters, holds a character of every required set, and keeps the three limits. The
    /// length bounds are not checked here: the generator combines them with the field's own.
    func accepts(_ password: [UInt8]) -> Bool {
        Matcher(self).accepts(password)
    }

    // MARK: Parsing

    private enum Value {
        case word(String)
        case custom([UInt8])
    }

    private mutating func apply(_ name: String, _ values: [Value]) {
        switch name {
        case "required":
            requiredSets += values.compactMap(Self.set(for:))
        case "allowed":
            allowedSets += values.compactMap(Self.set(for:))
        case "minlength":
            guard let number = Self.number(values) else { return }
            minLength = max(minLength ?? number, number)
        case "maxlength":
            guard let number = Self.number(values) else { return }
            maxLength = min(maxLength ?? number, number)
        case "max-consecutive":
            guard let number = Self.number(values) else { return }
            maxConsecutive = min(maxConsecutive ?? number, number)
        case "max-repeating":
            guard let number = Self.number(values) else { return }
            maxRepeating = min(maxRepeating ?? number, number)
        case "max-sequential":
            guard let number = Self.number(values) else { return }
            maxSequential = min(maxSequential ?? number, number)
        default:
            break
        }
    }

    private static func set(for value: Value) -> [UInt8]? {
        switch value {
        case let .custom(set):
            return set
        case let .word(word):
            switch word {
            case "upper":
                return upper
            case "lower":
                return lower
            case "digit":
                return digit
            case "special":
                return special
            case "ascii-printable", "unicode":
                return asciiPrintable
            default:
                return nil
            }
        }
    }

    /// A single positive integer, or nil.
    private static func number(_ values: [Value]) -> Int? {
        guard values.count == 1, case let .word(word) = values[0], word.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(word), number >= 1 else { return nil }
        return min(number, 1_000_000)
    }

    /// The comma-separated values of one property, up to its `;` (consumed) or the end. A `[` with no closing bracket ends the
    /// property: the rest of it, up to the next `;`, is skipped.
    private static func readValues(_ characters: [Character], from start: Int) -> (values: [Value], end: Int) {
        var index = start
        var values: [Value] = []
        while true {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            if index < characters.count, characters[index] == "[" {
                guard let close = closingBracket(characters, after: index) else {
                    while index < characters.count, characters[index] != ";" {
                        index += 1
                    }
                    return (values, min(index + 1, characters.count))
                }
                // A `-` counts only as the first character of the set; Apple drops any other.
                let content = Array(characters[(index + 1)..<close].flatMap { $0.utf8 })
                let hyphen = UInt8(ascii: "-")
                values.append(.custom(normalized(content.enumerated().filter { $0.offset == 0 || $0.element != hyphen }.map(\.element))))
                index = close + 1
            } else {
                let wordStart = index
                while index < characters.count, characters[index] != ",", characters[index] != ";" {
                    index += 1
                }
                let word = String(characters[wordStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !word.isEmpty {
                    values.append(.word(word))
                }
            }
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            if index < characters.count, characters[index] == "," {
                index += 1
                continue
            }
            return (values, min(index + 1, characters.count))
        }
    }

    /// The `]` that closes the custom set opened at `open`: the first one followed, past spaces, by `,`, `;` or the end. That keeps
    /// `[-abc]`, `[]abc]` and `[abc]]` working, a set may hold the `]` itself.
    private static func closingBracket(_ characters: [Character], after open: Int) -> Int? {
        var index = open + 1
        while index < characters.count {
            if characters[index] == "]" {
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace {
                    next += 1
                }
                if next == characters.count || characters[next] == "," || characters[next] == ";" {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    /// The ASCII characters 33...126 of `bytes`, ascending, once each.
    static func normalized(_ bytes: [UInt8]) -> [UInt8] {
        Array(Set(bytes.filter { (33...126).contains($0) })).sorted()
    }

    // MARK: Matching

    /// The rules as lookup tables, built once for the thousands of candidates a draw tests.
    struct Matcher {
        private let allowed: [Bool]
        private let required: [[Bool]]
        private let maxConsecutive: Int?
        private let maxRepeating: Int?
        private let maxSequential: Int?

        init(_ rules: PasswordRules) {
            allowed = Self.table(rules.allowedCharacters)
            required = rules.requiredSets.map(Self.table)
            maxConsecutive = rules.maxConsecutive
            maxRepeating = rules.maxRepeating
            maxSequential = rules.maxSequential
        }

        func accepts(_ password: [UInt8]) -> Bool {
            guard password.allSatisfy({ allowed[Int($0)] }) else { return false }
            for set in required where !password.contains(where: { set[Int($0)] }) {
                return false
            }
            if let limit = maxConsecutive, Self.longestRun(password, step: 0) > limit {
                return false
            }
            if let limit = maxSequential, max(Self.longestRun(password, step: 1), Self.longestRun(password, step: -1)) > limit {
                return false
            }
            if let limit = maxRepeating {
                var counts = [Int](repeating: 0, count: 256)
                for byte in password {
                    counts[Int(byte)] += 1
                    if counts[Int(byte)] > limit {
                        return false
                    }
                }
            }
            return true
        }

        private static func table(_ set: [UInt8]) -> [Bool] {
            var table = [Bool](repeating: false, count: 256)
            for byte in set {
                table[Int(byte)] = true
            }
            return table
        }

        /// The longest run in which every character is `step` above the one before it.
        private static func longestRun(_ password: [UInt8], step: Int) -> Int {
            guard !password.isEmpty else { return 0 }
            var longest = 1
            var current = 1
            for index in 1..<password.count {
                if Int(password[index]) - Int(password[index - 1]) == step {
                    current += 1
                    longest = max(longest, current)
                } else {
                    current = 1
                }
            }
            return longest
        }
    }
}
