// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import Foundation

// D4-41 (out-of-process Chromium, phase 5): the model of a page's accessibility trees, as the service's updates build it. One tree per
// `ax_tree_id` (the page, and one for each frame that has its own), kept in the shape CEF sends them (`osr_accessibility_util.cc`:
// `updates` with `tree_data`, `node_id_to_clear`, `root_id` and `nodes`).
//
// This is plain data (value types, no AppKit) on purpose. The accessibility decode queue applies the updates to it, off the main
// thread (a page's first update is several MB, and its parsed graph is freed there too, never on main), under the lock of
// `ChromiumAccessibilityMirror`, which also answers AppKit's questions from it.

nonisolated struct ChromiumAccessibilityKey: Hashable, Sendable {
    let tree: String
    let id: Int
}

nonisolated struct ChromiumAccessibilityNode: Sendable {
    var role = ""
    var name = ""
    var value = ""
    var detail = ""
    var url = ""
    var level = 0
    var childIDs: [Int] = []
    /// The tree of the frame this node hosts.
    var childTree = ""
    /// Chromium's bounds, in its own unit (physical pixels), relative to `offsetContainer` when there is one.
    var bounds = CGRect.zero
    var offsetContainer = -1
    var scrollX = 0.0
    var scrollY = 0.0
    /// Set by `relink`: the node that lists this one, or hosts the frame whose root this is.
    var parent: ChromiumAccessibilityKey?
}

nonisolated struct ChromiumAccessibilityTree: Sendable {
    var nodes: [Int: ChromiumAccessibilityNode] = [:]
    var rootID = -1
    var parentTree = ""
    var title = ""
    var url = ""
}

nonisolated struct ChromiumAccessibilityForest: Sendable {
    typealias Key = ChromiumAccessibilityKey
    typealias Node = ChromiumAccessibilityNode

    private(set) var trees: [String: ChromiumAccessibilityTree] = [:]
    /// The tree of the page: the last one that said it has no parent.
    private(set) var rootTree = ""

    var isEmpty: Bool {
        rootKey == nil
    }

    func node(_ key: Key) -> Node? {
        trees[key.tree]?.nodes[key.id]
    }

    var rootKey: Key? {
        guard let tree = trees[rootTree], tree.rootID >= 0, tree.nodes[tree.rootID] != nil else { return nil }
        return Key(tree: rootTree, id: tree.rootID)
    }

    var title: String {
        trees[rootTree]?.title ?? ""
    }

    func url(of key: Key) -> String {
        trees[key.tree]?.url ?? ""
    }

    var nodeCount: Int {
        trees.values.reduce(0) { $0 + $1.nodes.count }
    }

    // MARK: Updates from the service

    /// One `ax.tree` message's JSON object. Follows the trees in it, then `relink`s and drops what no tree reaches any more.
    mutating func applyTree(_ object: [String: Any]) {
        guard let treeID = object["ax_tree_id"] as? String, let list = object["updates"] as? [[String: Any]] else { return }
        for update in list {
            apply(update: update, tree: treeID)
        }
        dropUnreachableNodes()
        dropStaleTrees()
        relink()
    }

    /// One `ax.location` message's JSON array.
    mutating func applyLocations(_ list: [[String: Any]]) {
        for change in list {
            guard let treeID = change["ax_tree_id"] as? String, let id = Self.int(change["id"]),
                  let location = change["new_location"] as? [String: Any], trees[treeID]?.nodes[id] != nil else { continue }
            if let bounds = location["bounds"] as? [String: Any], let rect = Self.rect(bounds) {
                trees[treeID]?.nodes[id]?.bounds = rect
            }
            if let container = Self.int(location["offset_container_id"]) {
                trees[treeID]?.nodes[id]?.offsetContainer = container
            }
        }
    }

    private mutating func apply(update: [String: Any], tree treeID: String) {
        // Taken out of the dictionary while it is changed: a second reference would copy every node of the tree on each update.
        var tree = trees.removeValue(forKey: treeID) ?? ChromiumAccessibilityTree()
        if let clear = Self.int(update["node_id_to_clear"]), tree.nodes[clear] != nil {
            if tree.rootID == clear {
                tree.rootID = -1
            }
            Self.remove(clear, from: &tree)
        }
        if update["has_tree_data"] as? Bool == true, let data = update["tree_data"] as? [String: Any] {
            tree.parentTree = data["parent_tree_id"] as? String ?? ""
            tree.title = data["title"] as? String ?? tree.title
            tree.url = data["url"] as? String ?? tree.url
            if tree.parentTree.isEmpty {
                rootTree = treeID
            }
        }
        for raw in (update["nodes"] as? [[String: Any]]) ?? [] {
            guard let id = Self.int(raw["id"]) else { continue }
            var node = tree.nodes[id] ?? Node()
            Self.apply(raw, to: &node)
            tree.nodes[id] = node
        }
        if let root = Self.int(update["root_id"]), tree.nodes[root] != nil {
            tree.rootID = root
        }
        trees[treeID] = tree
    }

    private static func apply(_ raw: [String: Any], to node: inout Node) {
        node.role = raw["role"] as? String ?? node.role
        if let children = raw["child_ids"] as? [Any] {
            node.childIDs = children.compactMap(int)
        }
        if let location = raw["location"] as? [String: Any] {
            node.bounds = rect(location) ?? node.bounds
        }
        if let container = int(raw["offset_container_id"]) {
            node.offsetContainer = container
        }
        // As CEF's own sample: an update that carries attributes replaces them all.
        if let attributes = raw["attributes"] as? [String: Any] {
            node.name = attributes["name"] as? String ?? ""
            node.value = attributes["value"] as? String ?? ""
            node.detail = attributes["description"] as? String ?? ""
            node.url = attributes["url"] as? String ?? ""
            node.level = int(attributes["hierarchicalLevel"]) ?? 0
            node.childTree = attributes["childTreeId"] as? String ?? ""
            node.scrollX = number(attributes["scrollX"]) ?? 0
            node.scrollY = number(attributes["scrollY"]) ?? 0
        }
    }

    private static func remove(_ id: Int, from tree: inout ChromiumAccessibilityTree) {
        var pending = [id]
        while let current = pending.popLast() {
            guard let node = tree.nodes.removeValue(forKey: current) else { continue }
            pending += node.childIDs
        }
    }

    // MARK: Keeping the forest to what can be reached

    /// A node that no longer hangs off its tree's root (its parent dropped it from `child_ids`) is gone. Chromium's own tree does the same:
    /// without this a page that replaces its content all day keeps every node it ever had.
    private mutating func dropUnreachableNodes() {
        for (treeID, tree) in trees where tree.rootID >= 0 {
            var reached: Set<Int> = []
            var pending = [tree.rootID]
            while let current = pending.popLast() {
                guard reached.insert(current).inserted, let node = tree.nodes[current] else { continue }
                pending += node.childIDs
            }
            if reached.count < tree.nodes.count {
                trees[treeID]?.nodes = tree.nodes.filter { reached.contains($0.key) }
            }
        }
    }

    /// Every navigation brings a new tree for the page, and the old one's updates stop: it is dropped with the frames below it. A frame's
    /// tree that arrives before the node that hosts it is kept (it names its parent tree), as is every tree that is not under an old root.
    private mutating func dropStaleTrees() {
        var stale = Set(trees.filter { $0.value.parentTree.isEmpty && $0.key != rootTree }.keys)
        guard !stale.isEmpty else { return }
        var grew = true
        while grew {
            grew = false
            for (id, tree) in trees where !stale.contains(id) && stale.contains(tree.parentTree) {
                stale.insert(id)
                grew = true
            }
        }
        for id in stale {
            trees[id] = nil
        }
    }

    /// Parents, from the children lists and from the frames that host child trees.
    mutating func relink() {
        var links: [(child: Key, parent: Key)] = []
        for (treeID, tree) in trees {
            for (id, node) in tree.nodes {
                let parent = Key(tree: treeID, id: id)
                links += node.childIDs.map { (Key(tree: treeID, id: $0), parent) }
                if !node.childTree.isEmpty, let child = trees[node.childTree], child.rootID >= 0 {
                    links.append((Key(tree: node.childTree, id: child.rootID), parent))
                }
            }
        }
        for link in links {
            trees[link.child.tree]?.nodes[link.child.id]?.parent = link.parent
        }
    }

    // MARK: Structure as VoiceOver sees it

    /// The node's children: its own, then the root of the frame it hosts.
    func children(of key: Key) -> [Key] {
        guard let node = node(key) else { return [] }
        var result = node.childIDs.map { Key(tree: key.tree, id: $0) }
        if !node.childTree.isEmpty, let child = trees[node.childTree], child.rootID >= 0 {
            result.append(Key(tree: node.childTree, id: child.rootID))
        }
        return result
    }

    /// Children for VoiceOver: nodes that are not elements give way to theirs; leaves have none.
    func visibleChildren(of key: Key) -> [Key] {
        guard let node = node(key), !Self.leafRoles.contains(node.role) else { return [] }
        var result: [Key] = []
        for child in children(of: key) {
            guard let childNode = self.node(child) else { continue }
            if isElement(childNode, key: child) {
                result.append(child)
            } else {
                result += visibleChildren(of: child)
            }
        }
        return result
    }

    func visibleParent(of key: Key) -> Key? {
        var parent = node(key)?.parent
        while let current = parent, let node = node(current), !isElement(node, key: current) {
            parent = node.parent
        }
        return parent
    }

    func isElement(_ node: Node, key: Key) -> Bool {
        if key == rootKey {
            return true
        }
        if Self.flattenedRoles.contains(node.role) {
            return false
        }
        switch node.role {
        case "staticText":
            return !node.name.isEmpty && !Self.leafRoles.contains(leafAncestorRole(of: node))
        case "image", "img":
            return !node.name.isEmpty
        default:
            return true
        }
    }

    private func leafAncestorRole(of node: Node) -> String {
        var parent = node.parent
        while let current = parent, let parentNode = self.node(current) {
            if Self.leafRoles.contains(parentNode.role) {
                return parentNode.role
            }
            parent = parentNode.parent
        }
        return ""
    }

    /// Roles that are only structure: their children are what VoiceOver walks.
    private static let flattenedRoles: Set<String> = [
        "none", "ignored", "inlineTextBox", "lineBreak", "presentational", "genericContainer", "paragraph", "section", "div", "group",
        "main", "article", "region", "navigation", "banner", "contentInfo", "complementary", "form", "listItem", "list", "iframe",
        "iframePresentational", "rootWebArea", "webArea", "layoutTable", "layoutTableRow", "layoutTableCell", "figure", "blockquote",
        "label", "legend", "time", "abbr", "emphasis", "strong", "mark", "code",
    ]

    /// Elements that speak their own name; their text children would only repeat it.
    static let leafRoles: Set<String> = [
        "heading", "link", "button", "toggleButton", "popUpButton", "menuItem", "tab", "checkBox", "radioButton", "textField",
        "searchBox", "textFieldWithComboBox", "comboBoxGrouping", "image", "img", "staticText",
    ]

    // MARK: Geometry

    /// The node's rectangle in Chromium's unit (physical pixels), top-left origin, relative to the root web area's own origin.
    /// Bounds are relative to the offset container, whose scroll offset moves them; a frame's root is placed by the node that hosts it.
    func rectInUnits(_ key: Key) -> CGRect {
        var rect = absoluteRect(key, depth: 0)
        if let root = rootKey {
            let origin = absoluteRect(root, depth: 0).origin
            rect.origin.x -= origin.x
            rect.origin.y -= origin.y
        }
        return rect
    }

    private func absoluteRect(_ key: Key, depth: Int) -> CGRect {
        guard depth < 64, let node = node(key) else { return .zero }
        var rect = node.bounds
        if node.offsetContainer >= 0, let container = trees[key.tree]?.nodes[node.offsetContainer] {
            let origin = absoluteRect(Key(tree: key.tree, id: node.offsetContainer), depth: depth + 1).origin
            rect.origin.x += origin.x - container.scrollX
            rect.origin.y += origin.y - container.scrollY
        } else if key.tree != rootTree {
            // A frame's root: offset by the node in the parent tree that hosts the frame.
            var parent = node.parent
            while let current = parent, current.tree == key.tree {
                parent = self.node(current)?.parent
            }
            if let host = parent {
                let origin = absoluteRect(host, depth: depth + 1).origin
                rect.origin.x += origin.x
                rect.origin.y += origin.y
            }
        }
        return rect
    }

    /// Chromium's unit to the view's points: the unit is physical pixels, so one point is `unitsPerPoint` of them (the backing scale
    /// the service was told, which is the scale its frames are painted at).
    static func points(_ rect: CGRect, unitsPerPoint scale: CGFloat) -> CGRect {
        guard scale > 0, scale != 1 else { return rect }
        return CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
    }

    // MARK: Values

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            number
        case let number as Double:
            number.isFinite ? Int(number) : nil
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            number
        case let number as Int:
            Double(number)
        default:
            nil
        }
    }

    private static func rect(_ raw: [String: Any]) -> CGRect? {
        guard let x = number(raw["x"]), let y = number(raw["y"]), let width = number(raw["width"]), let height = number(raw["height"])
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
