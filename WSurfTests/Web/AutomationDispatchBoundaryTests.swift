// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct AutomationDispatchBoundaryTests {
    @Test(arguments: BrowserEngine.allCases)
    func revocationOnFirstRealWritePreventsNextEngineDispatch(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <input aria-label="First">
                <input aria-label="Second">
                """),
        ])
        defer { withExtendedLifetime(server) {} }

        let context = BrowserProfileContext(profile: .privateBrowsing())
        let view: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration),
                context: context
            )
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            view = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer {
            Task {
                await view.close()
                window.contentView = nil
                window.close()
            }
        }

        let access = DispatchBoundaryAccess()
        view.addScriptMessageHandler(name: "dispatch-boundary", in: PageAutomationGuard.world) { message in
            guard message.body as? String == "revoke" else { return }
            access.isLive = false
        }
        view.installScript("""
            document.addEventListener('input', event => {
              if (event.target?.getAttribute('aria-label') === 'First') {
                window.__wsurfSend('dispatch-boundary', 'revoke');
              }
            }, true);
            """, in: PageAutomationGuard.world, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let url = try server.url("/")
        view.load(URLRequest(url: url))
        try #require(await waitUntil { view.url == url && !view.isLoading })

        let observation = await PageDriver.readRenderedPage(view)
        let first = try #require(ref("First", in: observation))
        let second = try #require(ref("Second", in: observation))
        let observed = try #require(PageDriver.observation(in: view))
        let scope = PageAutomationGuard(
            documentURL: observed.url,
            snapshot: observed.id,
            validate: { access.isLive }
        )
        let filling = Task {
            await PageAutomationGuard.$current.withValue(scope) {
                await PageDriver.fillFields([
                    .init(ref: first, value: "written once", select: false),
                    .init(ref: second, value: "must not be written", select: false),
                ], in: view)
            }
        }
        #expect(await waitUntil { !access.isLive })
        _ = await filling.value
        #expect(!access.isLive)
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('input')[0].value") as? String == "written once")
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('input')[1].value") as? String == "")
    }

    private func ref(_ label: String, in observation: String) -> Int? {
        observation.components(separatedBy: "\n").first { $0.contains("field \"\(label)\"") }
            .flatMap { line in
                guard let end = line.firstIndex(of: "]") else { return nil }
                return Int(line[line.index(after: line.startIndex)..<end])
            }
    }
}

@MainActor
private final class DispatchBoundaryAccess {
    var isLive = true
}
