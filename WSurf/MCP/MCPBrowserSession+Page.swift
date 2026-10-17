// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CoreGraphics
import Foundation
import MCP

/// Reading and acting on a shared page.
@MainActor
extension MCPBrowserSession {
    func usePage(
        _ entry: MCPToolCatalog.Entry, arguments: [String: Value], tab: BrowserTab, capability: Scope
    ) async -> CallTool.Result {
        let name = entry.name
        // A secret is typed only in the Developer tier. Refused before the page is touched, and registered before it is typed.
        let secretEntry = Self.secretEntry(tool: name, arguments: arguments)
        if let secretEntry, let refusal = secretEntryRefusal(secretEntry, tab: tab) {
            return refusal
        }
        let typesSecret = secretEntry != nil
        tab.setExternalAutomationWorking(true)
        defer { tab.setExternalAutomationWorking(false) }
        tab.realizeDeferredSession()
        let view = tab.page
        // The view and generation this call started on. The guard below refuses to continue once either changes.
        let generation = tab.pageGeneration
        guard tab.isLive(view, generation: generation) else { return failure("The page is not ready. Try again.") }
        guard let url = webURL(of: tab) else { return failure("The webpage is unavailable.") }
        let usesRef = entry.usesRef || arguments["ref"] != nil
        let observation = observations[tab.id]
        if usesRef {
            guard let observation, observation.id == arguments["observationID"]?.stringValue,
                observation.documentURL == url.absoluteString
            else { return failure("The observation is stale. Use readPage again.") }
        }
        let scope = PageAutomationGuard(
            documentURL: url.absoluteString, snapshot: usesRef ? observation?.snapshot : nil,
            validate: { [weak self, weak tab, weak view] in
                guard let self, let tab, let view, tab.isLive(view, generation: generation) else { return false }
                return self.mayProceed(tab, capability: capability)
                    && (!typesSecret || self.mayProceed(tab, capability: .developer))
                    && (capability != .control || self.onScreen(tab))
            }
        )
        return await PageAutomationGuard.$current.withValue(scope) {
            guard scope.validate(), webURL(of: tab) == url else { return failure("Page access changed. Read the page again.") }
            return await PageDriver.$expectedObservation.withValue(usesRef ? observation?.snapshot : nil) {
                var capturedImage: Data?
                let output: String
                if name == "screenshotPage" {
                    let request = Self.screenshotTarget(arguments)
                    if let message = request.error {
                        output = message
                    } else {
                        // A control ref needs read access; a non-control inspection ref needs current development access, asked
                        // again inside the driver before work, after each await and before pixels are returned.
                        let developmentAllowed = { [weak self, weak tab] in
                            guard let self, let tab else { return false }
                            return self.mayProceed(tab, capability: .development)
                        }
                        // The Developer tier types its own test secrets, so its screenshots cover filled sensitive fields; anywhere
                        // else a filled sensitive field still prevents the capture.
                        let outcome = await PageDriver.screenshot(
                            request.target, developmentAllowed: developmentAllowed, maximumBytes: Self.screenshotBytes,
                            masking: screenshotMasking(for: tab), in: view)
                        switch outcome {
                        case .success(let capture):
                            let box = capture.bounds
                            let text =
                                "Screenshot captured. Shows viewport CSS pixels x \(Int(box.minX.rounded())), y \(Int(box.minY.rounded())), "
                                + "\(Int(box.width.rounded())) by \(Int(box.height.rounded())); image scale \(String(format: "%.2f", capture.scale)) px per CSS px.\n"
                                + (await PageDriver.snapshot(view, viewportOnly: true))
                            // The snapshot above was the last await: development access is asked once more right before the
                            // image is attached, so a revoke during it never returns an inspection image.
                            if capture.requiresDevelopment, !developmentAllowed() {
                                output = ScreenshotFailure.needsDevelopment.message
                            } else {
                                capturedImage = capture.jpeg
                                output = text
                            }
                        case .failure(let failure):
                            output = failure.message
                        }
                    }
                } else {
                    output = await pageAction(name: name, arguments: arguments, view: view, secret: secretEntry)
                    if let secretEntry {
                        finishSecretEntry(secretEntry, tab: tab, view: view)
                    }
                }
                guard scope.validate(), !Task.isCancelled else {
                    observations[tab.id] = nil
                    return failure("Page access changed before the operation finished. Its contents were not returned.")
                }
                let prefixes = [
                    "PAGE TEXT:", "Clicked", "Typed", "Selected", "Scrolled", "Already at", "Went back.",
                    "CONTROL:", "Condition met.", "Set checked", "Checked state", "Screenshot captured.", "Hovered.", "Sent ", "ELEMENTS:", "ELEMENT:",
                ]
                let succeeded =
                    prefixes.contains { output.hasPrefix($0) }
                    || (name == "fillFields" && output.hasPrefix("Filled "))
                var content: [String: Value] = ["tabID": .string(tab.id.uuidString), "content": .string(AgentToolkit.untrusted(output))]
                var delivered: PageObservation?
                if let current = PageDriver.observation(in: view), current.url == webURL(of: tab)?.absoluteString,
                    output.contains("observationID: " + current.id) {
                    delivered = PageObservation(id: current.id, snapshot: current.id, documentURL: current.url)
                    content["observationID"] = .string(current.id)
                    if PageOutputBudget.cost(current.url) <= 512 { content["url"] = .string(current.url) }
                }
                let value: Value = .object(content)
                var blocks: [MCP.Tool.Content] = [.text(text: encoded(value), annotations: nil, _meta: nil)]
                if let capturedImage { blocks.append(.image(data: capturedImage.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)) }
                let result = CallTool.Result(content: blocks, structuredContent: Optional.some(value), isError: !succeeded)
                // A refused reply grants nothing: the client never saw its observation ID or links.
                if capturedImage != nil, Self.replyBytes(result) > MCPMessageFramer.maximumBytes {
                    observations[tab.id] = nil
                    return failure("The screenshot is too large to return. Use readPage for redacted text.")
                }
                observations[tab.id] = delivered
                hasReadContent = true
                destinations.formUnion(PageDriver.listedLinks(in: output).map { destinationKey($0.url) })
                return result
            }
        }
    }

    /// `ref` or `region`, never both. `region` was shape-checked by the catalog.
    private static func screenshotTarget(_ arguments: [String: Value]) -> (target: ScreenshotTarget, error: String?) {
        func number(_ box: [String: Value], _ key: String) -> CGFloat {
            switch box[key] {
            case .int(let value):
                CGFloat(value)
            case .double(let value):
                CGFloat(value)
            default:
                .nan
            }
        }
        let ref = arguments["ref"]?.intValue
        if case .object(let box)? = arguments["region"] {
            if ref != nil { return (.viewport, "Use either ref or region, not both.") }
            return (.region(CGRect(x: number(box, "x"), y: number(box, "y"), width: number(box, "width"), height: number(box, "height"))), nil)
        }
        return (ref.map { .element(ref: $0) } ?? .viewport, nil)
    }

    private func pageAction(name: String, arguments: [String: Value], view: BrowserPage, secret: SecretEntry?) async -> String {
        let ref = arguments["ref"]?.intValue ?? 0
        switch name {
        case "readPage":
            return await PageDriver.readRenderedPage(
                view, lookingFor: arguments["lookingFor"]?.stringValue ?? "", textOffset: arguments["textOffset"]?.intValue ?? 0,
                controlOffset: arguments["controlOffset"]?.intValue ?? 0,
                scope: arguments["scope"]?.stringValue ?? "", viewportOnly: arguments["viewportOnly"]?.boolValue ?? false)
        case "clickOnPage":
            return await PageDriver.click(ref: ref, label: "", in: view, announced: true)
        case "typeOnPage":
            return await PageDriver.type(
                text: arguments["text"]?.stringValue ?? "", intoField: "", ref: ref, submit: arguments["submit"]?.boolValue ?? false,
                allowSensitive: secret != nil, secretWritten: secretWriteSink, in: view, announced: true)
        case "selectOption":
            return await PageDriver.selectOption(arguments["option"]?.stringValue ?? "", ref: ref, field: "", in: view, announced: true)
        case "scrollPage":
            return await PageDriver.scroll(direction: arguments["direction"]?.stringValue ?? "", ref: ref, in: view)
        case "hoverOnPage":
            return await PageDriver.hover(ref: ref, in: view)
        case "pressKey":
            return await PageDriver.pressKey(arguments["key"]?.stringValue ?? "", ref: ref, in: view)
        case "fillFields":
            let fields =
                arguments["fields"]?.arrayValue?.compactMap { value -> PageDriver.FieldValue? in
                    guard case .object(let field) = value, let ref = field["ref"]?.intValue,
                        let value = field["value"]?.stringValue, let select = field["select"]?.boolValue
                    else { return nil }
                    return .init(ref: ref, value: value, select: select)
                } ?? []
            return await PageDriver.fillFields(
                fields, secretRefs: secret?.refs ?? [], secretWritten: secretWriteSink, in: view, announced: true)
        case "inspectControl":
            return await PageDriver.inspectControl(ref: ref, offset: arguments["offset"]?.intValue ?? 0, in: view)
        case "setChecked":
            return await PageDriver.setChecked(ref: ref, checked: arguments["checked"]?.boolValue ?? false, in: view, announced: true)
        case "waitForPage":
            return await PageDriver.waitForPage(
                condition: arguments["condition"]?.stringValue ?? "", value: arguments["value"]?.stringValue ?? "",
                timeout: arguments["timeout"]?.intValue ?? 5, in: view)
        case "findElements":
            return await PageDriver.findElements(
                selector: arguments["selector"]?.stringValue ?? "", offset: arguments["offset"]?.intValue ?? 0,
                limit: arguments["limit"]?.intValue ?? MCPDevelopmentTools.defaultLimit, in: view)
        case "inspectElement":
            return await PageDriver.inspectElement(ref: ref, in: view)
        case "goBack":
            return await PageDriver.goBack(in: view)
        default:
            return "Unknown page action."
        }
    }
}
