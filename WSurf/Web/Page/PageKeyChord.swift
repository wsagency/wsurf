// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Carbon.HIToolbox

/// A keyboard chord an external client may ask a page to receive, and the one place that decides which chords may be sent.
///
/// The boundary is default-deny. A chord that is not built here is never turned into an `NSEvent`, so nothing the page ignores
/// can reach the app: an engine can hand a key its page did not handle back to the application, where Command+W closes the
/// window, Command+Q quits and Command+Comma opens Settings. Control is never sent, and Command only with the keys in
/// `commandChords`.
nonisolated struct PageKeyChord: Equatable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let command = Modifiers(rawValue: 4)

        var eventFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            for (modifier, flag) in [(Modifiers.shift, NSEvent.ModifierFlags.shift), (.option, .option), (.command, .command)]
            where contains(modifier) {
                flags.insert(flag)
            }
            return flags
        }
    }

    enum Refusal: Error, Equatable, Sendable {
        case unknownKey(extended: Bool)
        case unknownModifier(String)
        case control
        case commandWithOption
        case clipboard
        case appShortcut
        case commandNotAllowed

        var message: String {
            switch self {
            case .unknownKey(let extended):
                extended
                    ? "Use Enter, Tab, Escape, Space, ArrowLeft, ArrowRight, ArrowDown, ArrowUp, Home, End, PageUp, PageDown, Backspace, Delete, or one printable character."
                    : "Use Enter, Tab, Escape, Space, ArrowLeft, ArrowRight, ArrowDown, ArrowUp, Home, End, Backspace, or Delete."
            case .unknownModifier(let name):
                "“\(name)” is not a modifier. Use shift, option, or command."
            case .control:
                "Control chords are never sent."
            case .commandWithOption:
                "Command is never combined with Option."
            case .clipboard:
                "Clipboard shortcuts (Command with C, X, or V) are never sent. Use typeOnPage to enter text."
            case .appShortcut:
                "Browser and app shortcuts (such as Command with W, Q, T, N, L, R, P, S, O, F, H, M, or Comma) are never sent."
            case .commandNotAllowed:
                "Command is sent only with A, Z, Shift+Z, the arrow keys, Backspace, Delete, or Enter."
            }
        }
    }

    /// The chord as written in results, for example `Shift+Option+ArrowLeft`.
    let name: String
    let keyCode: UInt16
    let characters: String
    let modifiers: Modifiers
    /// `Enter` or `Space`: the keys that activate a focused control, so a consequential label needs approval first.
    let activates: Bool
    /// Command+A: the engines do not act on it unless the menu does, so the caller completes Select All after delivery.
    let selectsAll: Bool
    /// Command with an arrow key, Backspace or Delete edits text. Both engines hand a key the page leaves unhandled back to the
    /// app's menu, where Command+Left means Back. Only a text field consumes these, so only a text field may receive them.
    let needsTextField: Bool

    var eventFlags: NSEvent.ModifierFlags {
        modifiers.eventFlags
    }

    // MARK: Parsing

    /// `key` is a name, or one printable ASCII character when `extended`. `modifiers` is `+`-separated, for example
    /// `shift+option`. `extended: false` is the assistant's original contract: twelve named keys and no modifiers.
    static func parse(key: String, modifiers text: String = "", extended: Bool = true) -> Result<PageKeyChord, Refusal> {
        var modifiers: Modifiers = []
        for token in text.split(whereSeparator: { "+, ".contains($0) }).map({ $0.lowercased() }) {
            switch token {
            case "shift":
                modifiers.insert(.shift)
            case "option", "alt":
                modifiers.insert(.option)
            case "command", "cmd", "meta":
                modifiers.insert(.command)
            case "control", "ctrl":
                return .failure(.control)
            default:
                return .failure(.unknownModifier(String(token.prefix(24))))
            }
        }
        let trimmed = key == " " ? "Space" : key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found = resolve(trimmed, shifted: modifiers.contains(.shift), extended: extended) else {
            return .failure(.unknownKey(extended: extended))
        }
        if found.impliesShift {
            modifiers.insert(.shift)
        }
        if !extended, !modifiers.isEmpty {
            return .failure(.unknownKey(extended: false))
        }
        if let refusal = boundary(found.name, modifiers) {
            return .failure(refusal)
        }
        let (name, code, characters) = (found.name, found.code, found.characters)
        let label =
            (modifiers.contains(.command) ? ["Command"] : []) + (modifiers.contains(.shift) ? ["Shift"] : [])
            + (modifiers.contains(.option) ? ["Option"] : []) + [name]
        return .success(
            PageKeyChord(
                name: label.joined(separator: "+"), keyCode: code, characters: characters, modifiers: modifiers,
                activates: name == "Enter" || name == "Space", selectsAll: modifiers == .command && name == "A",
                needsTextField: modifiers.contains(.command) && Self.textEditing.contains(name)))
    }

    /// Key code and characters of a named key by its upper-case spelling or alias.
    static func namedKey(_ name: String) -> (UInt16, String)? {
        named[name].map { ($0.code, $0.characters) }
    }

    // MARK: The boundary

    /// Command is the modifier that reaches the app's own shortcuts. These are the only keys it may accompany, with the
    /// modifier sets listed.
    static let commandChords: [String: [Modifiers]] = [
        "A": [.command],
        "Z": [.command, [.command, .shift]],
        "ArrowLeft": [.command, [.command, .shift]], "ArrowRight": [.command, [.command, .shift]],
        "ArrowUp": [.command, [.command, .shift]], "ArrowDown": [.command, [.command, .shift]],
        "Backspace": [.command], "Delete": [.command], "Enter": [.command],
    ]

    private static let textEditing: Set<String> = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Backspace", "Delete"]

    private static func boundary(_ key: String, _ modifiers: Modifiers) -> Refusal? {
        guard modifiers.contains(.command) else {
            return nil
        }
        if modifiers.contains(.option) {
            return .commandWithOption
        }
        if commandChords[key]?.contains(modifiers) == true {
            return nil
        }
        if ["C", "X", "V"].contains(key) {
            return .clipboard
        }
        if ["W", "Q", "T", "N", "L", "R", "P", "S", "O", "F", "H", "M", ","].contains(key) {
            return .appShortcut
        }
        return .commandNotAllowed
    }

    // MARK: Tables

    private static let legacyNames: Set<String> = [
        "Enter", "Tab", "Escape", "Space", "ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp", "Home", "End", "Backspace", "Delete",
    ]

    private struct Key {
        let name: String
        let code: UInt16
        let characters: String
        var impliesShift = false
    }

    private static let named: [String: Key] = {
        let keys: [(spellings: [String], key: Key)] = [
            (["ENTER", "RETURN"], Key(name: "Enter", code: 36, characters: "\r")),
            (["TAB"], Key(name: "Tab", code: 48, characters: "\t")),
            (["ESCAPE", "ESC"], Key(name: "Escape", code: 53, characters: "\u{1b}")),
            (["SPACE"], Key(name: "Space", code: 49, characters: " ")),
            (["ARROWLEFT", "LEFT"], Key(name: "ArrowLeft", code: 123, characters: "\u{f702}")),
            (["ARROWRIGHT", "RIGHT"], Key(name: "ArrowRight", code: 124, characters: "\u{f703}")),
            (["ARROWDOWN", "DOWN"], Key(name: "ArrowDown", code: 125, characters: "\u{f701}")),
            (["ARROWUP", "UP"], Key(name: "ArrowUp", code: 126, characters: "\u{f700}")),
            (["HOME"], Key(name: "Home", code: 115, characters: "\u{f729}")),
            (["END"], Key(name: "End", code: 119, characters: "\u{f72b}")),
            (["PAGEUP"], Key(name: "PageUp", code: 116, characters: "\u{f72c}")),
            (["PAGEDOWN"], Key(name: "PageDown", code: 121, characters: "\u{f72d}")),
            (["BACKSPACE"], Key(name: "Backspace", code: 51, characters: "\u{7f}")),
            (["DELETE"], Key(name: "Delete", code: 117, characters: "\u{f728}")),
        ]
        var table: [String: Key] = [:]
        for (spellings, key) in keys {
            for spelling in spellings {
                table[spelling] = key
            }
        }
        return table
    }()

    static let letterCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
        "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
        "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
    ]

    static let printableKeys: [String: (code: Int, shifted: String)] = [
        "0": (kVK_ANSI_0, ")"), "1": (kVK_ANSI_1, "!"), "2": (kVK_ANSI_2, "@"), "3": (kVK_ANSI_3, "#"), "4": (kVK_ANSI_4, "$"),
        "5": (kVK_ANSI_5, "%"), "6": (kVK_ANSI_6, "^"), "7": (kVK_ANSI_7, "&"), "8": (kVK_ANSI_8, "*"), "9": (kVK_ANSI_9, "("),
        "-": (kVK_ANSI_Minus, "_"), "=": (kVK_ANSI_Equal, "+"), "[": (kVK_ANSI_LeftBracket, "{"), "]": (kVK_ANSI_RightBracket, "}"),
        "\\": (kVK_ANSI_Backslash, "|"), ";": (kVK_ANSI_Semicolon, ":"), "'": (kVK_ANSI_Quote, "\""),
        ",": (kVK_ANSI_Comma, "<"), ".": (kVK_ANSI_Period, ">"), "/": (kVK_ANSI_Slash, "?"), "`": (kVK_ANSI_Grave, "~"),
        " ": (kVK_Space, " "),
    ]

    /// A named key, or with `extended` one printable ASCII character. A letter is lowercase unless Shift is set; a shifted
    /// symbol such as `?` implies Shift.
    private static func resolve(_ key: String, shifted: Bool, extended: Bool) -> Key? {
        if let key = named[key.uppercased()] {
            return extended || legacyNames.contains(key.name) ? key : nil
        }
        guard extended, key.count == 1, key.unicodeScalars.first?.isASCII == true else {
            return nil
        }
        let upper = key.uppercased()
        if let code = letterCodes[upper] {
            return Key(name: upper, code: UInt16(code), characters: shifted ? upper : key.lowercased())
        }
        if let plain = printableKeys[key] {
            return Key(name: key, code: UInt16(plain.code), characters: shifted ? plain.shifted : key)
        }
        if let symbol = printableKeys.first(where: { $0.value.shifted == key }) {
            return Key(name: symbol.key, code: UInt16(symbol.value.code), characters: key, impliesShift: true)
        }
        return nil
    }
}
