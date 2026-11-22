// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
    static func spaceItem(_ space: Space, id: UUID, profile: UUID) -> SharedSpaceItem {
        .init(id: id, kind: .space, profileID: profile, title: space.name, symbol: space.symbol, color: space.color.rawValue)
    }

    static func pinItem(_ pin: ProfilePin, id: UUID, profile: UUID) -> SharedSpaceItem? {
        let url = pin.pinnedURL?.absoluteString ?? pin.url
        guard let page = SessionNode.tab(id: id, title: pin.pinnedTitle ?? pin.title, url: url) else { return nil }
        return .init(
            id: id, kind: .pin, profileID: profile, order: pin.orderKey, title: page.title,
            url: page.url, customTitle: pin.customTitle, favorite: pin.isFavorite
        )
    }

    func spaceChanged(_ space: Space, in profile: UUID, removed: Bool = false) {
        guard !applying, catalog.enabled(.spaces, for: profile),
              let link = links[profile], let id = link.spaces[space.id], let group = link.profile else { return }
        let value = Self.spaceItem(space, id: id, profile: group)
        catalog.stage(removed ? value.tombstone : value, for: profile)
        if removed {
            for slot in link.slots.values where slot.last?.spaceID == id {
                if let prior = slot.last {
                    catalog.stage(prior.tombstone, for: profile)
                }
            }
            links[profile]?.spaces[space.id] = nil
            persistLinks()
        }
    }

    func pinsChanged(in profile: Profile, store: ProfilePinStore) {
        guard !applying, isEnabled(.pins, for: profile), store.isAvailable,
              let link = links[profile.id], let group = link.profile, let library = link.pinLibrary,
              catalog.ready.contains(.pins) || !library.rows.isEmpty else { return }
        do {
            try capturePinLibrary(store.readForPublication(), in: profile, group: group)
        } catch {
            pinLibraryFailures.insert(profile.id)
        }
    }

    /// A row gone from an open window is ambiguous during teardown or transfer. Only an individual close supplies a deletion.
    func removed(_ id: UUID, in browser: BrowserModel) {
        let profile = browser.context.profile
        guard !applying, !browser.opensPrivately, !browser.isApplyingProfilePins, !browser.isReadingSharedSession, isEnabled(.spaces, for: profile),
              !browser.unplacedSpaceRows.contains(.tab(id)), !browser.unplacedSpaceRows.contains(.folder(id)),
              let entry = links[profile.id]?.slots[id], entry.window == browser.windowID, let prior = entry.last else { return }
        links[profile.id]?.slots[id]?.closedAfterRevision = browser.sessionRevision
        links[profile.id]?.slots[id]?.editedAfterRevision = nil
        links[profile.id]?.slots[id]?.last = prior.tombstone
        catalog.stage(prior.tombstone, for: profile.id)
        persistLinks()
    }

    func sharesRow(_ id: UUID, in browser: BrowserModel) -> Bool {
        let profile = browser.context.profile
        guard isEnabled(.spaces, for: profile), let slot = links[profile.id]?.slots[id] else { return false }
        return slot.window == browser.windowID && slot.last?.removed == false
    }

    /// A window's existing slot and catalog record can identify an ordinary SQLite row whose Space is missing.
    func savedSpace(of item: SidebarItem, in browser: BrowserModel, pinID: UUID? = nil) -> UUID? {
        let local: UUID, kind: SharedSpaceItem.Kind
        switch item {
        case .tab(let id):
            (local, kind) = (id, .tab)
        case .folder(let id):
            (local, kind) = (id, .folder)
        }
        guard let link = links[browser.context.profile.id], let slot = link.slots[local], slot.window == browser.windowID,
              slot.closedAfterRevision == nil, let last = slot.last, last.id == slot.cloudID,
              !last.removed, last.kind == kind, last.profileID == link.profile, let space = last.spaceID,
              let live = catalog.item(slot.cloudID, in: .spaces), live.id == slot.cloudID, !live.removed, live.kind == kind,
              live.profileID == last.profileID, live.spaceID == space, let container = catalog.item(space, in: .spaces),
              !container.removed, container.kind == .space, container.profileID == last.profileID else { return nil }
        let expectedPin = pinID ?? browser.tab(id: local)?.pinID
        if let priorPin = slot.pinID, priorPin != expectedPin {
            guard expectedPin == nil, browser.pinStore.isAvailable, !browser.pinStore.pins.contains(where: { $0.id == priorPin }) else { return nil }
        }
        return link.spaces.first { $0.value == space && browser.knownSpaceIDs.contains($0.key) }?.key
    }

    func liveLocalEdit(_ key: SyncRecordID, in profile: UUID) -> SharedSpaceItem? {
        let edit = catalog.state.pending[key] ?? catalog.state.conflicts[key]
        guard let edit, edit.profile == profile, !edit.item.removed else { return nil }
        return edit.item
    }

    func restoreWindowEdits(in browser: BrowserModel, only records: Set<UUID>? = nil) {
        let profile = browser.context.profile
        guard !browser.opensPrivately, browser.windowKind == .standard, var link = links[profile.id] else { return }
        let enabled = isEnabled(.spaces, for: profile)
        reconcileCloses(in: browser, link: &link, enabled: enabled, only: records)
        if link != links[profile.id] {
            links[profile.id] = link
            persistLinks()
        }
        guard enabled else { return }
        let slots = link.slots.filter { $0.value.window == browser.windowID }
        let spaces = Dictionary(uniqueKeysWithValues: link.spaces.map { ($0.value, $0.key) })
        let edits = slots.compactMap { _, slot -> SharedSpaceItem? in
            guard records?.contains(slot.cloudID) != false, slot.pinID == nil, let last = slot.last, !last.removed, last.profileID == link.profile,
                  last.spaceID.flatMap({ spaces[$0] }) != nil else { return nil }
            if let revision = slot.editedAfterRevision {
                return browser.sessionRevision <= revision ? last : nil
            }
            // Older checkpoints kept the authored row in the outbox. A conflicting remote close still wins.
            guard liveLocalEdit(last.recordID, in: profile.id) != nil, catalog.item(last.id, in: .spaces)?.removed == false else { return nil }
            return last
        }
        guard !edits.isEmpty else { return }
        let editing = Set(edits.map(\.id))
        let affectedSpaces = Set(edits.compactMap(\.spaceID))
        let parents = browser.reconciledTree().parents()
        // Keep existing SQLite rows as placement anchors without replaying their cached titles or URLs.
        let anchors = slots.compactMap { local, slot -> (SidebarItem, SharedSpaceItem)? in
            guard slot.pinID == nil, var row = slot.last, !row.removed, !editing.contains(row.id) else { return nil }
            let item: SidebarItem = row.kind == .folder ? .folder(local) : .tab(local)
            guard let space = browser.spaceID(ofItem: item).flatMap({ link.spaces[$0] }), affectedSpaces.contains(space) else { return nil }
            row.spaceID = space
            row.parentID = parents[item].flatMap { slots[$0]?.cloudID }
            return (item, row)
        }
        let ids = Dictionary(uniqueKeysWithValues: slots.map { ($0.value.cloudID, $0.key) })
        browser.applySharedRows(edits, spaces: spaces, ids: ids, anchors: Dictionary(uniqueKeysWithValues: anchors))
    }

    private func reconcileCloses(in browser: BrowserModel, link: inout SharedProfileLinks, enabled: Bool, only records: Set<UUID>?) {
        let profile = browser.context.profile.id
        for (id, slot) in link.slots where slot.window == browser.windowID && records?.contains(slot.cloudID) != false {
            guard let last = slot.last else { continue }
            let key = last.recordID
            if enabled, catalog.state.conflicts[key]?.profile == profile, catalog.state.remote[key]?.item.removed == true {
                if browser.removeSharedRow(id) {
                    link.slots[id]?.closedAfterRevision = slot.closedAfterRevision ?? browser.sessionRevision
                    link.slots[id]?.editedAfterRevision = nil
                    link.slots[id]?.last = last.tombstone
                }
                continue
            }
            guard slot.closedAfterRevision != nil else { continue }
            // The chosen version may have reached the checkpoint before the close marker was retired.
            let kept = last.removed ? liveLocalEdit(key, in: profile) : last
            if enabled, let kept, !kept.removed, kept.profileID == link.profile, catalog.item(kept.id, in: .spaces)?.removed == false {
                link.slots[id]?.last = kept
                link.slots[id]?.closedAfterRevision = nil
                link.slots[id]?.editedAfterRevision = browser.sessionRevision
            } else {
                browser.removeSharedRow(id)
            }
        }
    }

    func didSaveWindow(_ browser: BrowserModel, revision: Int64) {
        let profile = browser.context.profile.id
        guard browser.sessionRevision == revision, var link = links[profile] else { return }
        for (id, slot) in link.slots where slot.window == browser.windowID {
            if let edited = slot.editedAfterRevision, revision > edited {
                link.slots[id]?.editedAfterRevision = nil
            }
            if let closed = slot.closedAfterRevision, revision > closed, let last = slot.last, last.removed,
               browser.tab(id: id) == nil, browser.folder(id: id) == nil, liveLocalEdit(last.recordID, in: profile) == nil {
                link.slots[id] = nil
            }
        }
        guard link != links[profile] else { return }
        links[profile] = link
        persistLinks()
    }

    /// An explicit rename can update an already shared record while the Space list is unavailable.
    /// Its saved membership and placement stay intact, and upload waits for the list to recover.
    private func captureLinkedRename(_ row: SidebarItem, in browser: BrowserModel, link: SharedProfileLinks) {
        let local: UUID
        switch row {
        case .tab(let id), .folder(let id):
            local = id
        }
        let root = browser.rootItem(containing: row)
        guard !browser.isKept(root), let localSpace = browser.spaceID(ofItem: root), browser.spaceID(ofItem: row) == localSpace,
              let slot = link.slots[local], slot.window == browser.windowID, slot.pinID == nil, slot.closedAfterRevision == nil,
              var last = slot.last, !last.removed, last.profileID == link.profile,
              let space = link.spaces[localSpace], last.spaceID == space,
              let value = Self.row(row, id: slot.cloudID, space: space, profile: last.profileID, browser: browser),
              value.kind == last.kind else { return }
        if value.kind == .tab {
            last.customTitle = value.customTitle
        } else {
            last.title = value.title
        }
        guard last != slot.last else { return }
        let profile = browser.context.profile.id
        links[profile]?.slots[local]?.last = last
        links[profile]?.slots[local]?.editedAfterRevision = browser.sessionRevision
        catalog.stage(outgoingRow(last, after: slot.last, window: browser.windowID, link: link), for: profile)
        persistLinks()
    }

    func capture(_ browser: BrowserModel, renamed: SidebarItem? = nil) {
        let profile = browser.context.profile
        guard !applying, !browser.opensPrivately, !browser.isReadingSharedSession, browser.sessionClosedAt == nil,
              browser.windowKind == .standard, isEnabled(.spaces, for: profile),
              var link = links[profile.id], !link.spaces.isEmpty, let group = link.profile else { return }
        guard spaces(profile) != nil else {
            if let renamed {
                captureLinkedRename(renamed, in: browser, link: link)
            }
            return
        }
        let tree = browser.reconciledTree()
        let parents = tree.parents()
        var groups: [UUID: [UUID]] = [:]
        var values: [UUID: SharedSpaceItem] = [:]
        var leaving: [SharedSpaceItem] = []
        var transferredPins: [SharedSpaceItem] = []
        var restoredMembership = false
        // Missing membership supplies neither a shared destination nor evidence of departure.
        for row in tree.walk() where !browser.unplacedSpaceRows.contains(row) {
            let local: UUID
            switch row {
            case .folder(let id), .tab(let id):
                local = id
            }
            // A restored stale row is removed before capture. An explicit Undo can publish a new shared tab.
            let previous = link.slots[local].flatMap { $0.closedAfterRevision == nil ? $0 : nil }
            let cloudID = previous?.cloudID ?? (catalog.item(local, in: .spaces) == nil ? local : UUID())
            if case .tab = row, let tab = browser.tab(id: local), let previous, previous.last?.removed == false {
                if let pinID = tab.pinID {
                    if previous.pinID != pinID, isEnabled(.pins, for: profile),
                       let pin = browser.pinStore.pins.first(where: { $0.id == pinID }),
                       var value = Self.pinItem(pin, id: link.pins[pinID] ?? pinID, profile: group) {
                        value.sharedTabID = previous.cloudID
                        link.pins[pinID] = value.id
                        transferredPins.append(value)
                    }
                    link.slots[local]?.pinID = pinID
                    continue
                } else if let pinID = previous.pinID {
                    if let destination = savedSpace(of: row, in: browser, pinID: pinID), destination != tab.spaceID {
                        tab.spaceID = destination
                        restoredMembership = true
                    }
                    link.slots[local]?.pinID = nil
                }
            }
            guard let space = browser.spaceID(ofItem: row).flatMap({ link.spaces[$0] }),
                  var item = Self.row(row, id: cloudID, space: space, profile: group, browser: browser) else {
                if let prior = previous?.last, !prior.removed {
                    leaving.append(prior.tombstone)
                    link.slots[local]?.last = prior.tombstone
                    link.slots[local]?.editedAfterRevision = nil
                }
                continue
            }
            item.parentID = parents[row].flatMap { parent in
                browser.unplacedSpaceRows.contains(.folder(parent)) ? previous?.last?.parentID : link.slots[parent]?.cloudID
            }
            item.order = previous?.last?.order ?? ""
            values[local] = item
            groups[item.parentID ?? space, default: []].append(local)
            let edited = previous?.editedAfterRevision.map { previous?.window == browser.windowID ? $0 : browser.sessionRevision }
            link.slots[local] = .init(cloudID: cloudID, window: browser.windowID, last: previous?.last, editedAfterRevision: edited)
        }
        if restoredMembership {
            browser.sidebarDidChange()
        }
        var edits = leaving + transferredPins
        for ids in groups.values {
            var lower: String?
            for (i, local) in ids.enumerated() {
                guard var item = values[local] else { continue }
                if item.order.isEmpty || lower.map({ item.order <= $0 }) == true {
                    let upper = ids.dropFirst(i + 1).lazy.compactMap { values[$0]?.order }.first { next in
                        !next.isEmpty && lower.map { next > $0 } != false
                    }
                    item.order = OrderKey.between(lower, upper)
                }
                lower = item.order
                if link.slots[local]?.last != item {
                    edits.append(outgoingRow(item, after: link.slots[local]?.last, window: browser.windowID, link: link))
                    link.slots[local]?.last = item
                    link.slots[local]?.editedAfterRevision = browser.sessionRevision
                }
            }
        }
        guard links[profile.id] != link else { return }
        links[profile.id] = link
        catalog.stage(edits, for: profile.id)
        if !transferredPins.isEmpty {
            pinsChanged(in: profile, store: browser.pinStore)
        }
        persistLinks()
    }

    private static func row(_ row: SidebarItem, id: UUID, space: UUID, profile: UUID, browser: BrowserModel) -> SharedSpaceItem? {
        switch row {
        case .folder(let local):
            guard let folder = browser.folder(id: local), !folder.isPinned, !browser.profileFolderIDs.contains(local) else { return nil }
            return .init(id: id, kind: .folder, profileID: profile, spaceID: space, title: folder.name, symbol: folder.symbol, color: folder.color.rawValue)
        case .tab(let local):
            guard let tab = browser.tab(id: local), !tab.isPrivate, tab.pinID == nil, tab.pinnedURL == nil, !tab.isFavorite,
                  tab.microTabID == nil, tab.extensionBaseURL == nil,
                  let page = SessionNode.tab(id: id, title: tab.pageTitle, url: tab.urlString) else { return nil }
            return .init(id: id, kind: .tab, profileID: profile, spaceID: space, title: page.title, url: page.url, customTitle: tab.customTitle)
        }
    }
}
