// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

// Which saved passwords are weak or used on more than one website (`ProfileVaultStore+Health.swift`). Only flags leave the vault: a
// report holds no password, digest, length or entropy, so nothing in it can be turned back into a password.

/// The findings for one vault at one revision. Only live credentials with a password and at least one finding are listed.
public nonisolated struct PasswordHealthReport: Equatable, Sendable {
    public let vaultID: UUID
    /// The revision the findings describe.
    public let revision: UInt64
    public let findings: [UUID: PasswordHealthFinding]
}

/// Why one credential's password is listed.
public nonisolated struct PasswordHealthFinding: Equatable, Sendable {
    /// The same password is saved for another website; `nil` when it is not.
    public let reuse: PasswordReuse?
    public let weaknesses: Set<PasswordWeakness>
}

/// The credentials whose reuse has the same `group` share one password. The group is random for each report and says nothing about the
/// password.
public nonisolated struct PasswordReuse: Equatable, Sendable {
    public let group: UUID
    /// How many other websites (registrable domains) the same password is saved for.
    public let otherSites: Int
}

public nonisolated enum PasswordWeakness: String, CaseIterable, Sendable {
    /// Shorter than 8 characters, the minimum NIST SP 800-63B sets for a memorized secret.
    case short
    /// Shorter than 12 characters and of one kind only: all digits, all lowercase or all uppercase letters.
    case oneKind
    /// At least half of it is a pattern: a chunk of one to three characters repeated (`aaaa`, `abcabc`), or a run of six or more along
    /// the alphabet, the digits or a keyboard row (`abcdef`, `123456`, `qwerty`), either way.
    case pattern
    /// It holds the username (for an email, the part before "@") or the name of the credential's website, at least 4 characters of
    /// either, ignoring case.
    case personal
}

/// The rules behind a report. Pure, so the vault actor runs them over the passwords it already holds. They read a password's UTF-8
/// bytes, through buffer pointers in the loops, so no character is broken out and nothing is bridged. Over 20,000 logins that takes
/// 0.13 s in the tests' Debug build with coverage (0.49 s when written over Characters) and about 0.02 s optimized (0.12 s). Every
/// pointer read is below its buffer's count, and a step table index below 128 × 128.
public nonisolated enum PasswordHealth {
    /// The findings for `accounts`. `registrableDomain` names a host's website, as `RelyingPartyPolicy.registrableDomain` does; a host
    /// it has no answer for is a website of its own. The suffix list behind it is read only where a rule needs it: for the logins of
    /// a shared password, and for a password that holds a label of its own website's host.
    public static func report(
        vaultID: UUID, revision: UInt64, accounts: [CredentialAccount],
        registrableDomain: (String) -> String? = RelyingPartyPolicy.registrableDomain(of:)
    ) -> PasswordHealthReport {
        var siteOfHost: [String: String] = [:]
        func site(of host: String) -> String {
            if let known = siteOfHost[host] {
                return known
            }
            let site = registrableDomain(host) ?? host
            siteOfHost[host] = site
            return site
        }
        // The logins with a password, by their index in `accounts`, and each password's logins.
        var logins: [(account: Int, password: String)] = []
        var holders: [String: [Int]] = [:]
        for (index, account) in accounts.enumerated() {
            guard let password = account.password, !password.isEmpty else { continue }
            holders[password, default: []].append(logins.count)
            logins.append((index, password))
        }
        var reuse: [Int: PasswordReuse] = [:]
        for members in holders.values where members.count > 1 {
            // A credential without a website is a website of its own.
            let sites = members.map { member -> Set<String> in
                let account = accounts[logins[member].account]
                let hosts = hosts(of: account)
                return hosts.isEmpty ? ["\u{0}\(account.id)"] : Set(hosts.map { site(of: $0) })
            }
            let all = sites.reduce(into: Set<String>()) { $0.formUnion($1) }
            guard all.count > 1 else { continue }
            let group = UUID()
            for (member, own) in zip(members, sites) {
                // `own` is part of `all`, so a count is enough: building `all` minus `own` for every login would grow with the square
                // of the logins sharing one password.
                let others = all.count - own.count
                if others > 0 {
                    reuse[member] = PasswordReuse(group: group, otherSites: others)
                }
            }
        }
        var findings: [UUID: PasswordHealthFinding] = [:]
        for (index, login) in logins.enumerated() {
            let account = accounts[login.account]
            let lowered = loweredBytes(login.password)
            let names = siteNames(of: account, in: lowered) { site(of: $0) }
            let weaknesses = weaknesses(of: login.password, lowered: lowered, username: account.username, siteNames: names)
            if reuse[index] != nil || !weaknesses.isEmpty {
                findings[account.id] = PasswordHealthFinding(reuse: reuse[index], weaknesses: weaknesses)
            }
        }
        return PasswordHealthReport(vaultID: vaultID, revision: revision, findings: findings)
    }

    /// Whether `report` would read the same of `saved` as of `stored`, the credential it replaces. `report` reads a credential's id,
    /// password, username and websites (`origins`, which hold its login addresses' origins), and nothing else; the login addresses
    /// are compared too, as editing them edits the websites. Text is compared byte for byte, as the rules read it: a username typed
    /// again in another Unicode normalization form is the same `String`, but not the same bytes. A new credential (`stored` is `nil`)
    /// counts as a change. A page that shows findings under one Touch ID prompt carries that prompt only across its own saves where
    /// this holds (`CredentialSettingsModel.save`): a password, username or website saved as a guess would show whether the password
    /// is another website's too (`reuse`) or holds the guess (`personal`).
    public static func sameInputs(_ stored: CredentialAccount?, _ saved: CredentialAccount) -> Bool {
        guard let stored else { return false }
        return stored.id == saved.id && sameBytes(stored.password, saved.password) && sameBytes(stored.username, saved.username)
            && stored.origins.count == saved.origins.count && zip(stored.origins, saved.origins).allSatisfy { sameBytes($0, $1) }
            && stored.loginURLs == saved.loginURLs
    }

    /// Whether two texts hold the same UTF-8 bytes; `nil` is the same only as `nil`.
    private static func sameBytes(_ first: String?, _ second: String?) -> Bool {
        switch (first, second) {
        case (nil, nil):
            true
        case let (first?, second?):
            first.utf8.elementsEqual(second.utf8)
        default:
            false
        }
    }

    /// The lowercased hosts of a credential's websites: its origins, which hold its login addresses' origins too
    /// (`CredentialAccount.validate()`, which every commit runs, refuses a login address whose origin is not among them).
    static func hosts(of account: CredentialAccount) -> [String] {
        account.origins.compactMap { hostBytes(of: $0).map { String(decoding: $0, as: UTF8.self) } }
    }

    /// An origin's host as lowercased bytes, read without parsing a URL: what follows "://", up to a port or a path
    /// (`https://login.example.com:8443` is `login.example.com`). An address in brackets has no name, so it has none here.
    static func hostBytes(of origin: String) -> [UInt8]? {
        let bytes = Array(origin.utf8)
        let colon = UInt8(ascii: ":"), slash = UInt8(ascii: "/"), bracket = UInt8(ascii: "[")
        return bytes.withUnsafeBufferPointer { buffer -> [UInt8]? in
            guard let text = buffer.baseAddress else { return nil }
            let count = buffer.count
            var start = 0
            while start + 2 < count, text[start] != colon || text[start + 1] != slash || text[start + 2] != slash {
                start += 1
            }
            start += 3
            var end = start
            while end < count, text[end] != colon, text[end] != slash {
                end += 1
            }
            guard end > start, text[start] != bracket else { return nil }
            var host = [UInt8](repeating: 0, count: end - start)
            host.withUnsafeMutableBufferPointer { target in
                guard let target = target.baseAddress else { return }
                var index = 0
                while index < end - start {
                    let byte = text[start + index]
                    target[index] = byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
                    index += 1
                }
            }
            return host
        }
    }

    /// The names of `account`'s websites (`example` for `login.example.co.uk`) that `lowered` might hold. Only a host with a label of
    /// at least 4 characters in the password is named through `site`, so most logins read no suffix list at all.
    static func siteNames(of account: CredentialAccount, in lowered: [UInt8], site: (String) -> String) -> [String] {
        var names: [String] = []
        for origin in account.origins {
            guard let host = hostBytes(of: origin), holdsALabel(of: host, in: lowered),
                  let name = site(String(decoding: host, as: UTF8.self)).split(separator: ".").first
            else { continue }
            names.append(String(name))
        }
        return names
    }

    /// Whether `lowered` holds a label of `host` (the bytes between its dots) of at least 4 bytes.
    private static func holdsALabel(of host: [UInt8], in lowered: [UInt8]) -> Bool {
        var start = 0
        while start < host.count {
            var end = start
            while end < host.count, host[end] != dot {
                end += 1
            }
            if end - start >= 4, contains(lowered, host, start, end) {
                return true
            }
            start = end + 1
        }
        return false
    }

    /// Whether `needle[from..<to]` occurs in `haystack`, byte for byte.
    static func contains(_ haystack: [UInt8], _ needle: [UInt8], _ from: Int, _ to: Int) -> Bool {
        let length = to - from
        guard length > 0 else { return true }
        guard length <= haystack.count else { return false }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { word in
                guard let hay = hay.baseAddress, let word = word.baseAddress?.advanced(by: from) else { return false }
                var start = 0
                while start <= haystack.count - length {
                    if hay[start] == word[0] {
                        var offset = 1
                        while offset < length, hay[start + offset] == word[offset] {
                            offset += 1
                        }
                        if offset == length {
                            return true
                        }
                    }
                    start += 1
                }
                return false
            }
        }
    }

    private static let dot = UInt8(ascii: ".")

    /// The weak rules for one password. `siteNames` are the credential's websites without their suffix (`example` for `example.co.uk`).
    public static func weaknesses(of password: String, username: String, siteNames: [String]) -> Set<PasswordWeakness> {
        weaknesses(of: password, lowered: loweredBytes(password), username: username, siteNames: siteNames)
    }

    private static func weaknesses(of password: String, lowered: [UInt8], username: String, siteNames: [String]) -> Set<PasswordWeakness> {
        let ascii = isASCII(lowered)
        let length = ascii ? lowered.count : password.count
        var found = Set<PasswordWeakness>()
        if length < 8 {
            found.insert(.short)
        }
        if length < 12, ascii ? isOneKind(ascii: password.utf8) : isOneKind(Array(password)) {
            found.insert(.oneKind)
        }
        if isMostlyPattern(lowered) {
            found.insert(.pattern)
        }
        if isPersonal(lowered, username: username, siteNames: siteNames) {
            found.insert(.personal)
        }
        return found
    }

    /// Whether every byte is ASCII. Lowercasing keeps ASCII text ASCII, so the lowered bytes answer for the password.
    private static func isASCII(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return true }
            var index = 0
            while index < buffer.count {
                if base[index] >= 0x80 {
                    return false
                }
                index += 1
            }
            return true
        }
    }

    /// The UTF-8 bytes of `text` with its letters lowercased: by hand for ASCII text, through `lowercased()` otherwise.
    static func loweredBytes(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        let ascii = bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var index = 0
            while index < buffer.count {
                let byte = base[index]
                if byte >= 0x80 {
                    return false
                }
                if byte >= 0x41 && byte <= 0x5A {
                    base[index] = byte + 0x20
                }
                index += 1
            }
            return true
        }
        return ascii ? bytes : Array(text.lowercased().utf8)
    }

    /// All digits, all lowercase or all uppercase letters, for an ASCII password.
    private static func isOneKind(ascii bytes: String.UTF8View) -> Bool {
        let kinds = [UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z")]
        return !bytes.isEmpty && kinds.contains { kind in bytes.allSatisfy(kind.contains) }
    }

    /// The same, for a password with any other character: digits are ASCII digits, and letters may be any letters.
    static func isOneKind(_ characters: [Character]) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.allSatisfy { $0.isASCII && $0.isNumber }
            || characters.allSatisfy { $0.isLetter && $0.isLowercase }
            || characters.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// The sequences a run follows, either way: the alphabet, the digits, and the keyboard's rows (`1234567890` is the digit row).
    private static let sequences = ["abcdefghijklmnopqrstuvwxyz", "0123456789", "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]

    /// For each pair of ASCII bytes, the (sequence, direction) pairs along which the second follows the first, as bits: bit
    /// 2 × the sequence's index forwards, the bit after it backwards. Made once.
    private static let stepTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 128 * 128)
        for (number, sequence) in sequences.enumerated() {
            let bytes = Array(sequence.utf8)
            for (from, to) in zip(bytes, bytes.dropFirst()) {
                table[Int(from) << 7 | Int(to)] |= 1 << (number * 2)
                table[Int(to) << 7 | Int(from)] |= 1 << (number * 2 + 1)
            }
        }
        return table
    }()

    /// Whether at least half of the lowercased password's bytes are a repeated chunk or a run along a sequence.
    static func isMostlyPattern(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        let count = bytes.count
        var covered = [Bool](repeating: false, count: count)
        let marked = bytes.withUnsafeBufferPointer { text in
            covered.withUnsafeMutableBufferPointer { marks -> Int in
                guard let text = text.baseAddress, let marks = marks.baseAddress else { return 0 }
                markRepeats(text, count, marks)
                stepTable.withUnsafeBufferPointer { table in
                    if let table = table.baseAddress {
                        markRuns(text, count, marks, table)
                    }
                }
                var marked = 0
                var index = 0
                while index < count {
                    if marks[index] {
                        marked += 1
                    }
                    index += 1
                }
                return marked
            }
        }
        return marked * 2 >= count
    }

    /// A chunk of one to three bytes said again and again: at least 4 bytes in all, and the chunk at least twice.
    private static func markRepeats(_ text: UnsafePointer<UInt8>, _ count: Int, _ marks: UnsafeMutablePointer<Bool>) {
        var length = 1
        while length <= 3 {
            var start = 0
            while start + length < count {
                var end = start + length
                while end < count, text[end] == text[end - length] {
                    end += 1
                }
                if end - start >= 4, end - start >= 2 * length {
                    var index = start
                    while index < end {
                        marks[index] = true
                        index += 1
                    }
                    start = end
                } else {
                    start += 1
                }
            }
            length += 1
        }
    }

    /// Six or more bytes that each step to the next (or the previous) one of the same sequence.
    private static func markRuns(
        _ text: UnsafePointer<UInt8>, _ count: Int, _ marks: UnsafeMutablePointer<Bool>, _ table: UnsafePointer<UInt16>
    ) {
        guard count > 1 else { return }
        var start = 0
        // The (sequence, direction) bits every step of the current run follows; 0 while no run has started.
        var ways: UInt16 = 0
        var index = 1
        while index <= count {
            var step: UInt16 = 0
            if index < count {
                let from = text[index - 1], to = text[index]
                step = from < 0x80 && to < 0x80 ? table[Int(from) << 7 | Int(to)] : 0
            }
            let kept = ways == 0 ? step : ways & step
            if kept == 0 || index == count {
                // The run so far ends before `index`.
                if ways != 0, index - start >= 6 {
                    var marked = start
                    while marked < index {
                        marks[marked] = true
                        marked += 1
                    }
                }
                start = step == 0 ? index : index - 1
                ways = step
            } else {
                ways = kept
            }
            index += 1
        }
    }

    /// The username before any "@", or a website's name, of at least 4 characters, anywhere in the lowercased password.
    static func isPersonal(_ lowered: [UInt8], username: String, siteNames: [String]) -> Bool {
        let local = username.firstIndex(of: "@").map { String(username[..<$0]) } ?? username
        return ([local] + siteNames).contains { word in
            guard word.count >= 4 else { return false }
            let bytes = loweredBytes(word)
            return contains(lowered, bytes, 0, bytes.count)
        }
    }
}
