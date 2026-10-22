// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP

/// Targets named by selector, and drags.
@MainActor
extension MCPBrowserSession {
    struct DragTargets {
        let source: PageDriver.DragEnd
        let destination: PageDriver.DragDestination

        var usesSelector: Bool {
            let ends = [source, destination.named].compactMap { $0 }
            return ends.contains { if case .selector = $0 { true } else { false } }
        }
    }

    /// One source (ref or selector) and one destination (toRef, toSelector, or dx with dy), or what is wrong with the request.
    static func dragTargets(_ arguments: [String: Value]) -> Result<DragTargets, PageDriver.TargetFailure> {
        func refuse(_ message: String) -> Result<DragTargets, PageDriver.TargetFailure> {
            .failure(.init(message: message))
        }
        let source: PageDriver.DragEnd
        switch (arguments["ref"]?.intValue, arguments["selector"]?.stringValue) {
        case (let ref?, nil):
            source = .ref(ref)
        case (nil, let selector?):
            source = .selector(selector)
        default:
            return refuse("Name the source with exactly one of ref and selector.")
        }
        let named = [arguments["toRef"] != nil, arguments["toSelector"] != nil, arguments["dx"] != nil || arguments["dy"] != nil]
        guard named.filter({ $0 }).count == 1 else { return refuse("Name the destination with exactly one of toRef, toSelector, and dx with dy.") }
        if let ref = arguments["toRef"]?.intValue { return .success(.init(source: source, destination: .end(.ref(ref)))) }
        if let selector = arguments["toSelector"]?.stringValue { return .success(.init(source: source, destination: .end(.selector(selector)))) }
        guard let dx = arguments["dx"]?.intValue, let dy = arguments["dy"]?.intValue else { return refuse("Give both dx and dy.") }
        guard dx != 0 || dy != 0 else { return refuse("dx and dy cannot both be 0.") }
        return .success(.init(source: source, destination: .offset(dx: dx, dy: dy)))
    }

    func dragAction(arguments: [String: Value], view: BrowserPage) async -> String {
        switch Self.dragTargets(arguments) {
        case .failure(let failed):
            return failed.message
        case .success(let targets):
            return await PageDriver.drag(
                from: targets.source, to: targets.destination, pointer: arguments["pointer"]?.boolValue ?? false, in: view)
        }
    }

    /// Runs before `usePage` looks at refs. A tool that names its target by selector gets the control the selector names as a
    /// registered ref, so every check that applies to a ref applies to it; a drag only has its arguments checked, because it
    /// finds its own ends. A selector reads the page's structure, so it needs development access, not only control.
    /// Returns a refusal, or nil with `arguments` rewritten.
    func prepareTargets(
        _ entry: MCPToolCatalog.Entry, arguments: inout [String: Value], tab: BrowserTab, view: BrowserPage, generation: Int, url: URL
    ) async -> CallTool.Result? {
        let name = entry.name
        let needsDevelopment = "A selector needs development access. Use readPage and a ref, or ask for development access with requestAccess."
        if name == "dragOnPage" {
            switch Self.dragTargets(arguments) {
            case .failure(let failed):
                return failure(failed.message)
            case .success(let targets):
                return targets.usesSelector && !mayProceed(tab, capability: .development) ? failure(needsDevelopment) : nil
            }
        }
        guard let kinds = MCPToolCatalog.selectorTargets[name] else { return nil }
        guard let selector = arguments["selector"]?.stringValue else {
            return arguments["ref"] == nil ? failure("Name the control with a ref from readPage or with a selector.") : nil
        }
        guard arguments["ref"] == nil else { return failure("Name the control with either ref or selector, not both.") }
        guard mayProceed(tab, capability: .development) else { return failure(needsDevelopment) }
        let scope = PageAutomationGuard(
            documentURL: url.absoluteString, snapshot: nil,
            validate: { [weak self, weak tab, weak view] in
                guard let self, let tab, let view, tab.isLive(view, generation: generation) else { return false }
                return self.mayProceed(tab, capability: .development) && self.isReachable(tab)
            })
        let outcome = await PageAutomationGuard.$current.withValue(scope) { () -> Result<PageDriver.ControlTarget, PageDriver.TargetFailure> in
            guard scope.validate(), webURL(of: tab) == url else { return .failure(.init(message: "Page access changed. Read the page again.")) }
            return await PageDriver.resolveControl(selector: selector, kinds: kinds.isEmpty ? nil : kinds, in: view)
        }
        switch outcome {
        case .failure(let failed):
            return failure(failed.message)
        case .success(let target):
            guard scope.validate(), !Task.isCancelled else { return failure("Page access changed before the operation finished. Its contents were not returned.") }
            // The client holds this observation from now on; one it already holds keeps its id.
            if observations[tab.id]?.id != target.observationID {
                observations[tab.id] = PageObservation(id: target.observationID, snapshot: target.observationID, documentURL: target.url)
            }
            arguments["selector"] = nil
            arguments["ref"] = .int(target.ref)
            arguments["observationID"] = .string(target.observationID)
            return nil
        }
    }
}
