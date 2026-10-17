// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What the page driver does with a test secret on each engine: typing it into a sensitive field without focusing the field,
/// refusing it everywhere else, and covering sensitive fields in a screenshot. The MCP session decides who may ask for any of
/// this; these tests drive the driver directly.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageSecretEntryTests {
    private static let password = "Zx9-driver-Pa$$word!"

    private static let loginPage = """
        <!doctype html><title>Login</title>
        <style>
          input { display: block; width: 240px; height: 32px; border: 0; padding: 0; margin: 0 0 8px 0; }
          #pw { background: #f00; color: #fff; }
          #plain { width: 240px; height: 32px; background: #00f; }
        </style>
        <input id=user aria-label="Username">
        <input id=pw type=password aria-label="Password">
        <input id=otp autocomplete="one-time-code" aria-label="Verification code">
        <div id=plain></div>
        """

    private func withPage(engine: BrowserEngine, html: String, body: (BrowserPage) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(html)])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let view: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration), context: context)
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            view = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        do {
            view.load(URLRequest(url: url))
            try #require(await waitUntil { view.url == url && !view.isLoading })
            try await body(view)
        } catch {
            await view.close()
            await context.endPrivateSession()
            throw error
        }
        await view.close()
        await context.endPrivateSession()
    }

    private func refs(in view: BrowserPage) async throws -> [Int] {
        _ = await PageDriver.readRenderedPage(view)
        return try #require(PageDriver.observation(in: view)?.refs.sorted())
    }

    private func value(_ id: String, in view: BrowserPage) async throws -> String {
        try await view.evaluateJavaScript("document.getElementById('\(id)').value") as? String ?? "<none>"
    }

    @Test func aTypedSecretIsRetainedWhenTheSubmitLeavesThePage() {
        let fallback = PageDriver.typeFallback(submit: true)
        #expect(fallback["retained"] as? Bool == true, "the page was left after Enter, which is pressed only for a retained value")
        #expect(fallback["ok"] as? Bool == true && fallback["submitted"] as? Bool == true)
        #expect(PageDriver.typeFallback(submit: false)["submitted"] as? Bool == false)
    }

    @Test(arguments: BrowserEngine.allCases)
    func aSecretSubmitThatNavigatesAwayIsReportedAsSubmitted(engine: BrowserEngine) async throws {
        let page = """
            <!doctype html><title>Login</title>
            <form onsubmit="event.preventDefault(); location.replace('/?signed-in')">
              <input id=pw type=password aria-label="Password">
            </form>
            """
        try await withPage(engine: engine, html: page) { view in
            let password = try #require(try await refs(in: view).first)
            let typed = await PageDriver.type(
                text: Self.password, intoField: "", ref: password, submit: true, allowSensitive: true, in: view)
            #expect(typed.hasPrefix("Typed a secret into"), "engine \(engine): \(typed)")
            #expect(typed.contains("requested submission") && !typed.contains("did not retain"), "engine \(engine): \(typed)")
            #expect(!typed.contains(Self.password))
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aSecretIsTypedWithoutFocusingTheFieldAndTheReplyNeverRepeatsIt(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.loginPage) { view in
            let refs = try await refs(in: view)
            try #require(refs.count == 3)
            let password = refs[1]

            let refused = await PageDriver.type(text: Self.password, intoField: "", ref: password, submit: false, in: view)
            #expect(refused.contains("The user has to fill it themselves"), "engine \(engine): \(refused)")
            #expect(try await value("pw", in: view) == "")

            var writes: [PageDriver.SecretWrite] = []
            let typed = await PageDriver.type(
                text: Self.password, intoField: "", ref: password, submit: false, allowSensitive: true, secretWritten: { writes.append($0) }, in: view)
            #expect(typed.hasPrefix("Typed a secret into"), "engine \(engine): \(typed)")
            #expect(!typed.contains(Self.password), "engine \(engine)")
            #expect(typed.contains("(filled, hidden)"))
            #expect(try await value("pw", in: view) == Self.password)
            #expect(writes.count == 1, "engine \(engine)")
            #expect(writes.first?.stored == Self.password, "the page kept exactly what was typed")
            #expect(writes.first?.isSensitiveField == true && writes.first?.retained == true, "a password field, written")
            // The field was never focused, so autofill has no field to offer the vault's accounts for.
            #expect(try await view.evaluateJavaScript("document.activeElement === document.body") as? Bool == true, "engine \(engine)")

            // A secret typed into a field that is not a password, code or card field says so, so the user's own records can tell.
            var plain: [PageDriver.SecretWrite] = []
            _ = await PageDriver.type(
                text: "Pay $500 to X", intoField: "", ref: refs[0], submit: false, allowSensitive: true, secretWritten: { plain.append($0) }, in: view)
            #expect(plain.count == 1 && plain.first?.isSensitiveField == false, "engine \(engine): an ordinary field is not a secret field")
            #expect(try await value("user", in: view) == "Pay $500 to X")

            // An ordinary field is focused as before.
            let user = await PageDriver.type(text: "alice", intoField: "", ref: refs[0], submit: false, in: view)
            #expect(user.hasPrefix("Typed into"), "engine \(engine): \(user)")
            #expect(try await view.evaluateJavaScript("document.activeElement.id") as? String == "user", "engine \(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aFormOfTheSecretThePageStoresIsReportedToTheCaller(engine: BrowserEngine) async throws {
        let card = """
            <!doctype html><title>Card</title>
            <input id=card aria-label="Card number" autocomplete="cc-number">
            <script>
              const card = document.getElementById('card');
              card.addEventListener('input', () => {
                card.value = card.value.replace(/\\D/g, '').replace(/(.{4})/g, '$1 ').trim();
              });
            </script>
            """
        try await withPage(engine: engine, html: card) { view in
            let refs = try await refs(in: view)
            var writes: [PageDriver.SecretWrite] = []
            let typed = await PageDriver.type(
                text: "4242424242424242", intoField: "", ref: try #require(refs.first), submit: false, allowSensitive: true,
                secretWritten: { writes.append($0) }, in: view)

            #expect(writes.map(\.stored) == ["4242 4242 4242 4242"], "engine \(engine): \(writes)")
            #expect(writes.first?.isSensitiveField == true && writes.first?.retained == false)
            #expect(typed.contains("did not retain"), "engine \(engine): \(typed)")
            #expect(!typed.contains("4242"))
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func fillFieldsTypesOnlyTheFlaggedSecretsIntoSensitiveFields(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.loginPage) { view in
            let refs = try await refs(in: view)
            try #require(refs.count == 3)
            let fields: [PageDriver.FieldValue] = [
                .init(ref: refs[0], value: "alice", select: false),
                .init(ref: refs[1], value: Self.password, select: false),
                .init(ref: refs[2], value: "482916", select: false),
            ]

            let result = await PageDriver.fillFields(fields, secretRefs: [refs[1]], in: view)

            #expect(result.hasPrefix("Filled 2 of 3"), "engine \(engine): \(result)")
            #expect(result.contains("sensitive field"), "the unflagged code field is still refused")
            #expect(!result.contains(Self.password))
            #expect(try await value("user", in: view) == "alice")
            #expect(try await value("pw", in: view) == Self.password)
            #expect(try await value("otp", in: view) == "")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aSecretIsNeverTypedIntoAFrame(engine: BrowserEngine) async throws {
        let framed = """
            <!doctype html><title>Framed</title>
            <iframe id=f srcdoc="<input id=inner type=password aria-label='Inner password'>" style="width:300px;height:60px"></iframe>
            """
        try await withPage(engine: engine, html: framed) { view in
            try #require(await waitUntil { (try? await view.evaluateJavaScript("!!document.getElementById('f').contentDocument?.getElementById('inner')")) as? Bool == true })
            let refs = try await refs(in: view)
            let typed = await PageDriver.type(
                text: Self.password, intoField: "", ref: try #require(refs.first), submit: false, allowSensitive: true, in: view)

            #expect(typed.contains("not into a frame"), "engine \(engine): \(typed)")
            let inner = try await view.evaluateJavaScript("document.getElementById('f').contentDocument.getElementById('inner').value")
            #expect(inner as? String == "")
        }
    }

    // MARK: Screenshots

    private func color(of capture: ScreenshotCapture, at point: CGPoint) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let bitmap = try #require(NSBitmapImageRep(data: capture.jpeg))
        let x = min(bitmap.pixelsWide - 1, Int((point.x - capture.bounds.minX) * capture.scale))
        let y = min(bitmap.pixelsHigh - 1, Int((point.y - capture.bounds.minY) * capture.scale))
        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    private func center(_ id: String, in view: BrowserPage) async throws -> CGPoint {
        let box = try #require(
            try await view.evaluateJavaScript(
                "(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()")
                as? [Double])
        return CGPoint(x: box[0], y: box[1])
    }

    @Test(arguments: BrowserEngine.allCases)
    func aScreenshotCoversFilledSensitiveFieldsOnlyWhenAskedTo(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.loginPage) { view in
            let refs = try await refs(in: view)
            _ = await PageDriver.type(text: Self.password, intoField: "", ref: refs[1], submit: false, allowSensitive: true, in: view)
            try #require(await waitUntil { (try? await view.evaluateJavaScript("window.innerWidth")) as? Int == 500 })

            // Anywhere else a filled sensitive field prevents the capture, as before.
            guard case .failure(let failure) = await PageDriver.screenshot(.viewport, in: view) else {
                Issue.record("engine \(engine): a filled password field must refuse an ordinary capture")
                return
            }
            #expect(failure == .privacy)

            guard case .success(let capture) = await PageDriver.screenshot(.viewport, masking: ScreenshotMasking(), in: view) else {
                Issue.record("engine \(engine): a masked capture must succeed")
                return
            }
            let password = try color(of: capture, at: try await center("pw", in: view))
            let plain = try color(of: capture, at: try await center("plain", in: view))
            #expect(password.red < 0.15 && password.green < 0.15 && password.blue < 0.15, "engine \(engine): the field is black, not red: \(password)")
            #expect(plain.blue > 0.6 && plain.red < 0.3 && plain.green < 0.3, "engine \(engine): the rest of the page is untouched: \(plain)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aFilledFieldInsideAFrameIsCoveredByTheWholeFrame(engine: BrowserEngine) async throws {
        // The field's own position inside the frame is not mapped back to the page, so the frame is what is blacked out.
        let framed = """
            <!doctype html><title>Framed</title>
            <style>body { margin: 0 } iframe { display: block; border: 0; width: 300px; height: 60px; background: #f00 }</style>
            <iframe id=f srcdoc="<style>body{margin:0;background:red}</style><input id=inner type=password aria-label='Inner password' value='filled-by-the-user'>"></iframe>
            <div id=plain style="width:100px;height:40px;background:#00f"></div>
            """
        try await withPage(engine: engine, html: framed) { view in
            try #require(await waitUntil { (try? await view.evaluateJavaScript("!!document.getElementById('f').contentDocument?.getElementById('inner')")) as? Bool == true })
            guard case .success(let capture) = await PageDriver.screenshot(.viewport, masking: ScreenshotMasking(), in: view) else {
                Issue.record("engine \(engine): a field inside a frame is covered by the frame")
                return
            }
            let frame = try color(of: capture, at: try await center("f", in: view))
            #expect(frame.red < 0.15 && frame.green < 0.15 && frame.blue < 0.15, "engine \(engine): the whole frame is black: \(frame)")
            let plain = try color(of: capture, at: try await center("plain", in: view))
            #expect(plain.blue > 0.6, "engine \(engine): \(plain)")
        }
    }
}
