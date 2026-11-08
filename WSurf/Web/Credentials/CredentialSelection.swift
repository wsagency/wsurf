// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation

/// What one row shows of the selection. A row reads only its own (`CredentialSelection.state(of:)`), never the selected set or the
/// cursor, so a change redraws only the rows whose state it changes: a cursor move redraws two rows, not every row that is built.
@MainActor
@Observable
final class CredentialRowState {
    fileprivate(set) var isSelected = false
    fileprivate(set) var isCursor = false
}

/// Which rows of the credential list, or of the Trash, are selected, and where the keyboard cursor is. Pure state, shared by both lists.
///
/// The list tells it the rows it shows (`show`) once per refresh. A cursor move or a toggle is O(1) plus the row states it changes; a
/// range (`extend`), select all and clear also update every row state handed out (one per row that was built). Rows read their own
/// `CredentialRowState` and the two flags `showsCheckboxes` and `hasSeveralSelected`, which change only when they flip. A row the list
/// stops showing (a search, a filter, a removal) leaves the selection, so an action never acts on rows you cannot see.
@MainActor
@Observable
final class CredentialSelection {
    private(set) var selected: Set<UUID> = []
    /// The row the keyboard acts on when nothing is selected, and where an arrow key starts.
    private(set) var cursor: UUID?
    /// Rows show a checkbox in selection mode and whenever something is selected. Set only when it flips.
    private(set) var showsCheckboxes = false
    /// Two or more rows are selected, so a selected row's menu acts on all of them. Set only when it flips.
    private(set) var hasSeveralSelected = false
    /// Where a range from the keyboard or a shift-click starts.
    private(set) var anchor: UUID?
    /// Selection mode, started by Select in a row's menu: every row shows a checkbox and a plain click toggles a row. It ends with
    /// `clear` (Done, Escape, a finished action) and `reset`.
    private(set) var isSelecting = false
    /// True while the list receives the keyboard: a row was clicked, or the search field handed it over.
    private(set) var ownsKeyboard = false
    /// Changes when the list should take the keyboard, so the key catcher becomes first responder again.
    private(set) var keyboardRequestID = 0
    /// Changes when a key moved the cursor, so the list scrolls to it. A click never scrolls.
    private(set) var scrollRequestID = 0
    /// The rows in the order the list shows them: the flat list, or the groups one after another with "By Site".
    @ObservationIgnored private(set) var order: [UUID] = []
    @ObservationIgnored private var position: [UUID: Int] = [:]
    /// The state each built row reads, made on first read and kept, so a row that is not redrawn never holds a stale one.
    @ObservationIgnored private var rows: [UUID: CredentialRowState] = [:]

    var isEmpty: Bool {
        selected.isEmpty
    }

    /// How many rows have been built since this selection was made (one state per row, kept): the performance tests' probe for the
    /// rows a keystroke or a scroll brings into view.
    var builtRowCount: Int {
        rows.count
    }

    /// The selection as row `id` shows it. Read in the row's body: only a change to this row's state redraws it.
    func state(of id: UUID) -> CredentialRowState {
        if let state = rows[id] {
            return state
        }
        let state = CredentialRowState()
        state.isSelected = selected.contains(id)
        state.isCursor = cursor == id
        rows[id] = state
        return state
    }

    /// The selected rows in list order; empty when nothing is selected (unlike `targets`, never the cursor row).
    var selectedInOrder: [UUID] {
        selected.isEmpty ? [] : order.filter { selected.contains($0) }
    }

    /// What an action acts on, in list order: the selection, else the cursor row.
    var targets: [UUID] {
        if !selected.isEmpty {
            return order.filter { selected.contains($0) }
        }
        return cursor.map { [$0] } ?? []
    }

    // MARK: Rows

    /// The rows the list shows now, in order. Selected rows, the cursor and the anchor that are no longer among them are dropped.
    func show(_ ids: [UUID]) {
        order = ids
        position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        if selected.contains(where: { position[$0] == nil }) {
            select(selected.filter { position[$0] != nil })
        }
        if let cursor, position[cursor] == nil {
            moveCursor(to: nil)
        }
        if let anchor, position[anchor] == nil {
            self.anchor = nil
        }
    }

    /// Back to nothing, for another vault, a lock or another list.
    func reset() {
        isSelecting = false
        select([])
        moveCursor(to: nil)
        anchor = nil
        ownsKeyboard = false
        order = []
        position = [:]
    }

    // MARK: Keyboard

    /// Moves the cursor by `delta` rows, stopping at the ends. `extending` selects the range from the anchor to the new cursor row.
    func moveCursor(by delta: Int, extending: Bool) {
        guard !order.isEmpty else { return }
        let target: Int
        if let current = cursor.flatMap({ position[$0] }) {
            target = min(max(current + delta, 0), order.count - 1)
        } else {
            target = delta >= 0 ? 0 : order.count - 1
        }
        let id = order[target]
        if extending {
            extend(to: id)
        } else {
            moveCursor(to: id)
            anchor = id
        }
        scrollRequestID += 1
    }

    /// Selects or deselects the cursor row.
    func toggleCursor() {
        if let cursor {
            toggle(cursor)
        }
    }

    func selectAll() {
        select(Set(order))
    }

    /// Deselects everything and ends selection mode. The cursor stays.
    func clear() {
        if isSelecting {
            isSelecting = false
        }
        if !selected.isEmpty {
            select([])
        }
        refreshFlags()
        anchor = cursor
    }

    /// Select in a row's menu: selection mode, with that row selected and the keyboard on the list.
    func beginSelecting(with id: UUID?) {
        isSelecting = true
        if let id, position[id] != nil {
            if !selected.contains(id) {
                flip(id)
            }
            moveCursor(to: id)
            anchor = id
        }
        refreshFlags()
        takeKeyboard()
    }

    // MARK: Mouse

    /// A plain click: the row gets the cursor and the keyboard. It selects nothing, except in selection mode, where it toggles the row.
    func click(_ id: UUID) {
        if isSelecting {
            toggle(id)
        } else {
            moveCursor(to: id)
            anchor = id
        }
        takeKeyboard()
    }

    /// Command-click: toggles the row.
    func toggle(_ id: UUID) {
        flip(id)
        moveCursor(to: id)
        anchor = id
    }

    /// Shift-click and shift-arrow: selects the rows from the anchor to `id`, in list order, and puts the cursor on `id`.
    func extend(to id: UUID) {
        guard let end = position[id] else { return }
        let start = anchor.flatMap { position[$0] } ?? cursor.flatMap { position[$0] } ?? end
        if anchor == nil {
            anchor = cursor ?? id
        }
        select(Set(order[min(start, end)...max(start, end)]))
        moveCursor(to: id)
    }

    // MARK: Focus

    /// The list takes the keyboard. With a row it starts there; without, the cursor stays or starts on the first row.
    func takeKeyboard(cursor row: UUID? = nil) {
        if let row, position[row] != nil {
            moveCursor(to: row)
            anchor = row
        } else if cursor == nil, let first = order.first {
            moveCursor(to: first)
            anchor = first
        }
        ownsKeyboard = true
        keyboardRequestID += 1
    }

    /// Another control took the keyboard (the search field, a sheet).
    func releaseKeyboard() {
        if ownsKeyboard {
            ownsKeyboard = false
        }
    }

    // MARK: Removal

    /// The row the cursor goes to when `ids` leave the list: the next row that stays, else the previous one.
    func cursorAfterRemoving(_ ids: [UUID]) -> UUID? {
        let gone = Set(ids)
        let positions = ids.compactMap { position[$0] }
        guard let first = positions.min(), let last = positions.max() else { return cursor }
        return order.dropFirst(last + 1).first { !gone.contains($0) } ?? order.prefix(first).last { !gone.contains($0) }
    }

    /// Puts the cursor on `id` (or nowhere) without selecting it, for the row that takes over after a removal.
    func place(cursor id: UUID?) {
        moveCursor(to: id)
        anchor = id
    }

    // MARK: Row states

    /// The one place the cursor changes: the row it leaves and the row it reaches are told, no other.
    private func moveCursor(to id: UUID?) {
        guard id != cursor else { return }
        if let old = cursor {
            rows[old]?.isCursor = false
        }
        cursor = id
        if let id {
            rows[id]?.isCursor = true
        }
    }

    /// Selects exactly `ids`; each handed-out row state whose answer changed is told.
    private func select(_ ids: Set<UUID>) {
        selected = ids
        for (id, state) in rows where state.isSelected != ids.contains(id) {
            state.isSelected.toggle()
        }
        refreshFlags()
    }

    /// Selects or deselects one row; only its state is told.
    private func flip(_ id: UUID) {
        if selected.remove(id) == nil {
            selected.insert(id)
        }
        rows[id]?.isSelected = selected.contains(id)
        refreshFlags()
    }

    private func refreshFlags() {
        let shows = isSelecting || !selected.isEmpty
        if showsCheckboxes != shows {
            showsCheckboxes = shows
        }
        let several = selected.count > 1
        if hasSeveralSelected != several {
            hasSeveralSelected = several
        }
    }
}

// MARK: - Row menu

/// One entry of a credential row's right-click menu. Pure, so which entries a row offers, and on which credentials, is tested without
/// a view.
nonisolated enum CredentialRowMenuItem: Hashable, Sendable {
    case openWebsite(URL)
    case copyUsername
    case copyPassword
    case edit
    /// `ofSelection`: the row is one of several selected rows, so the entry acts on all of them (`menuTargets(for:)`, read on click).
    /// Otherwise it acts on the row alone (merge: its suggestion, or Select to pick more).
    case merge(ofSelection: Bool)
    case moveToTrash(ofSelection: Bool)
    case select
    case deselect
}

extension CredentialSelection {
    /// What a row's menu acts on: the selection when the row is one of two or more selected rows, else the row alone.
    func menuTargets(for id: UUID) -> [UUID] {
        selected.count > 1 && selected.contains(id) ? selectedInOrder : [id]
    }

    /// The entries of `summary`'s right-click menu, in order. O(1): it reads this row's state and one flag, never the selected set, so
    /// building it in a row's body redraws the row only when its own answer changes.
    func menu(for summary: CredentialSummary) -> [CredentialRowMenuItem] {
        var items: [CredentialRowMenuItem] = []
        if let website = summary.website {
            items.append(.openWebsite(website))
        }
        if summary.usernameIsConcealed || summary.username != nil {
            items.append(.copyUsername)
        }
        if summary.hasPassword {
            items.append(.copyPassword)
        }
        let isSelected = state(of: summary.id).isSelected
        let ofSelection = isSelected && hasSeveralSelected
        items += [.edit, .merge(ofSelection: ofSelection), .moveToTrash(ofSelection: ofSelection), isSelected ? .deselect : .select]
        return items
    }
}
