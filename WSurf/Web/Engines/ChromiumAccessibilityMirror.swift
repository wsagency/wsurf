// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import os

// D4-41 (out-of-process Chromium, phase 5): the mirror of one browser's accessibility trees, as VoiceOver (or any other client) asks for
// them. The service runs CEF's tree-only mode and sends Chromium's updates (D4-40); the decode queue applies them to the forest here,
// and the elements (`ChromiumAccessibilityElement`) answer AppKit from it. It follows CEF's own sample bridge
// (`tests/shared/browser/osr_accessibility_*`), with one change for VoiceOver's sequential navigation (VO-arrow keys): containers with
// no name of their own are flattened, and headings, links and buttons are leaves that speak their name.
//
// Threads: the decode queue writes, the main thread reads, both under one lock. A query waits for the apply that holds it: the whole
// apply of one update runs under the lock (about 130 ms for the first update of a 12,000-node page, measured as the difference of
// two runs, not as the hold itself: D4-42 publishes snapshots instead). The main thread never parses a tree, and it is the thread
// that lets go of the elements (`releaseOnMain`): an element's dealloc may call into AppKit, which a decode queue holding the lock must
// not be in.

nonisolated final class ChromiumAccessibilityMirror: @unchecked Sendable {
    typealias Key = ChromiumAccessibilityKey

    /// What an element says about its node, read in one pass under the lock.
    nonisolated struct Description: Sendable {
        nonisolated enum Value: Sendable {
            case string(String)
            case number(Int)
        }

        var role: NSAccessibility.Role
        var roleDescription: String?
        var title: String?
        var label: String?
        var value: Value?
        var url: URL?
    }

    private nonisolated struct State {
        var forest = ChromiumAccessibilityForest()
        /// False from `reset` until `accept`: an update the service had already sent when the tree was turned off arrives after it.
        var accepting = true
        var elements: [Key: ChromiumAccessibilityElement] = [:]
        var treeUpdates = 0
        var locationUpdates = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: Updates (the decode queue)

    /// Applies one parsed update. `json` is what `JSONSerialization` made of the update's bytes; it is not kept.
    func apply(_ kind: ChromiumAccessibilityUpdate.Kind, json: Any) {
        // The box takes the only reference to the array that holds them (nothing here keeps another: a second reference would free the
        // elements wherever it was dropped last), and the main thread empties it.
        let retired = Retired(state.withLockUnchecked { state -> [ChromiumAccessibilityElement] in
            guard state.accepting else { return [] }
            switch kind {
            case .tree:
                guard let object = json as? [String: Any] else { return [] }
                state.forest.applyTree(object)
                state.treeUpdates += 1
                // An element whose node is gone is dropped with it (a client that still holds one is told it does not exist).
                let gone = state.elements.filter { state.forest.node($0.key) == nil }
                for key in gone.keys {
                    state.elements[key] = nil
                }
                return Array(gone.values)
            case .location:
                guard let list = json as? [[String: Any]] else { return [] }
                state.forest.applyLocations(list)
                state.locationUpdates += 1
                return []
            }
        })
        retired.releaseOnMain()
    }

    /// Elements the mirror let go of, to be freed on the main thread, outside the lock: with a client such as VoiceOver registered, an
    /// element's dealloc may call back into AppKit, and into our own overrides.
    private nonisolated final class Retired: @unchecked Sendable {
        var elements: [ChromiumAccessibilityElement]

        init(_ elements: [ChromiumAccessibilityElement]) {
            self.elements = elements
        }

        func releaseOnMain() {
            guard !elements.isEmpty else { return }
            DispatchQueue.main.async { self.elements.removeAll() }
        }
    }

    /// Back to no tree: the tree was turned off, its connection was lost, or the browser is gone. Updates are ignored until `accept`.
    func reset() {
        let retired = Retired(state.withLock { state -> [ChromiumAccessibilityElement] in
            state.forest.clearNodes()
            let all = Array(state.elements.values)
            state.elements.removeAll()
            state.accepting = false
            return all
        })
        retired.releaseOnMain()
    }

    /// The tree is being turned on: its updates are applied again.
    func accept() {
        state.withLock { $0.accepting = true }
    }

    // MARK: What is there

    var isEmpty: Bool {
        state.withLock { $0.forest.isEmpty }
    }

    var nodeCount: Int {
        state.withLock { $0.forest.nodeCount }
    }

    var treeUpdates: Int {
        state.withLock { $0.treeUpdates }
    }

    var locationUpdates: Int {
        state.withLock { $0.locationUpdates }
    }

    var rootKey: Key? {
        state.withLock { $0.forest.rootKey }
    }

    /// What the mirror holds, for a failing test's message.
    var summary: String {
        state.withLock { state in
            "trees \(state.forest.trees.count), nodes \(state.forest.nodeCount), root \(String(describing: state.forest.rootKey)), "
                + "accepting \(state.accepting), tree updates \(state.treeUpdates)"
        }
    }

    /// The root web area's bounds in Chromium's unit.
    var rootBounds: CGRect? {
        state.withLock { state in state.forest.rootKey.flatMap { state.forest.node($0)?.bounds } }
    }

    var title: String {
        state.withLock { $0.forest.title }
    }

    func exists(_ key: Key) -> Bool {
        state.withLock { $0.forest.node(key) != nil }
    }

    // MARK: Elements

    /// The element of a node, made once and kept until the node goes, or until the page navigates (an element is bound to the page's
    /// main-frame generation when it was made: the one a client holds across a navigation stays what it was, and a new query gets a
    /// new one). Asked on the main thread, by AppKit's queries; off it the generation is 0, which no press accepts.
    func element(for key: Key, host: ChromiumRemoteAccessibilityHost?) -> ChromiumAccessibilityElement? {
        let generation: UInt64 = Thread.isMainThread ? MainActor.assumeIsolated { host?.generation ?? 0 } : 0
        let (element, replaced): (ChromiumAccessibilityElement?, ChromiumAccessibilityElement?) = state.withLockUnchecked { state in
            guard state.forest.node(key) != nil else { return (nil, nil) }
            let cached = state.elements[key]
            if let cached, cached.generation == generation {
                return (cached, nil)
            }
            let element = ChromiumAccessibilityElement(mirror: self, key: key, host: host, generation: generation)
            state.elements[key] = element
            return (element, cached)
        }
        // The one it replaced is let go of here, outside the lock.
        withExtendedLifetime(replaced) {}
        return element
    }

    func rootElement(host: ChromiumRemoteAccessibilityHost?) -> ChromiumAccessibilityElement? {
        rootKey.flatMap { element(for: $0, host: host) }
    }

    func childElements(of key: Key, host: ChromiumRemoteAccessibilityHost?) -> [ChromiumAccessibilityElement] {
        let keys = state.withLock { $0.forest.visibleChildren(of: key) }
        return keys.compactMap { element(for: $0, host: host) }
    }

    /// The element's parent: the nearest element above it, and nil for the root (whose parent is the view that hosts the mirror).
    func parentElement(of key: Key, host: ChromiumRemoteAccessibilityHost?) -> ChromiumAccessibilityElement? {
        let parent: Key? = state.withLock { state in
            key == state.forest.rootKey ? nil : state.forest.visibleParent(of: key)
        }
        return parent.flatMap { element(for: $0, host: host) }
    }

    func isRoot(_ key: Key) -> Bool {
        state.withLock { $0.forest.rootKey == key }
    }

    // MARK: Geometry

    /// The node's rectangle in the view's points (top-left origin): Chromium reports physical pixels, and a point is `unitsPerPoint`
    /// of them (the backing scale the service was told).
    func rectInPoints(_ key: Key, unitsPerPoint: CGFloat) -> CGRect {
        let rect = state.withLock { $0.forest.rectInUnits(key) }
        return ChromiumAccessibilityForest.points(rect, unitsPerPoint: unitsPerPoint)
    }

    /// The deepest element that contains `point` (view points), or nil.
    func elementKey(at point: CGPoint, unitsPerPoint: CGFloat) -> Key? {
        let forest = state.withLock { $0.forest }
        guard let root = forest.rootKey else { return nil }
        func rect(_ key: Key) -> CGRect {
            ChromiumAccessibilityForest.points(forest.rectInUnits(key), unitsPerPoint: unitsPerPoint)
        }
        func hit(_ key: Key, depth: Int) -> Key? {
            guard depth < 64 else { return nil }
            // Later siblings are drawn over earlier ones.
            for child in forest.visibleChildren(of: key).reversed() where rect(child).contains(point) {
                return hit(child, depth: depth + 1) ?? child
            }
            return nil
        }
        return hit(root, depth: 0) ?? root
    }

    // MARK: Descriptions

    func describe(_ key: Key) -> Description? {
        state.withLock { state in
            let forest = state.forest
            guard let node = forest.node(key) else { return nil }
            if key == forest.rootKey {
                // An AXWebArea (Q12b): VoiceOver reads the title and the address from it. If it insists on text markers, which come
                // with D4-45, the spike's AXGroup "web content" is the fallback (`ChromiumAccessibilityMirror.rootRole`).
                let title = forest.title.isEmpty ? node.name : forest.title
                return Description(
                    role: Self.rootRole, roleDescription: nil, title: title.isEmpty ? nil : title, label: nil, value: nil,
                    url: URL(string: forest.url(of: key)))
            }
            let label = node.detail.isEmpty ? nil : node.detail
            let url = node.url.isEmpty ? nil : URL(string: node.url)
            let value: Description.Value? = switch node.role {
            case "staticText":
                .string(node.name)
            case "heading":
                .number(node.level)
            case "textField", "searchBox", "textFieldWithComboBox":
                .string(node.value)
            default:
                node.value.isEmpty ? nil : .string(node.value)
            }
            return Description(
                role: Self.role(of: node.role), roleDescription: node.role == "heading" ? "heading" : nil,
                title: node.role == "staticText" || node.name.isEmpty ? nil : node.name, label: label, value: value, url: url)
        }
    }

    /// The root's role (the Q12b default).
    static let rootRole = NSAccessibility.Role(rawValue: "AXWebArea")

    private static func role(of chromium: String) -> NSAccessibility.Role {
        switch chromium {
        case "heading":
            NSAccessibility.Role(rawValue: "AXHeading")
        case "link":
            .link
        case "staticText":
            .staticText
        case "button", "popUpButton":
            .button
        case "toggleButton", "checkBox":
            .checkBox
        case "radioButton", "tab":
            .radioButton
        case "textField", "searchBox", "textFieldWithComboBox":
            .textField
        case "image", "img":
            .image
        case "table":
            .table
        case "row":
            .row
        case "cell", "gridCell":
            .cell
        case "menuItem":
            .menuItem
        default:
            .group
        }
    }
}
