// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// The SF Symbols a folder can take as its icon: a short list of suggestions, and a search over every symbol the
/// system names, by name and by the words the SF Symbols app finds them by ("date" finds the calendars).
@MainActor
enum SymbolCatalog {
    static let suggested = [
        "folder", "star", "briefcase", "house", "cart", "book", "chevron.left.forwardslash.chevron.right", "terminal",
        "music.note", "photo", "globe", "person", "heart", "flag", "bolt", "bookmark",
        "star.fill", "heart.fill", "bolt.fill", "flag.fill", "tag", "tray", "archivebox", "doc.text",
        "newspaper", "graduationcap", "building.2", "storefront", "bag", "creditcard", "banknote", "chart.bar",
        "chart.pie", "cpu", "server.rack", "externaldrive", "wifi", "lock", "key", "shield",
        "gearshape", "hammer", "wrench.and.screwdriver", "paintbrush", "pencil", "scissors", "camera", "video",
        "film", "play.rectangle", "headphones", "mic", "gamecontroller", "sportscourt", "figure.run", "airplane",
        "car", "bicycle", "map", "mappin", "leaf", "tree", "flame", "drop",
        "sun.max", "moon", "cloud", "snowflake", "sparkles", "lightbulb", "gift", "cup.and.saucer",
        "fork.knife", "cross.case", "pills", "envelope", "bubble.left", "phone", "calendar", "clock",
        "bell", "pin", "paperclip", "link", "magnifyingglass", "square.grid.2x2", "list.bullet", "checklist",
        "flask", "atom", "brain", "puzzlepiece", "crown", "trophy", "lifepreserver", "hourglass",
        "pawprint", "ladybug", "theatermasks", "ticket", "wand.and.stars", "dollarsign.circle", "books.vertical", "person.2",
    ]

    /// The folder that shows when a person has not chosen a symbol.
    static let plainFolder = "folder"

    private static let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// The symbol names the system lists, in the order of the SF Symbols app, without the variants drawn for other
    /// scripts. Where the system's list cannot be read, only the suggestions.
    private static let all: [String] = {
        guard let names = property(list: "symbol_order") as? [String] else { return suggested }
        return names.filter { !isForOtherScript($0) }
    }()

    private static let keywords: [String: [String]] = property(list: "symbol_search") as? [String: [String]] ?? [:]

    private static func property(list name: String) -> Any? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("\(name).plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    /// The SF Symbols app names a symbol drawn for another script by ending its name with the script's code.
    private static let scriptCodes: Set<String> = [
        "ar", "he", "hi", "th", "zh", "ja", "ko", "ru", "el", "bn", "gu", "kn", "ml", "mr", "my", "or", "pa", "ta", "te",
        "ur", "vi", "km", "si", "hy", "ne", "ka", "lo", "ps", "sd", "fa", "rtl",
    ]

    private static func isForOtherScript(_ name: String) -> Bool {
        name.split(separator: ".").last.map { scriptCodes.contains(String($0)) } ?? false
    }

    static func isAvailable(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The symbols whose name or search words contain every word of `query`, the closest names first, and only those
    /// this Mac has.
    static func search(_ query: String, limit: Int = 240) -> [String] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: ".")
        var hits: [(name: String, rank: Int, order: Int)] = []
        for (order, name) in all.enumerated() {
            let lowered = name.lowercased()
            let tags = keywords[name] ?? []
            guard words.allSatisfy({ word in lowered.contains(word) || tags.contains { $0.contains(word) } }) else { continue }
            let rank = lowered == phrase ? 0 : lowered.hasPrefix(phrase) ? 1 : lowered.contains(phrase) ? 2 : 3
            hits.append((name, rank, order))
        }
        hits.sort { ($0.rank, $0.name.count, $0.order) < ($1.rank, $1.name.count, $1.order) }
        return hits.lazy.map(\.name).filter(isAvailable).prefix(limit).map { $0 }
    }
}

/// Chooses the symbol a folder shows: Default for the plain folder, a suggestion, or anything found by searching.
struct FolderIconPicker: View {
    let folder: TabFolder
    let browser: BrowserModel
    let dismiss: () -> Void

    @State private var query: String
    @FocusState private var isSearching: Bool
    @Environment(\.chromeWash) private var wash

    init(folder: TabFolder, browser: BrowserModel, query: String = "", dismiss: @escaping () -> Void) {
        self.folder = folder
        self.browser = browser
        self.dismiss = dismiss
        _query = State(initialValue: query)
    }

    private static let cell: CGFloat = 32

    private var searchedSymbols: [String] {
        SymbolCatalog.search(query)
    }

    private var isSearchingNames: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var shown: [String] {
        isSearchingNames ? searchedSymbols : SymbolCatalog.suggested.filter(SymbolCatalog.isAvailable)
    }

    var body: some View {
        let symbols = shown
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Symbols", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearching)
                    .accessibilityLabel(Text("Search Symbols"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.Wash.hairline, in: RoundedRectangle(cornerRadius: Theme.Radius.hover, style: .continuous))

            Button {
                choose(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: SymbolCatalog.plainFolder)
                        .frame(width: Self.cell - 6)
                    Text("Default")
                    Spacer(minLength: 0)
                    if folder.symbol == nil {
                        Image(systemName: "checkmark")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(folder.ink(opacity: 1, on: wash))

            ScrollView {
                if symbols.isEmpty {
                    Text("No Symbols Found")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell), spacing: 4)], spacing: 4) {
                        ForEach(symbols, id: \.self) { name in
                            cell(name)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300, height: 340)
        .onAppear { isSearching = true }
    }

    private func cell(_ name: String) -> some View {
        let isChosen = folder.symbol == name
        return Button {
            choose(name)
        } label: {
            Image(systemName: name)
                .font(.system(size: 15))
                .frame(width: Self.cell, height: Self.cell)
                .foregroundStyle(folder.ink(opacity: 1, on: wash))
                .background(
                    isChosen ? Theme.Wash.strong : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.hover, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: name))
        .accessibilityLabel(Text(verbatim: name))
    }

    private func choose(_ name: String?) {
        browser.setFolderSymbol(name, for: folder)
        dismiss()
    }
}
