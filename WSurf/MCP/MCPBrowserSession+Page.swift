// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import CoreGraphics
import Foundation
import MCP

/// Reading and acting on a shared page.
@MainActor
extension MCPBrowserSession {
    func usePage(
        _ entry: MCPToolCatalog.Entry, arguments: [String: Value], tab: BrowserTab, capability: Scope,
        previewRead: PageAutomationGuard? = nil
    ) async -> CallTool.Result {
        let name = entry.name
        if previewRead == nil {
            tab.setExternalAutomationWorking(true)
            tab.realizeDeferredSession()
        }
        defer { if previewRead == nil { tab.setExternalAutomationWorking(false) } }
        if let previewRead, !previewRead.validate() || !tab.isMaterialised {
            return failure("The page is not ready. Try again.", code: .pageUnavailable)
        }
        let view = tab.page
        // The view and generation this call started on. The guard below refuses to continue once either changes.
        let generation = tab.pageGeneration
        guard tab.isLive(view, generation: generation) else { return failure("The page is not ready. Try again.", code: .pageUnavailable) }
        guard let url = webURL(of: tab) else { return failure("The webpage is unavailable.", code: .pageUnavailable) }
        if capability == .control, let refusal = await sensitivePageRefusal(tab, view: view, url: url) {
            return refusal
        }
        var targeted = arguments
        if let refusal = await prepareTargets(entry, arguments: &targeted, tab: tab, view: view, generation: generation, url: url) {
            return refusal
        }
        let arguments = targeted
        // Explicit `secret: true` is refused immediately if password/secret entry is disallowed.
        let explicitSecretEntry = Self.secretEntry(tool: name, arguments: arguments)
        if let explicitSecretEntry, !allowsPasswordEntry(for: tab) {
            return secretEntryRefusal(explicitSecretEntry, tab: tab) ?? failure("Password and secret entry is not allowed.", code: .accessDenied)
        }
        if let refusal = fullInspectionRefusal(name, arguments: arguments, tab: tab) {
            return refusal
        }
        // What only the Developer tier may read: a full inspection, a selector that reads attribute values.
        let readsAsDeveloper = (name == "inspectElement" && arguments["full"]?.boolValue == true) || (name == "findElements" && permits(tab, capability: .developer))
        // A click, hover or scroll at x and y names no control, so it needs no observation.
        let atPoint = Self.point(arguments) != nil && arguments["ref"] == nil
        let usesRef = (entry.usesRef && !atPoint) || arguments["ref"] != nil || arguments["toRef"] != nil
        let observation = observations[tab.id]
        if usesRef {
            // A ref stays valid for as long as its document does, so the observation ID is optional. One that is sent must
            // still be the latest.
            guard let observation, arguments["observationID"]?.stringValue.map({ $0 == observation.id }) ?? true,
                observation.documentURL == url.absoluteString
            else { return failure("The observation is stale. Use readPage again.", code: .stale) }
        }
        // Under Control (when password entry is allowed) or Developer tier, writes into password/OTP/card fields are
        // automatically treated as secret entries: registered in MCPSecretScrubber before typing, autofill suppressed,
        // and value hidden from every result — without requiring `secret: true`.
        var autoSensitiveRefs: Set<Int> = []
        if allowsPasswordEntry(for: tab), name == "typeOnPage" || name == "fillFields" {
            let probeRefs: [Int]
            if name == "typeOnPage" {
                probeRefs = arguments["ref"]?.intValue.map { [$0] } ?? []
            } else {
                probeRefs = arguments["fields"]?.arrayValue?.compactMap { $0.objectValue?["ref"]?.intValue } ?? []
            }
            if !probeRefs.isEmpty {
                let probeScope = PageAutomationGuard(
                    documentURL: url.absoluteString, snapshot: observation?.snapshot,
                    validate: { [weak self, weak tab, weak view] in
                        guard let self, let tab, let view, tab.isLive(view, generation: generation) else { return false }
                        return self.mayProceed(tab, capability: capability)
                    })
                autoSensitiveRefs = await PageAutomationGuard.$current.withValue(probeScope) {
                    await PageDriver.sensitiveSecretRefs(probeRefs, in: view)
                }
                guard mayProceed(tab, capability: capability), tab.isLive(view, generation: generation), webURL(of: tab) == url else {
                    return failure("Page access changed. Read the page again.", code: .accessDenied)
                }
            }
        }
        let secretEntry = Self.secretEntry(tool: name, arguments: arguments, autoSensitiveRefs: autoSensitiveRefs)
        if let secretEntry, let refusal = secretEntryRefusal(secretEntry, tab: tab) {
            return refusal
        }
        let typesSecret = secretEntry != nil
        let scope = previewRead ?? PageAutomationGuard(
            documentURL: url.absoluteString, snapshot: usesRef ? observation?.snapshot : nil,
            validate: { [weak self, weak tab, weak view] in
                guard let self, let tab, let view, tab.isLive(view, generation: generation) else { return false }
                return self.mayProceed(tab, capability: capability)
                    && (!typesSecret || self.allowsPasswordEntry(for: tab))
                    && (!readsAsDeveloper || self.mayProceed(tab, capability: .developer))
                    && (capability != .control || self.isReachable(tab))
            }
        )
        // What a finished action may report: the page may have left the screen (a popup took its place) without the
        // connection losing the right to read it.
        let reading = previewRead ?? PageAutomationGuard(
            documentURL: url.absoluteString, snapshot: nil,
            validate: { [weak self, weak tab, weak view] in
                guard let self, let tab, let view, tab.isLive(view, generation: generation) else { return false }
                return self.mayProceed(tab, capability: .read)
            }
        )
        let tainted = tab.isMCPCredentialTainted
        return await PageAutomationGuard.$current.withValue(scope) {
            guard scope.validate(), webURL(of: tab) == url else { return failure("Page access changed. Read the page again.", code: .accessDenied) }
            // The ring still shows on a page the person sees, but an MCP action does not wait for it.
            return await PageDriver.$announceDuration.withValue(.zero) {
                await PageDriver.$protectedCredentials.withValue(tainted) {
                    await PageDriver.$accumulatesRefs.withValue(true) {
                        await PageDriver.$expectedObservation.withValue(usesRef ? observation?.snapshot : nil) {
                            await pageReply(
                                name: name, arguments: arguments, tab: tab, view: view, scope: scope, reading: reading,
                                observation: observation, secret: secretEntry)
                        }
                    }
                }
            }
        }
    }

    /// The reply for a page tool whose guard and expected observation are already in place.
    private func pageReply(
        name: String, arguments: [String: Value], tab: BrowserTab, view: BrowserPage, scope: PageAutomationGuard,
        reading: PageAutomationGuard, observation: PageObservation?, secret: SecretEntry?
    ) async -> CallTool.Result {
        if Self.feedbackActions.contains(name), arguments["result"]?.stringValue != "full",
            let reply = await deltaAction(
                name: name, arguments: arguments, tab: tab, view: view, scope: scope, reading: reading, observation: observation,
                secret: secret) {
            return reply
        }
        var capturedImage: Data?
        var failureCode: MCPFailureCode?
        let output: String
        if name == "screenshotPage" {
            (output, capturedImage, failureCode) = await screenshotOutput(arguments: arguments, tab: tab, view: view)
        } else {
            // `result: full` keeps the old grace for a navigation to start; only the longest wait follows the budget.
            let limits = PageSettle.limits(
                settle: arguments["settle"]?.stringValue, grace: PageSettle.navigationGrace,
                quietCeiling: .milliseconds(FeedbackBudget(arguments["budget"]).settleMs))
            // A dialog the action opens blocks the page, so the action cannot return until it is answered.
            let acted = await PageSettle.$limits.withValue(limits) {
                await interrupting(tab) { await self.performAction(name: name, arguments: arguments, tab: tab, view: view, secret: secret) }
            }
            guard let acted else {
                observations[tab.id] = nil
                return interruptedResult(tab)
            }
            output = acted
            if name == "waitForPage", output.hasPrefix("Timed out waiting for ") {
                failureCode = .timeout
            }
        }
        guard scope.validate(), !Task.isCancelled else {
            observations[tab.id] = nil
            return failure("Page access changed before the operation finished. Its contents were not returned.", code: .accessDenied)
        }
        if output == PageDriver.filledSecretRefusal {
            return failure(output, code: .protectedSecretPresent)
        }
        let succeeded = Self.succeeded(name, output)
        if !succeeded, name != "screenshotPage" {
            capturedImage = await failureImage(
                arguments["screenshotOnFailure"]?.stringValue, ref: arguments["ref"]?.intValue, tab: tab, view: view, scope: scope)
        }
        var content: [String: Value] = ["tabID": .string(tab.id.uuidString), "content": .string(AgentToolkit.untrusted(output))]
        if !succeeded { content["code"] = (failureCode ?? .actionFailed).value }
        if !PageDriver.refusesFilledSecrets, succeeded, name == "readPage" || name == "inspectControl", let currentURL = webURL(of: tab),
            let hint = await vaultHint(for: tab, view: view, url: currentURL) {
            guard scope.validate(), !Task.isCancelled else {
                observations[tab.id] = nil
                return failure("Page access changed before the operation finished. Its contents were not returned.", code: .accessDenied)
            }
            content["vaultHint"] = hint
        }
        var delivered: PageObservation?
        if let current = PageDriver.observation(in: view), current.url == webURL(of: tab)?.absoluteString,
            output.contains("observationID: " + current.id) {
            delivered = PageObservation(id: current.id, snapshot: current.id, documentURL: current.url)
            content["observationID"] = .string(current.id)
            if PageOutputBudget.cost(current.url) <= 512 { content["url"] = .string(current.url) }
        }
        let value: Value = .object(content)
        var blocks: [MCP.Tool.Content] = [.text(text: encoded(value), annotations: nil, _meta: nil)]
        if let capturedImage {
            blocks.append(.image(data: capturedImage.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
        }
        let result = CallTool.Result(content: blocks, structuredContent: Optional.some(value), isError: !succeeded)
        // A refused reply grants nothing: the client never saw its observation ID or links.
        if capturedImage != nil, Self.replyBytes(result) > MCPMessageFramer.maximumBytes {
            observations[tab.id] = nil
            return failure("The screenshot is too large to return. Use readPage for redacted text.")
        }
        // A reply that carries no new observation leaves the client with the one it has, while the page still has it.
        if delivered == nil, let observation, PageDriver.observation(in: view)?.id == observation.id {
            observations[tab.id] = observation
        } else {
            observations[tab.id] = delivered
        }
        hasReadContent = true
        destinations.formUnion(PageDriver.listedLinks(in: output).map { destinationKey($0.url) })
        return result
    }

    /// `screenshotPage`: the text a client reads and the image, when there is one.
    private func screenshotOutput(
        arguments: [String: Value], tab: BrowserTab, view: BrowserPage
    ) async -> (String, Data?, MCPFailureCode?) {
        let request = Self.screenshotTarget(arguments)
        if let message = request.error {
            return (message, nil, .invalidInput)
        }
        if request.target == .fullPage, !mayProceed(tab, capability: .development) {
            return ("A full-page screenshot needs development access.", nil, .accessDenied)
        }
        // A control ref needs read access; a non-control inspection ref needs current development access, asked
        // again inside the driver before work, after each await and before pixels are returned.
        let developmentAllowed = { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return self.mayProceed(tab, capability: .development)
        }
        // A client that holds a current observation of this page gets the image alone unless it asks for the text too.
        let holdsObservation = observations[tab.id].map { PageDriver.observation(in: view)?.id == $0.id } ?? false
        let includeSnapshot = arguments["includeSnapshot"]?.boolValue ?? !holdsObservation
        await throttleCapture()
        let outcome = await PageDriver.screenshot(
            request.target, developmentAllowed: developmentAllowed, maximumBytes: Self.screenshotBytes,
            maxWidth: arguments["maxWidth"]?.intValue,
            // The Developer tier types its own test secrets, so its screenshots cover filled sensitive fields; anywhere else a
            // filled sensitive field still prevents the capture.
            masking: screenshotMasking(for: tab), in: view)
        switch outcome {
        case .success(let capture):
            let box = capture.bounds
            let shows = request.target == .fullPage ? "the full page, CSS pixels" : "viewport CSS pixels"
            let text =
                "Screenshot captured. Shows \(shows) x \(Int(box.minX.rounded())), y \(Int(box.minY.rounded())), "
                + "\(Int(box.width.rounded())) by \(Int(box.height.rounded())); image scale \(String(format: "%.2f", capture.scale)) px per CSS px."
                + (includeSnapshot
                    ? "\n" + (await PageDriver.snapshot(view, viewportOnly: true))
                    // The image alone still names the observation the client holds, which stays current.
                    : holdsObservation ? PageDriver.observation(in: view).map { "\nobservationID: " + $0.id } ?? "" : "")
            // The snapshot above was the last await: development access is asked once more right before the
            // image is attached, so a revoke during it never returns an inspection image.
            if capture.requiresDevelopment, !developmentAllowed() {
                return (ScreenshotFailure.needsDevelopment.message, nil, .accessDenied)
            }
            return (text, capture.jpeg, nil)
        case .failure(let failure):
            let code: MCPFailureCode = switch failure {
            case .privacy:
                .protectedSecretPresent
            case .uninspectableFrame:
                .unsupported
            case .stale:
                .stale
            case .invalidGeometry:
                .invalidInput
            case .needsDevelopment:
                .accessDenied
            case .fullPageUnsupported:
                .unsupported
            case .offscreen, .captureFailed, .unmappableFrame:
                .actionFailed
            }
            return (failure.message, nil, code)
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
        if arguments["fullPage"]?.boolValue == true {
            if ref != nil || arguments["region"] != nil { return (.viewport, "Use fullPage alone, not with ref or region.") }
            return (.fullPage, nil)
        }
        if case .object(let box)? = arguments["region"] {
            if ref != nil { return (.viewport, "Use either ref or region, not both.") }
            return (.region(CGRect(x: number(box, "x"), y: number(box, "y"), width: number(box, "width"), height: number(box, "height"))), nil)
        }
        return (ref.map { .element(ref: $0) } ?? .viewport, nil)
    }

    /// `pageAction`, and after a secret entry what must follow it: the fields remembered, and autofill and the vault kept away.
    func performAction(name: String, arguments: [String: Value], tab: BrowserTab, view: BrowserPage, secret: SecretEntry?) async -> String {
        let output = await pageAction(name: name, arguments: arguments, view: view, secret: secret, developer: permits(tab, capability: .developer))
        if let secret {
            finishSecretEntry(secret, tab: tab, view: view)
        }
        return output
    }

    private func pageAction(name: String, arguments: [String: Value], view: BrowserPage, secret: SecretEntry?, developer: Bool) async -> String {
        let ref = arguments["ref"]?.intValue ?? 0
        if let pointer = await pointerAction(name: name, arguments: arguments, ref: ref, view: view) {
            return pointer
        }
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
            return await PageDriver.pressKey(arguments["key"]?.stringValue ?? "", ref: ref, modifiers: arguments["modifiers"]?.stringValue ?? "", in: view)
        case "dragOnPage":
            return await dragAction(arguments: arguments, view: view)
        case "fillFields":
            let fields =
                arguments["fields"]?.arrayValue?.compactMap { value -> PageDriver.FieldValue? in
                    guard case .object(let field) = value, let ref = field["ref"]?.intValue,
                        let value = field["value"]?.stringValue, let select = field["select"]?.boolValue
                    else { return nil }
                    return .init(ref: ref, value: value, select: select)
                } ?? []
            return await PageDriver.fillFields(
                fields, secretRefs: secret?.refs ?? [], secretWritten: secretWriteSink, submitRef: arguments["submitRef"]?.intValue,
                submit: arguments["submit"]?.boolValue ?? false, in: view, announced: true)
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
                limit: arguments["limit"]?.intValue ?? MCPDevelopmentTools.defaultLimit, unrestricted: developer, in: view)
        case "inspectElement":
            return await PageDriver.inspectElement(
                ref: ref, full: developer && arguments["full"]?.boolValue == true,
                properties: Self.computedPropertyNames(arguments["properties"]?.stringValue) ?? [], in: view)
        case "readAccessibility":
            return await PageDriver.readAccessibility(offset: arguments["offset"]?.intValue ?? 0, scope: arguments["scope"]?.stringValue ?? "", in: view)
        case "readPerformance":
            return await PageDriver.readPerformance(in: view)
        case "goBack":
            return await PageDriver.goBack(in: view)
        default:
            return "Unknown page action."
        }
    }

    /// Trusted pointer input for a click, hover or scroll that asks for it (a point, `pointer`, another button...), and every
    /// Chromium hover; nil for the tool's ordinary path.
    private func pointerAction(name: String, arguments: [String: Value], ref: Int, view: BrowserPage) async -> String? {
        let point = Self.point(arguments)
        switch name {
        case "clickOnPage":
            switch Self.pointerClick(arguments) {
            case .success(let click)?:
                return await PageDriver.pointerClick(
                    ref: ref > 0 ? ref : nil, point: point, button: click.button, clickCount: click.count, modifiers: click.modifiers, in: view)
            case .failure(let refusal)?:
                return refusal.message
            case nil:
                return nil
            }
        case "scrollPage":
            guard let point else { return nil }
            return await PageDriver.scroll(direction: arguments["direction"]?.stringValue ?? "", at: point, in: view)
        case "hoverOnPage":
            if view.chromium != nil {
                return await PageDriver.pointerHover(ref: ref > 0 ? ref : nil, point: point, in: view)
            }
            if view.isParked {
                return PageDriver.backgroundWebKitPointer
            }
            // A visible WebKit tab hovers with the real pointer, which needs a control to aim at.
            return point == nil ? nil : "Hover at x and y needs a Chromium tab (setTabEngine). On WebKit, hover a ref; WSurf must be the active app."
        default:
            return nil
        }
    }

    /// The refusal for a full inspection outside the Developer tier, or for a malformed `properties`; nil when the call may go on.
    private func fullInspectionRefusal(_ name: String, arguments: [String: Value], tab: BrowserTab) -> CallTool.Result? {
        guard name == "inspectElement" else { return nil }
        let full = arguments["full"]?.boolValue == true
        if full, !permits(tab, capability: .developer) {
            return failure("A full inspection needs Developer access: a paired app, a developer site, and a window of the Developer profile. Nothing was read.", code: .accessDenied)
        }
        if arguments["properties"] != nil {
            guard full else { return failure("properties belongs to a full inspection. Set full to true.", code: .invalidInput) }
            guard Self.computedPropertyNames(arguments["properties"]?.stringValue) != nil else {
                return failure("properties is up to \(Self.maximumComputedProperties) comma-separated CSS property names of letters, digits and dashes.", code: .invalidInput)
            }
        }
        return nil
    }

    nonisolated static let maximumComputedProperties = 32

    /// The computed property names in a comma-separated list, or nil when the list is not a valid one. Empty text names none, which
    /// means all.
    nonisolated static func computedPropertyNames(_ list: String?) -> [String]? {
        guard let list, !list.allSatisfy(\.isWhitespace) else { return [] }
        let names = list.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count <= maximumComputedProperties,
            names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
        else { return nil }
        return names
    }
}
