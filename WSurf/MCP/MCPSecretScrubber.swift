// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import MCP
import os

/// The test secrets one connection typed into a page, and the one place that hides them again.
///
/// A secret is registered the moment a call asks to type it. From then on `MCPBrowserSession.call` runs every result through
/// `scrub(_:)` before it leaves WSurf, so a page that echoes the value into its text, its title, a console line or a URL
/// still cannot hand it back. The match is on the exact registered value, in the forms it takes once something encodes it:
/// as typed, with whitespace collapsed, percent-encoded, JSON-escaped, HTML-escaped, and those layered (a JSON text block
/// carries an HTML-escaped page). Matching ignores ASCII case, because a page can upper-case what it shows. It is not a
/// heuristic: a secret nobody registered is not recognised here, which is why the Developer tier is the only way to type one.
///
/// The registry is agent-controlled: the agent chooses what it registers. That is harmless for what the agent itself is told,
/// where hiding a value only blinds the agent, and wrong for anything the user relies on. A record of what the agent did (an
/// approval it skipped, an activity entry, a consent) must never go through `scrub(_:)`, or the agent could erase a record by
/// registering its text. Those records use `scrubForAudit(_:)`, which hides only the values that were written into a password,
/// code or card field (`confirm(_:)`, called after the write) and puts a visible marker where it hid one, so the record still
/// says what happened.
///
/// Nothing is stored anywhere but in this object. It keeps byte copies that `wipe()` overwrites before releasing them (a Swift
/// `String` cannot be overwritten, so the registry never keeps one), and it prints as a count, never as its content, so a log
/// line, a dump or a crash report that mentions the registry shows no secret.
///
/// Integration points for code that produces text outside a tool result. Text that goes back to the agent (a diagnostics
/// record, a change report built from page values) is cleaned with `scrub(_:)`, through `MCPBrowserSession.scrubbed(_:)`. Text
/// the user reads as a record of the agent's actions (an activity entry's tab title or target, an approval label) is cleaned
/// with `scrubForAudit(_:)`, through `MCPBrowserSession.scrubbedForAudit(_:)`.
nonisolated final class MCPSecretScrubber: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// What replaces a secret in any output.
    static let replacement = "‹secret›"
    /// What replaces a confirmed secret in a record the user reads: visibly a hidden value, so the record cannot be mistaken for
    /// an empty one.
    static let auditReplacement = "‹hidden secret›"
    /// A shorter value cannot be hidden without destroying ordinary output (`[12]`, ports, counts), so it is never typed.
    static let minimumBytes = 4
    /// Distinct secrets one connection may hold.
    static let maximumSecrets = 32
    /// The longest a page-side value is kept before it is cut: control rows show the first 30 UTF-16 units of a field value.
    private static let truncatedLength = 30

    enum Registration: Equatable {
        case registered, tooShort, tooMany
    }

    /// One form of a secret as an output can show it, folded to lower case, and the secret it belongs to.
    private struct Needle {
        var bytes: [UInt8]
        let owner: Int
    }

    private struct State {
        /// The values as typed, folded to lower case, so a repeated registration is recognised.
        var secrets: [[UInt8]] = []
        /// The secrets (by index) that were written into a password, code or card field.
        var confirmed: Set<Int> = []
        /// Every form of every secret, longest first.
        var needles: [Needle] = []
        /// A secret was registered at some point, even if `wipe()` has run since.
        var used = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    deinit {
        state.withLock { Self.overwrite(&$0) }
    }

    // MARK: Registry

    var count: Int {
        state.withLock { $0.secrets.count }
    }

    var isEmpty: Bool {
        count == 0
    }

    /// Whether any secret was ever registered here, which `wipe()` does not forget: the connection that held them is over, and a
    /// result it was still computing must not be returned unscrubbed.
    var wasUsed: Bool {
        state.withLock { $0.used }
    }

    /// Remembers `secret` so no later output shows it. Registering a value twice does nothing the second time.
    @discardableResult
    func register(_ secret: String) -> Registration {
        let bytes = Self.fold(Array(secret.utf8))
        guard bytes.count >= Self.minimumBytes else { return .tooShort }
        return state.withLock { state in
            if state.secrets.contains(bytes) {
                return .registered
            }
            guard state.secrets.count < Self.maximumSecrets else { return .tooMany }
            state.secrets.append(bytes)
            state.used = true
            let owner = state.secrets.count - 1
            let added = Self.forms(of: secret).map { Needle(bytes: $0, owner: owner) }
            state.needles = (state.needles + added).sorted { $0.bytes.count > $1.bytes.count }
            return .registered
        }
    }

    /// Marks an already registered secret as written into a password, code or card field. Call it after the write, and only for
    /// a field the page driver treats as sensitive: nothing else may be hidden in a record the user reads. A value that was
    /// never registered is not confirmed.
    func confirm(_ secret: String) {
        let bytes = Self.fold(Array(secret.utf8))
        state.withLock { state in
            if let index = state.secrets.firstIndex(of: bytes) {
                state.confirmed.insert(index)
            }
        }
    }

    /// Forgets every secret and overwrites the copies. Called when the connection ends.
    func wipe() {
        state.withLock { Self.overwrite(&$0) }
    }

    private static func overwrite(_ state: inout State) {
        for index in state.secrets.indices {
            state.secrets[index].zero()
        }
        for index in state.needles.indices {
            state.needles[index].bytes.zero()
        }
        state = State(used: state.used)
    }

    // MARK: Scrubbing

    /// For text that goes back to the agent: hides every registered secret.
    func scrub(_ text: String) -> String {
        Self.scrub(text, needles: allNeedles)
    }

    func scrub(_ value: Value) -> Value {
        let needles = allNeedles
        return needles.isEmpty ? value : Self.scrub(value, needles: needles)
    }

    /// For a record the user reads about what the agent did: hides only the values confirmed as written into a password, code
    /// or card field, and marks each place with `auditReplacement`. Whatever else the agent registered stays visible, so a
    /// record cannot be blanked by registering its text.
    func scrubForAudit(_ text: String) -> String {
        let needles = state.withLock { state in state.needles.filter { state.confirmed.contains($0.owner) }.map(\.bytes) }
        return Self.scrub(text, needles: needles, marker: Self.auditReplacement)
    }

    private var allNeedles: [[UInt8]] {
        state.withLock { $0.needles.map(\.bytes) }
    }

    /// Text blocks and the structured copy. Images carry pixels, which `PageScreenshotMasking` handles at the source.
    func scrub(_ result: CallTool.Result) -> CallTool.Result {
        let needles = allNeedles
        guard !needles.isEmpty else { return result }
        let content = result.content.map { block -> MCP.Tool.Content in
            guard case .text(let text, let annotations, let meta) = block else { return block }
            return .text(text: Self.scrub(text, needles: needles), annotations: annotations, _meta: meta)
        }
        return CallTool.Result(
            content: content, structuredContent: result.structuredContent.map { Self.scrub($0, needles: needles) },
            isError: result.isError, _meta: result._meta)
    }

    private static func scrub(_ value: Value, needles: [[UInt8]]) -> Value {
        switch value {
        case .string(let text):
            .string(scrub(text, needles: needles))
        case .array(let items):
            .array(items.map { scrub($0, needles: needles) })
        case .object(let fields):
            .object(Dictionary(fields.map { (scrub($0.key, needles: needles), scrub($0.value, needles: needles)) }) { first, _ in first })
        default:
            value
        }
    }

    /// Every run of bytes covered by any needle becomes one `marker`. Overlapping and adjacent matches merge.
    private static func scrub(_ text: String, needles: [[UInt8]], marker: String = replacement) -> String {
        guard let shortest = needles.last?.count, text.utf8.count >= shortest else { return text }
        let original = Array(text.utf8)
        let folded = fold(original)
        var covered: [Bool]?
        for needle in needles where needle.count <= folded.count {
            let first = needle[0]
            for start in 0...(folded.count - needle.count) where folded[start] == first {
                guard folded[start..<(start + needle.count)].elementsEqual(needle) else { continue }
                if covered == nil {
                    covered = [Bool](repeating: false, count: folded.count)
                }
                for index in start..<(start + needle.count) {
                    covered?[index] = true
                }
            }
        }
        guard let covered else { return text }
        var output: [UInt8] = []
        output.reserveCapacity(original.count)
        var inside = false
        for (index, byte) in original.enumerated() {
            if covered[index] {
                if !inside {
                    output.append(contentsOf: Array(marker.utf8))
                }
                inside = true
            } else {
                output.append(byte)
                inside = false
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// ASCII upper case to lower case; every other byte is kept, so a multi-byte scalar is never altered.
    private static func fold(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    // MARK: Forms

    /// `secret` as an output can show it, folded and without duplicates, none shorter than `minimumBytes`.
    private static func forms(of secret: String) -> [[UInt8]] {
        var bases = [secret]
        let collapsed = secret.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed != secret {
            bases.append(collapsed)
        }
        for base in bases where base.utf16.count > truncatedLength {
            // A page-side read cuts a long field value, and the cut copy is a form of the secret too.
            bases.append(String(decoding: Array(base.utf16.prefix(truncatedLength)), as: UTF16.self))
        }
        let encoders: [(String) -> String] = [
            { $0 }, htmlMarkup, htmlEntities, percentEscaped, percentComponent, percentForm, jsonEscaped, jsonUnescapedSlashes,
        ]
        let layers: [(String) -> String] = [{ $0 }, jsonEscaped, jsonUnescapedSlashes]
        var seen = Set<[UInt8]>()
        var result: [[UInt8]] = []
        for base in bases {
            for encode in encoders {
                for layer in layers {
                    let bytes = fold(Array(layer(encode(base)).utf8))
                    if bytes.count >= minimumBytes, seen.insert(bytes).inserted {
                        result.append(bytes)
                    }
                }
            }
        }
        return result
    }

    /// The escaping `AgentToolkit.untrusted` applies to page text.
    private static func htmlMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func htmlEntities(_ text: String) -> String {
        htmlMarkup(text).replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Everything but letters and digits as `%XX`.
    private static func percentEscaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    /// `encodeURIComponent`.
    private static func percentComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? text
    }

    /// `URLSearchParams` and an HTML form: a space is `+`.
    private static func percentForm(_ text: String) -> String {
        (text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.* ")) ?? text)
            .replacingOccurrences(of: " ", with: "+")
    }

    /// The body of a JSON string, with `/` escaped the way `JSONEncoder` does by default.
    private static func jsonEscaped(_ text: String) -> String {
        json(text, escapingSlashes: true)
    }

    private static func jsonUnescapedSlashes(_ text: String) -> String {
        json(text, escapingSlashes: false)
    }

    private static func json(_ text: String, escapingSlashes: Bool) -> String {
        let encoder = JSONEncoder()
        if !escapingSlashes {
            encoder.outputFormatting = [.withoutEscapingSlashes]
        }
        guard let data = try? encoder.encode(text), var quoted = String(data: data, encoding: .utf8), quoted.count >= 2 else { return text }
        quoted.removeFirst()
        quoted.removeLast()
        return quoted
    }

    // MARK: Descriptions

    /// A count, never a value: the same text shows in logs, dumps and crash reports.
    var description: String {
        "MCPSecretScrubber(\(count) secrets)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: ["secrets": count], displayStyle: .class)
    }
}

private extension Array where Element == UInt8 {
    /// `memset_s` is the one store a compiler may not drop as dead.
    nonisolated mutating func zero() {
        withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return }
            _ = memset_s(base, bytes.count, 0, bytes.count)
        }
    }
}
