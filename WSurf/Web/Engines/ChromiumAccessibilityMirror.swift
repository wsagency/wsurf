// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4 spike, days 8-9: accessibility for an out-of-process Chromium page. The service runs CEF's windowless tree-only mode
// and sends Chromium's tree updates as JSON; this mirror keeps the nodes and answers VoiceOver with NSAccessibilityElements:
// role, title or value, children, frame, and Press (a click at the element's centre, sent as input). A prototype after CEF's
// own macOS bridge (`osr_accessibility_node_mac.mm`): no text ranges, tables or live regions.

import AppKit
import CefKit

@MainActor
final class ChromiumAccessibilityMirror {
    final class Node {
        let id: Int
        var role = ""
        var name = ""
        var value = ""
        var url = ""
        var level = 0
        var childIDs: [Int] = []
        var bounds = CGRect.zero
        var offsetContainer = -1
        var scrollX = 0.0
        var scrollY = 0.0
        var parentID: Int?
        var element: ChromiumAccessibilityElement?

        init(id: Int) {
            self.id = id
        }
    }

    weak var page: ChromiumPage?
    private(set) var nodes: [Int: Node] = [:]
    private(set) var rootID: Int?
    private(set) var updates = 0

    init(page: ChromiumPage) {
        self.page = page
    }

    var rootElement: ChromiumAccessibilityElement? {
        rootID.flatMap { element(for: $0) }
    }

    func element(for id: Int) -> ChromiumAccessibilityElement? {
        guard let node = nodes[id] else { return nil }
        if let element = node.element {
            return element
        }
        let element = ChromiumAccessibilityElement(mirror: self, nodeID: id)
        node.element = element
        return element
    }

    // MARK: Updates from the service

    func applyTree(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        updates += 1
        // CEF sends either one update or a list of them (`updates`), each with nodes and an optional root.
        let list = (object["updates"] as? [[String: Any]]) ?? [object]
        for update in list {
            if let clear = update["node_id_to_clear"] as? Int, clear > 0 {
                remove(clear, keepSelf: true)
            }
            if let root = update["root_id"] as? Int, root > 0 {
                rootID = root
            }
            for raw in (update["nodes"] as? [[String: Any]]) ?? [] {
                apply(node: raw)
            }
        }
        for node in nodes.values {
            for child in node.childIDs {
                nodes[child]?.parentID = node.id
            }
        }
        if rootID == nil {
            rootID = nodes.values.first { $0.role == "rootWebArea" || $0.role == "webArea" }?.id
        }
        if let page {
            NSAccessibility.post(element: page, notification: .layoutChanged)
        }
    }

    func applyLocations(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return }
        let list = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["changes"] as? [[String: Any]]) ?? []
        for change in list {
            guard let id = change["id"] as? Int, let node = nodes[id] else { continue }
            let location = (change["new_location"] as? [String: Any]) ?? change
            Self.applyBounds(location, to: node)
        }
    }

    private func apply(node raw: [String: Any]) {
        guard let id = raw["id"] as? Int else { return }
        let node = nodes[id] ?? Node(id: id)
        nodes[id] = node
        node.role = raw["role"] as? String ?? node.role
        node.childIDs = (raw["child_ids"] as? [Int]) ?? node.childIDs
        if let location = raw["location"] as? [String: Any] {
            Self.applyBounds(["bounds": location, "offset_container_id": raw["offset_container_id"] ?? -1], to: node)
        } else if let bounds = raw["bounds"] {
            Self.applyBounds(["bounds": bounds, "offset_container_id": raw["offset_container_id"] ?? -1], to: node)
        }
        let attributes = raw["attributes"] as? [String: Any] ?? [:]
        node.name = attributes["name"] as? String ?? node.name
        node.value = attributes["value"] as? String ?? node.value
        node.url = attributes["url"] as? String ?? node.url
        node.level = attributes["hierarchicalLevel"] as? Int ?? node.level
        node.scrollX = Self.number(attributes["scrollX"]) ?? node.scrollX
        node.scrollY = Self.number(attributes["scrollY"]) ?? node.scrollY
    }

    private static func applyBounds(_ raw: [String: Any], to node: Node) {
        let bounds = (raw["bounds"] as? [String: Any]) ?? raw
        if let x = number(bounds["x"]), let y = number(bounds["y"]), let width = number(bounds["width"]), let height = number(bounds["height"]) {
            node.bounds = CGRect(x: x, y: y, width: width, height: height)
        }
        if let container = raw["offset_container_id"] as? Int {
            node.offsetContainer = container
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    private func remove(_ id: Int, keepSelf: Bool) {
        guard let node = nodes[id] else { return }
        for child in node.childIDs {
            remove(child, keepSelf: false)
        }
        if !keepSelf {
            nodes[id] = nil
        }
    }

    // MARK: Geometry

    /// The node's rectangle in the page view's coordinates (points, top-left origin): its bounds are relative to its offset
    /// container, whose scroll offset moves it.
    func rectInView(_ id: Int) -> CGRect {
        guard let node = nodes[id] else { return .zero }
        var rect = node.bounds
        var container = node.offsetContainer
        var hops = 0
        while container >= 0, let parent = nodes[container], hops < 64 {
            rect.origin.x += parent.bounds.minX - parent.scrollX
            rect.origin.y += parent.bounds.minY - parent.scrollY
            container = parent.offsetContainer
            hops += 1
        }
        return rect
    }

    /// Children as VoiceOver should see them: nodes with no role of their own (ignored, inline text boxes) give way to theirs.
    func visibleChildren(of id: Int) -> [Int] {
        guard let node = nodes[id] else { return [] }
        var result: [Int] = []
        for child in node.childIDs {
            guard let childNode = nodes[child] else { continue }
            if Self.isFlattened(childNode.role) {
                result += visibleChildren(of: child)
            } else {
                result.append(child)
            }
        }
        return result
    }

    static func isFlattened(_ role: String) -> Bool {
        ["none", "ignored", "inlineTextBox", "lineBreak", "presentational"].contains(role)
    }

    /// A summary for the driver's log: counts per role and the first headings and links.
    func summary() -> String {
        var counts: [String: Int] = [:]
        for node in nodes.values {
            counts[node.role, default: 0] += 1
        }
        let headings = nodes.values.filter { $0.role == "heading" }.prefix(3).map { "\($0.name)@\(rectInView($0.id).integral)" }
        let links = nodes.values.filter { $0.role == "link" }.prefix(3).map { "\($0.name)@\(rectInView($0.id).integral)" }
        let root = rootID.flatMap { nodes[$0] }
        return "updates \(updates), nodes \(nodes.count), root \(root?.role ?? "nil") '\(root?.name ?? "")', roles \(counts.sorted { $0.value > $1.value }.prefix(10)), headings \(headings), links \(links)"
    }
}

/// One node of the mirror as VoiceOver sees it.
@MainActor
final class ChromiumAccessibilityElement: NSAccessibilityElement {
    private weak var mirror: ChromiumAccessibilityMirror?
    let nodeID: Int

    init(mirror: ChromiumAccessibilityMirror, nodeID: Int) {
        self.mirror = mirror
        self.nodeID = nodeID
        super.init()
    }

    private var node: ChromiumAccessibilityMirror.Node? {
        mirror?.nodes[nodeID]
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        switch node?.role ?? "" {
        case "rootWebArea", "webArea": NSAccessibility.Role("AXWebArea")
        case "heading": NSAccessibility.Role("AXHeading")
        case "link": .link
        case "staticText": .staticText
        case "button", "toggleButton", "popUpButton": .button
        case "textField", "searchBox", "textFieldWithComboBox": .textField
        case "checkBox": .checkBox
        case "radioButton": .radioButton
        case "image", "img": .image
        case "list": .list
        case "table": .table
        case "row": .row
        case "cell", "gridCell": .cell
        default: .group
        }
    }

    override func accessibilityTitle() -> String? {
        guard let node else { return nil }
        return node.role == "staticText" ? nil : (node.name.isEmpty ? nil : node.name)
    }

    override func accessibilityValue() -> Any? {
        guard let node else { return nil }
        switch node.role {
        case "staticText": return node.name.isEmpty ? node.value : node.name
        case "heading": return node.level
        case "textField", "searchBox", "textFieldWithComboBox": return node.value
        default: return node.value.isEmpty ? nil : node.value
        }
    }

    override func accessibilityURL() -> URL? {
        node.flatMap { URL(string: $0.url) }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let mirror else { return nil }
        return mirror.visibleChildren(of: nodeID).compactMap { mirror.element(for: $0) }
    }

    override func accessibilityParent() -> Any? {
        guard let mirror, let page = mirror.page else { return nil }
        var parent = node?.parentID
        while let id = parent, let candidate = mirror.nodes[id], ChromiumAccessibilityMirror.isFlattened(candidate.role) {
            parent = candidate.parentID
        }
        if let id = parent, let element = mirror.element(for: id) {
            return element
        }
        return page
    }

    override func accessibilityFrame() -> NSRect {
        guard let mirror, let page = mirror.page, let window = page.window else { return .zero }
        let rect = mirror.rectInView(nodeID)
        return window.convertToScreen(page.convert(rect, to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let mirror, let page = mirror.page else { return false }
        let rect = mirror.rectInView(nodeID)
        guard rect.width > 0, rect.height > 0 else { return false }
        page.remoteClick(at: CGPoint(x: rect.midX, y: rect.midY))
        return true
    }
}
