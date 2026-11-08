// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4 spike, days 8-9: accessibility for an out-of-process Chromium page. The service runs CEF's windowless tree-only mode
// and sends Chromium's tree updates as JSON (CEF's `osr_accessibility_util.cc` format: `ax_tree_id`, `updates` with
// `tree_data`, `node_id_to_clear`, `root_id` and `nodes`); this mirror keeps the trees (one per frame) and answers
// VoiceOver with NSAccessibilityElements. It follows CEF's own sample bridge (`tests/shared/browser/osr_accessibility_*`),
// with one change for VoiceOver's sequential navigation (VO-arrow keys): containers with no name of their own are flattened,
// and headings, links and buttons are leaves that speak their name. Press is a click at the element's centre, sent as
// input. A prototype: no text ranges, no search predicates (the rotor), no tables or live regions.

import AppKit
import CefKit

@MainActor
final class ChromiumAccessibilityMirror {
    struct Key: Hashable {
        let tree: String
        let id: Int
    }

    final class Node {
        let key: Key
        var role = ""
        var name = ""
        var value = ""
        var detail = ""
        var url = ""
        var level = 0
        var childIDs: [Int] = []
        var childTree = ""
        var bounds = CGRect.zero
        var offsetContainer = -1
        var scrollX = 0.0
        var scrollY = 0.0
        var parent: Key?
        var element: ChromiumAccessibilityElement?

        init(key: Key) {
            self.key = key
        }
    }

    final class Tree {
        var nodes: [Int: Node] = [:]
        var rootID = -1
        var parentTree = ""
        var title = ""
        var url = ""
    }

    weak var page: ChromiumPage?
    private(set) var trees: [String: Tree] = [:]
    private(set) var rootTree = ""
    private(set) var updates = 0
    private(set) var locationUpdates = 0

    init(page: ChromiumPage) {
        self.page = page
    }

    func node(_ key: Key) -> Node? {
        trees[key.tree]?.nodes[key.id]
    }

    var rootKey: Key? {
        guard let tree = trees[rootTree], tree.rootID > 0 else { return nil }
        return Key(tree: rootTree, id: tree.rootID)
    }

    var rootElement: ChromiumAccessibilityElement? {
        rootKey.flatMap { element(for: $0) }
    }

    var title: String {
        trees[rootTree]?.title ?? ""
    }

    func element(for key: Key) -> ChromiumAccessibilityElement? {
        guard let node = self.node(key) else { return nil }
        if let element = node.element {
            return element
        }
        let element = ChromiumAccessibilityElement(mirror: self, key: key)
        node.element = element
        return element
    }

    // MARK: Updates from the service

    func applyTree(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let treeID = object["ax_tree_id"] as? String, let list = object["updates"] as? [[String: Any]] else { return }
        updates += 1
        for update in list {
            apply(update: update, tree: treeID)
        }
        relink()
        if let page {
            NSAccessibility.post(element: page, notification: .layoutChanged)
        }
    }

    func applyLocations(_ data: Data) {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        locationUpdates += 1
        for change in list {
            guard let treeID = change["ax_tree_id"] as? String, let id = Self.int(change["id"]),
                  let location = change["new_location"] as? [String: Any], let node = trees[treeID]?.nodes[id] else { continue }
            if let bounds = location["bounds"] as? [String: Any] {
                node.bounds = Self.rect(bounds) ?? node.bounds
            }
            if let container = Self.int(location["offset_container_id"]) {
                node.offsetContainer = container
            }
        }
    }

    private func apply(update: [String: Any], tree treeID: String) {
        let tree = trees[treeID] ?? Tree()
        trees[treeID] = tree
        if let clear = Self.int(update["node_id_to_clear"]), let node = tree.nodes[clear] {
            if tree.rootID == clear {
                tree.rootID = -1
            }
            remove(node, from: tree)
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
            let node = tree.nodes[id] ?? Node(key: Key(tree: treeID, id: id))
            tree.nodes[id] = node
            apply(raw, to: node)
        }
        if let root = Self.int(update["root_id"]), tree.nodes[root] != nil {
            tree.rootID = root
        }
    }

    private func apply(_ raw: [String: Any], to node: Node) {
        node.role = raw["role"] as? String ?? node.role
        if let children = raw["child_ids"] as? [Any] {
            node.childIDs = children.compactMap(Self.int)
        }
        if let location = raw["location"] as? [String: Any] {
            node.bounds = Self.rect(location) ?? node.bounds
        }
        if let container = Self.int(raw["offset_container_id"]) {
            node.offsetContainer = container
        }
        // As CEF's sample: an update that carries attributes replaces them all.
        if let attributes = raw["attributes"] as? [String: Any] {
            node.name = attributes["name"] as? String ?? ""
            node.value = attributes["value"] as? String ?? ""
            node.detail = attributes["description"] as? String ?? ""
            node.url = attributes["url"] as? String ?? ""
            node.level = Self.int(attributes["hierarchicalLevel"]) ?? 0
            node.childTree = attributes["childTreeId"] as? String ?? ""
            node.scrollX = Self.number(attributes["scrollX"]) ?? 0
            node.scrollY = Self.number(attributes["scrollY"]) ?? 0
        }
    }

    private func remove(_ node: Node, from tree: Tree) {
        for child in node.childIDs {
            if let childNode = tree.nodes[child] {
                remove(childNode, from: tree)
            }
        }
        node.element = nil
        tree.nodes[node.key.id] = nil
    }

    /// Parents, from the children lists and from the frames that host child trees.
    private func relink() {
        for tree in trees.values {
            for node in tree.nodes.values {
                for child in node.childIDs {
                    tree.nodes[child]?.parent = node.key
                }
                if !node.childTree.isEmpty, let child = trees[node.childTree], let root = child.nodes[child.rootID] {
                    root.parent = node.key
                }
            }
        }
    }

    // MARK: Structure as VoiceOver sees it

    /// The node's children: its own, then the root of the frame it hosts.
    func children(of key: Key) -> [Key] {
        guard let node = self.node(key) else { return [] }
        var result = node.childIDs.map { Key(tree: key.tree, id: $0) }
        if !node.childTree.isEmpty, let child = trees[node.childTree], child.rootID > 0 {
            result.append(Key(tree: node.childTree, id: child.rootID))
        }
        return result
    }

    /// Children for VoiceOver: nodes that are not elements give way to theirs; leaves have none.
    func visibleChildren(of key: Key) -> [Key] {
        guard let node = self.node(key), !Self.isLeaf(node.role) else { return [] }
        var result: [Key] = []
        for child in children(of: key) {
            guard let childNode = self.node(child) else { continue }
            if isElement(childNode) {
                result.append(child)
            } else {
                result += visibleChildren(of: child)
            }
        }
        return result
    }

    func visibleParent(of key: Key) -> Key? {
        var parent = node(key)?.parent
        while let current = parent, let node = self.node(current), !isElement(node) {
            parent = node.parent
        }
        return parent
    }

    func isElement(_ node: Node) -> Bool {
        if node.key == rootKey {
            return true
        }
        switch node.role {
        case "none", "ignored", "inlineTextBox", "lineBreak", "presentational", "genericContainer", "paragraph", "section",
             "div", "group", "main", "article", "region", "navigation", "banner", "contentInfo", "complementary", "form",
             "listItem", "list", "iframe", "iframePresentational", "rootWebArea", "webArea", "layoutTable", "layoutTableRow",
             "layoutTableCell", "figure", "blockquote", "label", "legend", "time", "abbr", "emphasis", "strong", "mark", "code":
            return false
        case "staticText":
            return !node.name.isEmpty && !Self.isLeaf(parentRole(node))
        case "image", "img":
            return !node.name.isEmpty
        default:
            return true
        }
    }

    private func parentRole(_ node: Node) -> String {
        var parent = node.parent
        while let current = parent, let parentNode = self.node(current) {
            if Self.isLeaf(parentNode.role) {
                return parentNode.role
            }
            parent = parentNode.parent
        }
        return ""
    }

    /// Elements that speak their own name; their text children would only repeat it.
    static func isLeaf(_ role: String) -> Bool {
        ["heading", "link", "button", "toggleButton", "popUpButton", "menuItem", "tab", "checkBox", "radioButton", "textField",
         "searchBox", "textFieldWithComboBox", "comboBoxGrouping", "image", "img", "staticText"].contains(role)
    }

    // MARK: Geometry

    /// The node's rectangle in the page view's coordinates (points, top-left origin). Bounds are relative to the offset
    /// container, whose scroll offset moves them; a frame's root is placed by the node that hosts the frame.
    func rectInView(_ key: Key) -> CGRect {
        var rect = absoluteRect(key, depth: 0)
        // Chromium may report physical pixels: the root web area spans the view, which calibrates the unit.
        let scale = unitsPerPoint
        if scale > 0, abs(scale - 1) > 0.01 {
            rect = CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
        }
        return rect
    }

    var unitsPerPoint: CGFloat {
        guard let rootKey, let root = node(rootKey), let page, page.bounds.width > 0, root.bounds.width > 0 else { return 1 }
        let ratio = root.bounds.width / page.bounds.width
        return ratio > 1.5 ? ratio : 1
    }

    private func absoluteRect(_ key: Key, depth: Int) -> CGRect {
        guard depth < 64, let node = self.node(key) else { return .zero }
        var rect = node.bounds
        if node.offsetContainer >= 0, let container = trees[key.tree]?.nodes[node.offsetContainer] {
            let origin = absoluteRect(container.key, depth: depth + 1).origin
            rect.origin.x += origin.x - container.scrollX
            rect.origin.y += origin.y - container.scrollY
        } else if key.tree != rootTree {
            // A frame's root: offset by the frame's host in the parent tree.
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

    // MARK: Helpers

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: number
        case let number as Double: Int(number)
        case let string as String: Int(string)
        default: nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as Int: Double(number)
        default: nil
        }
    }

    private static func rect(_ raw: [String: Any]) -> CGRect? {
        guard let x = number(raw["x"]), let y = number(raw["y"]), let width = number(raw["width"]), let height = number(raw["height"])
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// A summary for the driver's log: counts per role, the first headings and links, the root and its unit.
    func summary() -> String {
        var counts: [String: Int] = [:]
        var total = 0
        for tree in trees.values {
            for node in tree.nodes.values {
                counts[node.role, default: 0] += 1
                total += 1
            }
        }
        let all = trees.values.flatMap { Array($0.nodes.values) }
        let headings = all.filter { $0.role == "heading" }.prefix(3).map { "'\($0.name)'@\(rectInView($0.key).integral)" }
        let links = all.filter { $0.role == "link" }.prefix(3).map { "'\($0.name)'@\(rectInView($0.key).integral)" }
        let root = rootKey.flatMap { node($0) }
        let pageSize = page.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "nil"
        return "updates \(updates) (+\(locationUpdates) location), trees \(trees.count), nodes \(total), root \(root?.role ?? "nil") "
            + "'\(title)' bounds \(root?.bounds.integral ?? .zero) in a \(pageSize) view (units per point \(unitsPerPoint)), "
            + "roles \(counts.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) \($0.value)" }), headings \(headings), links \(links)"
    }
}

/// One node of the mirror as VoiceOver sees it. NSAccessibilityElement is not main-actor isolated, so the overrides are
/// nonisolated; AppKit asks for accessibility on the main thread, where they read the mirror.
@MainActor
final class ChromiumAccessibilityElement: NSAccessibilityElement {
    private weak var mirror: ChromiumAccessibilityMirror?
    let key: ChromiumAccessibilityMirror.Key

    init(mirror: ChromiumAccessibilityMirror, key: ChromiumAccessibilityMirror.Key) {
        self.mirror = mirror
        self.key = key
        super.init()
    }

    private var node: ChromiumAccessibilityMirror.Node? {
        mirror?.node(key)
    }

    private var isRoot: Bool {
        mirror?.rootKey == key
    }

    nonisolated override func isAccessibilityElement() -> Bool {
        MainActor.assumeIsolated { node != nil }
    }

    nonisolated override func accessibilityRole() -> NSAccessibility.Role? {
        MainActor.assumeIsolated { role?.rawValue }.map { NSAccessibility.Role(rawValue: $0) }
    }

    private var role: NSAccessibility.Role? {
        if isRoot {
            // An AXWebArea makes VoiceOver ask for text markers, which the prototype does not have.
            return ChromiumOOP.environment("WSURF_OOP_AX_ROOT") == "webArea" ? NSAccessibility.Role("AXWebArea") : .group
        }
        return switch node?.role ?? "" {
        case "heading": NSAccessibility.Role("AXHeading")
        case "link": .link
        case "staticText": .staticText
        case "button", "popUpButton": .button
        case "toggleButton", "checkBox": .checkBox
        case "radioButton": .radioButton
        case "textField", "searchBox", "textFieldWithComboBox": .textField
        case "image", "img": .image
        case "table": .table
        case "row": .row
        case "cell", "gridCell": .cell
        case "menuItem": .menuItem
        case "tab": .radioButton
        default: .group
        }
    }

    nonisolated override func accessibilityRoleDescription() -> String? {
        let own: String? = MainActor.assumeIsolated {
            if isRoot {
                return "web content"
            }
            return node?.role == "heading" ? "heading" : nil
        }
        return own ?? super.accessibilityRoleDescription()
    }

    nonisolated override func accessibilityTitle() -> String? {
        MainActor.assumeIsolated {
            guard let node else { return nil }
            if isRoot {
                return mirror?.title.isEmpty == false ? mirror?.title : node.name
            }
            return node.role == "staticText" || node.name.isEmpty ? nil : node.name
        }
    }

    nonisolated override func accessibilityLabel() -> String? {
        MainActor.assumeIsolated {
            guard let node, !node.detail.isEmpty else { return nil }
            return node.detail
        }
    }

    nonisolated override func accessibilityValue() -> Any? {
        let value: (any Sendable)? = MainActor.assumeIsolated {
            guard let node else { return nil }
            switch node.role {
            case "staticText": return node.name
            case "heading": return node.level
            case "textField", "searchBox", "textFieldWithComboBox": return node.value
            default: return node.value.isEmpty ? nil : node.value
            }
        }
        return value
    }

    nonisolated override func accessibilityURL() -> URL? {
        MainActor.assumeIsolated { node.flatMap { URL(string: $0.url) } }
    }

    nonisolated override func accessibilityChildren() -> [Any]? {
        let children: [ChromiumAccessibilityElement]? = MainActor.assumeIsolated {
            guard let mirror else { return nil }
            return mirror.visibleChildren(of: key).compactMap { mirror.element(for: $0) }
        }
        return children
    }

    nonisolated override func accessibilityParent() -> Any? {
        let parent: (element: ChromiumAccessibilityElement?, page: ChromiumPage?) = MainActor.assumeIsolated {
            guard let mirror, let page = mirror.page else { return (nil, nil) }
            if !isRoot, let key = mirror.visibleParent(of: key), let element = mirror.element(for: key) {
                return (element, nil)
            }
            return (nil, page)
        }
        if let element = parent.element {
            return element
        }
        return parent.page
    }

    nonisolated override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated {
            guard let mirror, let page = mirror.page, let window = page.window else { return .zero }
            let rect = mirror.rectInView(key)
            return window.convertToScreen(page.convert(rect, to: nil))
        }
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let mirror, let page = mirror.page else { return false }
            let rect = mirror.rectInView(key)
            guard rect.width > 0, rect.height > 0 else { return false }
            page.remoteClick(at: CGPoint(x: rect.midX, y: rect.midY))
            return true
        }
    }
}
