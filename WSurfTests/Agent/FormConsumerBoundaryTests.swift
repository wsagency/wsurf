// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct FormConsumerBoundaryTests {
    private enum Consumer: CaseIterable, Sendable {
        case assistant
        case mcp
    }

    @Test(arguments: BrowserEngine.allCases)
    func assistantFillFieldsDispatchStaysWithinObservedSafeControls(engine: BrowserEngine) async throws {
        try await exercise(engine: engine, consumer: .assistant)
    }

    @Test(arguments: BrowserEngine.allCases)
    func mcpFillFieldsDispatchStaysWithinObservedSafeControls(engine: BrowserEngine) async throws {
        try await exercise(engine: engine, consumer: .mcp)
    }

    @Test(arguments: BrowserEngine.allCases, Consumer.allCases)
    private func closingTheOwnerDuringARealFillStopsTheRemainingFields(engine: BrowserEngine, consumer: Consumer) async throws {
        try await exercise(engine: engine, consumer: consumer, retireOwner: true)
    }

    private func exercise(engine: BrowserEngine, consumer: Consumer, retireOwner: Bool = false) async throws {
        let controls = (1...26).map { index in
            "<input aria-label=\"Safe \(index)\" data-safe value=\"\">"
        }.joined()
        let fixtureHTML = """
            <!doctype html><title>Fill consumer fixture</title>
            <script>
              window.formEvents = { input: 0, change: 0, submit: 0, fileClick: 0 };
              document.addEventListener('input', () => window.formEvents.input++, true);
              document.addEventListener('change', () => window.formEvents.change++, true);
              document.addEventListener('submit', () => window.formEvents.submit++, true);
            </script>
            <form onsubmit="window.formEvents.submit++; return false">
              \(controls)
              <select aria-label="Safe select"><option>Small</option><option>Large</option></select>
              <input aria-label="Safe date" type="date">
              <input aria-label="Sensitive password" type="password" value="keep-secret">
              <input aria-label="Unavailable disabled" disabled>
              <input aria-label="Unavailable read-only" readonly value="keep-readonly">
              <input aria-label="User file" type="file" onclick="window.formEvents.fileClick++">
            </form>
            """
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(fixtureHTML)])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        try await withOwnedPage(engine: engine, url: url) { browser, tab in
            tab.assistantAccess.persistsAnswers = false
            tab.assistantAccess.pageChanged(url: url)
            tab.assistantAccess.set(.control)
            var retiredValues: [[String]] = []
            if retireOwner {
                let page = tab.page
                page.addScriptMessageHandler(name: "retire-fill-owner", in: .page) { message in
                    guard let values = message.body as? [String] else { return }
                    retiredValues.append(values)
                    browser.close(tab)
                }
                _ = try await page.evaluateJavaScript("""
                    document.addEventListener('input', () => {
                      window.__wsurfSend('retire-fill-owner',
                        Array.from(document.querySelectorAll('[data-safe]'), field => field.value));
                    }, true); true
                    """, in: nil, contentWorld: .page)
            }

            let output: String
            let chooser = FileChooserProbe()
            switch consumer {
            case .assistant:
                var services = AgentToolkit.Services.live
                services.chooseFiles = { _ in
                    chooser.invocations += 1
                    return nil
                }
                let toolkit = AgentToolkit(
                    browser: browser,
                    media: MediaCenter(),
                    log: ConversationLog(database: .temporary()),
                    services: services
                )
                toolkit.beginTask(AgentTaskContext(id: UUID(), tabID: tab.id))
                let read = try await ReadPageTool(toolkit: toolkit).call(arguments: .init(
                    lookingFor: "", page: "", textOffset: nil, controlOffset: nil, scope: nil, viewportOnly: nil
                ))
                let observationID = try #require(read.components(separatedBy: "observationID: ").last?
                    .components(separatedBy: .newlines).first)
                try assertObservedRefs(observationID, in: tab.page)
                output = try await FillFieldsTool(toolkit: toolkit).call(arguments: .init(
                    page: nil, observationID: observationID, fields: fields()
                ))
                #expect(chooser.invocations == 0)
            case .mcp:
                let session = MCPBrowserSession(
                    browser: browser,
                    available: { true },
                    consent: { _, _ in .control }
                )
                defer { session.revoke() }
                _ = try await session.call(name: "requestAccess", arguments: [:])
                let read = try await session.call(name: "readPage", arguments: ["tabID": .string(tab.id.uuidString)])
                guard case .object(let readObject) = read.structuredContent else {
                    Issue.record("MCP readPage did not return structured observation data")
                    return
                }
                let observationID = try #require(readObject["observationID"]?.stringValue)
                try assertObservedRefs(observationID, in: tab.page)
                let action = try await session.call(name: "fillFields", arguments: [
                    "tabID": .string(tab.id.uuidString),
                    "observationID": .string(observationID),
                    "fields": .array(fields().map { field in
                        .object(["ref": .int(field.ref), "value": .string(field.value), "select": .bool(field.select)])
                    }),
                ])
                output = action.content.compactMap { block in
                    if case .text(let text, _, _) = block {
                        return text
                    }
                    return nil
                }.joined(separator: "\n")
            }
            if retireOwner {
                #expect(tab.isClosed && browser.tab(id: tab.id) == nil)
                #expect(retiredValues == [["value-1"] + Array(repeating: "", count: 25)])
                #expect(!output.contains("Verified refs:"))
                return
            }

            let verified = "Verified refs: " + (1...28).map { "[\($0)]" }.joined(separator: ", ") + "."
            #expect(output.contains("Filled 28 of 32 fields."), "\(output)")
            #expect(output.contains(verified), "\(output)")
            #expect(try await tab.page.evaluateJavaScript(
                "Array.from(document.querySelectorAll('[data-safe]')).every((el, i) => el.value === `value-${i + 1}`)"
            ) as? Bool == true)
            #expect(try await tab.page.evaluateJavaScript("document.querySelector('[aria-label=\"Safe select\"]').value") as? String == "Large")
            #expect(try await tab.page.evaluateJavaScript("document.querySelector('[aria-label=\"Safe date\"]').value") as? String == "2026-10-07")
            #expect(try await tab.page.evaluateJavaScript("document.querySelector('[type=password]').value") as? String == "keep-secret")
            #expect(try await tab.page.evaluateJavaScript("document.querySelector('[aria-label=\"Unavailable disabled\"]').value") as? String == "")
            #expect(try await tab.page.evaluateJavaScript("document.querySelector('[aria-label=\"Unavailable read-only\"]').value") as? String == "keep-readonly")
            #expect(try await tab.page.evaluateJavaScript("document.querySelector('[type=file]').files.length") as? Int == 0)
            #expect(try await tab.page.evaluateJavaScript("JSON.stringify(window.formEvents)") as? String == "{\"input\":28,\"change\":28,\"submit\":0,\"fileClick\":0}")
        }
    }

    private func assertObservedRefs(_ observationID: String, in page: BrowserPage) throws {
        let observation = try #require(PageDriver.observation(in: page))
        #expect(observation.id == observationID)
        #expect(observation.refs == Set(1...32))
    }

    private func withOwnedPage<T>(
        engine: BrowserEngine,
        url: URL,
        body: (BrowserModel, BrowserTab) async throws -> T
    ) async throws -> T {
        let profile = Profile(id: UUID(), name: "Form fixture", symbol: "person", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let permissions = SitePermissions(storageURL: nil)
        permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let browser = BrowserModel(
            context: context, windowID: UUID(), database: .temporary(), sitePermissions: permissions
        )
        let tab = browser.newTab(url: url)
        let page = tab.page
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFront(nil)

        func closeFixture() async {
            await page.close()
            window.contentView = nil
            window.close()
            browser.closeAllTabs(saving: false)
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        }

        do {
            try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading })
            #expect(tab.page.engine == engine)
            let result = try await body(browser, tab)
            await closeFixture()
            return result
        } catch {
            await closeFixture()
            throw error
        }
    }

    private func fields() -> [FillFieldsTool.Field] {
        (1...26).map { index in
            .init(ref: index, value: "value-\(index)", select: false)
        } + [
            .init(ref: 27, value: "Large", select: true),
            .init(ref: 28, value: "2026-10-07", select: false),
            .init(ref: 29, value: "overwrite-secret", select: false),
            .init(ref: 30, value: "disabled-value", select: false),
            .init(ref: 31, value: "readonly-value", select: false),
            .init(ref: 32, value: "/tmp/never-selected", select: false),
        ]
    }
}

@MainActor
private final class FileChooserProbe {
    var invocations = 0
}
