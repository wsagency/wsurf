// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation
import Security

extension NSPasteboard.PasteboardType {
    /// Clipboard managers skip a copy that carries it. `CredentialSettingsModel` keeps its own copy of the name.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

/// What the Input History list shows and does, for one profile and one opening of the list.
///
/// - Rows are built once, when the unlocked entries arrive or change. Their search text is folded then, so typing in the search
///   field only compares strings and `body` never searches.
/// - Nothing is read until `InputHistory` holds the decrypted entries, and the rows are dropped as soon as it locks.
/// - A password stays masked until its row is revealed, one row at a time, and no search text ever contains a password.
@MainActor
@Observable
final class InputHistoryListModel {
    static let clipboardLifetime: Duration = .seconds(60)
    /// Rows the list draws. The store keeps no more than this many entries, so a longer list only ever comes from a test.
    static let visibleLimit = 500
    static let mask = String(repeating: "\u{2022}", count: 8)
    private static let previewLength = 240

    struct Row: Identifiable {
        let id: String
        let createdAt: Date
        let host: String
        /// Origin and path of the page, as recorded.
        let location: String
        let label: String
        let title: String
        let kind: InputHistoryPayload.Kind
        let username: String?
        let value: String
        /// The start of the value, on one line, so a row never lays out a 10,000 character text.
        let preview: String
        /// The HTTPS origin a saved login would belong to: the frame's own, else the page's. Nil for HTTP, which cannot be saved, and
        /// for an address the vault and the save offer would name differently.
        let credentialOrigin: String?
        fileprivate let haystack: String

        var isPassword: Bool {
            kind == .password
        }

        var canSaveAsCredential: Bool {
            isPassword && credentialOrigin != nil
        }

        fileprivate init(_ entry: InputHistoryEntry) {
            let payload = entry.payload
            let address = InputHistoryRules.address(URL(string: payload.url))
            id = entry.id
            createdAt = entry.createdAt
            host = address?.host ?? payload.url
            location = payload.url
            label = payload.label
            title = payload.title
            kind = payload.kind
            username = payload.username
            value = payload.value
            preview = String(payload.value.prefix(InputHistoryListModel.previewLength)).replacingOccurrences(of: "\n", with: " ")
            credentialOrigin = URL(string: payload.frameOrigin ?? payload.url).flatMap(CredentialAccountSelection.origin(for:))
            // A password is never searchable. The username next to it is plain text.
            let searchable = [host, payload.url, payload.label, payload.title, payload.username ?? "", payload.kind == .password ? "" : payload.value]
            haystack = InputHistoryListModel.fold(searchable.joined(separator: "\n"))
        }
    }

    let profile: Profile
    private let settings: BrowserSettings
    @ObservationIgnored private let history: InputHistory
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let clock: any Clock<Duration>

    /// All unlocked entries, newest first.
    private(set) var rows: [Row] = []
    /// The rows that match the search, at most `visibleLimit`.
    private(set) var visible: [Row] = []
    var query = "" {
        didSet {
            if query != oldValue {
                refilter()
            }
        }
    }

    var selection: String?
    private(set) var revealedID: String?
    private(set) var isUnlocking = false
    private(set) var error: String?
    /// The result of the last action that has no visible effect on the list, such as copying.
    private(set) var notice: String?
    /// The last copy's clearing, so a test can wait for it after moving the clock.
    @ObservationIgnored private(set) var clipboardClearing: Task<Void, Never>?

    init(
        profile: Profile,
        settings: BrowserSettings,
        history: InputHistory = .shared,
        pasteboard: NSPasteboard = .general,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.profile = profile
        self.settings = settings
        self.history = history
        self.pasteboard = pasteboard
        self.clock = clock
    }

    // MARK: - Opening

    var isLocked: Bool {
        history.unlocked[profile.id] == nil
    }

    /// The entries the list was built from; the view watches it to rebuild after a delete, an expiry or a lock.
    var source: [InputHistoryEntry]? {
        history.unlocked[profile.id]
    }

    var entryCount: Int {
        isLocked ? history.count(for: profile.id) : rows.count
    }

    var retention: InputHistoryRetention {
        settings.inputHistoryRetention
    }

    func listDidOpen() {
        history.listDidOpen(profile.id)
    }

    func listDidClose() {
        history.listDidClose(profile.id)
    }

    /// Asks for Touch ID or the Mac password. Cancelling is not an error: the list just stays locked.
    func unlock() async {
        guard !isUnlocking, isLocked else {
            sync()
            return
        }
        isUnlocking = true
        error = nil
        defer { isUnlocking = false }
        do {
            try await history.unlock(profile)
            sync()
        } catch {
            self.error = Self.message(for: error)
        }
    }

    nonisolated static func message(for error: any Error) -> String? {
        switch error {
        case AutofillVaultError.keychain(let status) where status == errSecUserCanceled || status == errSecAuthFailed:
            nil
        case InputHistoryError.keysUnusable:
            String(localized: "Input History couldn’t be opened, so it was cleared.")
        case InputHistoryError.unavailable:
            String(localized: "Another copy of WSurf is keeping Input History.")
        default:
            String(localized: "Couldn’t open Input History. Try again.")
        }
    }

    /// Drops the decrypted entries now. Showing them again asks again.
    func lock() {
        history.lock(profileID: profile.id)
        sync()
    }

    /// Rebuilds the rows from what `InputHistory` holds, or drops them when it is locked.
    func sync() {
        guard let entries = source else {
            guard !rows.isEmpty || selection != nil || revealedID != nil || !query.isEmpty else { return }
            rows = []
            visible = []
            selection = nil
            revealedID = nil
            query = ""
            return
        }
        show(entries)
    }

    /// Builds the rows. `sync` is the only caller outside tests, which pass more entries than a store keeps.
    func show(_ entries: [InputHistoryEntry]) {
        rows = entries.sorted(by: Self.newerFirst).map(Row.init)
        if let revealedID, !rows.contains(where: { $0.id == revealedID }) {
            self.revealedID = nil
        }
        refilter()
    }

    nonisolated static func newerFirst(_ lhs: InputHistoryEntry, _ rhs: InputHistoryEntry) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id > rhs.id
    }

    // MARK: - Searching

    /// Case, diacritics and width do not matter.
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private func refilter() {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if needle.isEmpty {
            visible = Array(rows.prefix(Self.visibleLimit))
        } else {
            visible = Array(rows.lazy.filter { $0.haystack.contains(needle) }.prefix(Self.visibleLimit))
        }
        if let selection, !visible.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    // MARK: - Showing

    /// What a row shows for its value: the mask for a password that was not revealed.
    func text(for row: Row) -> String {
        row.isPassword && revealedID != row.id ? Self.mask : row.preview
    }

    func isRevealed(_ row: Row) -> Bool {
        revealedID == row.id
    }

    /// What VoiceOver reads for the value. A masked password is described, never spelled out as bullets or as itself.
    func spokenValue(for row: Row) -> String {
        row.isPassword && revealedID != row.id ? String(localized: "Password, hidden") : row.preview
    }

    /// Reveals one row and hides the one revealed before it.
    func toggleReveal(_ row: Row) {
        revealedID = revealedID == row.id ? nil : row.id
    }

    /// Up and Down in the search field: the next or previous visible row, starting at the first.
    func moveSelection(by offset: Int) {
        guard !visible.isEmpty else { return }
        guard let current = selection.flatMap({ id in visible.firstIndex { $0.id == id } }) else {
            selection = visible[offset < 0 ? visible.count - 1 : 0].id
            return
        }
        selection = visible[min(max(current + offset, 0), visible.count - 1)].id
    }

    var selectedRow: Row? {
        selection.flatMap { id in visible.first { $0.id == id } }
    }

    // MARK: - Acting

    /// The text goes to the clipboard marked concealed, and leaves it after a minute unless something else was copied since.
    func copy(_ row: Row) {
        pasteboard.declareTypes([.string, .concealed], owner: nil)
        pasteboard.setString(row.value, forType: .string)
        pasteboard.setString("", forType: .concealed)
        let changeCount = pasteboard.changeCount
        // The task holds the pasteboard and the clock, not the model: closing the list does not cancel the clearing.
        clipboardClearing = Task { [pasteboard, clock] in
            do {
                try await clock.sleep(for: Self.clipboardLifetime)
            } catch {
                return
            }
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
            }
        }
        notice = String(localized: "Copied. It leaves the clipboard in a minute.")
    }

    func copySelected() {
        if let row = selectedRow {
            copy(row)
        }
    }

    func delete(_ row: Row) {
        let next = neighbour(of: row)
        history.delete(row.id, in: profile)
        sync()
        if selection == nil {
            selection = next
        }
    }

    func deleteSelected() {
        if let row = selectedRow {
            delete(row)
        }
    }

    func clearAll() {
        history.clearAll(in: profile)
        sync()
        notice = nil
    }

    /// Recording stops and everything kept goes, keys included. The view asks first.
    func turnOffAndDelete() {
        settings.recordsInputHistory = false
        clearAll()
    }

    /// The row to select once `row` is gone: the one below it, else the one above.
    private func neighbour(of row: Row) -> String? {
        guard selection == row.id, let index = visible.firstIndex(where: { $0.id == row.id }) else { return nil }
        return visible.indices.contains(index + 1) ? visible[index + 1].id : visible.indices.contains(index - 1) ? visible[index - 1].id : nil
    }

    /// Adds the row's host to the excluded websites. Entries already kept stay until they expire or are deleted.
    func excludeSite(of row: Row) {
        let existing = InputHistoryRules.excludedHosts(settings.inputHistoryExcludedSites)
        if !InputHistoryRules.isExcluded(row.host, by: existing) {
            settings.inputHistoryExcludedSites.append(row.host.contains(":") ? "[\(row.host)]" : row.host)
        }
        notice = String(localized: "\(row.host) won’t be recorded.")
    }
}
