// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// What the Developer tier's opt-in detail may show of a request: which headers keep their values, which fields of a body are
/// hidden, how much of a body is kept, and when nothing is recorded at all. Pure: no page, no engine.
struct PageDiagnosticsDetailTests {
    private typealias Redaction = PageDiagnostics.Redaction
    private static let hidden = Redaction.hidden
    private static let tagged: @Sendable (String) -> PageDiagnostics.QueryValues = { _ in DiagnosticsTestKey.values }

    private func headers(
        _ pairs: [(String, String)], url: String? = nil, mode: (String) -> PageDiagnostics.QueryValues = PageDiagnosticsDetailTests.tagged
    ) -> [PageDiagnostics.Header] {
        Redaction.headers(pairs.map { (name: $0.0, value: $0.1) }, requestURL: url, mode: mode)
    }

    private func value(_ name: String, in list: [PageDiagnostics.Header]) -> String? {
        list.first { $0.name == name }?.value
    }

    // MARK: Headers

    @Test func credentialHeadersShowOnlyTheirNames() {
        let list = headers([
            ("Authorization", "Bearer abc.def.ghi"), ("Proxy-Authorization", "Basic dXNlcjpwYXNz"), ("Cookie", "sid=hunter2; theme=dark"),
            ("Set-Cookie", "sid=hunter2; HttpOnly"), ("X-API-Key", "k-1"), ("X-Auth-Token", "t-1"), ("X-CSRF-Token", "c-1"), ("X-Session-Id", "s-1"),
            ("X-Client-Secret", "s-2"), ("Content-Type", "application/json"), ("X-Trace", "trace-ok"),
        ])
        for name in ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-csrf-token", "x-session-id", "x-client-secret"] {
            #expect(value(name, in: list) == Self.hidden, "\(name) must show only its name")
        }
        #expect(value("content-type", in: list) == "application/json")
        #expect(value("x-trace", in: list) == "trace-ok")
        let text = Redaction.block(list).text
        for secret in ["abc.def.ghi", "dXNlcjpwYXNz", "hunter2", "k-1", "t-1", "c-1", "s-1", "s-2"] {
            #expect(!text.contains(secret), "\(secret) leaked into: \(text)")
        }
        #expect(text.contains("authorization: \(Self.hidden)"), "the name stays, with the marker")
    }

    @Test func aHeaderWhoseValueLooksGeneratedIsHiddenWhateverItIsCalled() {
        let list = headers([
            ("X-Build", "v1.2.3"), ("X-Request", DiagnosticsTestKey.secret), ("X-Info", "user=ann; ref=\(DiagnosticsTestKey.otherSecret)"),
            ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"),
            ("Content-Type", "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"), ("Accept", "*/*"),
        ])
        #expect(value("x-build", in: list) == "v1.2.3")
        #expect(value("x-request", in: list) == Self.hidden)
        #expect(value("x-info", in: list) == Self.hidden, "a token inside a longer value hides the value")
        #expect(value("user-agent", in: list)?.hasPrefix("Mozilla/5.0") == true, "a user agent is not a credential")
        #expect(value("content-type", in: list) == "multipart/form-data", "the boundary is not shown")
        #expect(value("accept", in: list) == "*/*")
    }

    @Test func headerListsAreNormalizedAndBounded() {
        let many = (0..<100).map { ("x-h\($0)", "v") }
        #expect(headers(many).count == Redaction.maxHeaders)
        let list = headers([(":path", "/a?token=1"), ("Accept", "a"), ("accept", "b"), ("bad name", "x"), ("X-Flat", "one\ntwo\tthree")])
        #expect(list.map(\.name) == ["accept", "x-flat"], "pseudo-headers and invalid names are dropped")
        #expect(value("accept", in: list) == "a, b", "duplicates are joined")
        #expect(value("x-flat", in: list) == "one two three")
        let long = headers([("X-Long", String(repeating: "a ", count: 400))])
        #expect((value("x-long", in: long) ?? "").utf8.count <= Redaction.maxHeaderValueBytes + 4)
        let all = headers((0..<64).map { ("x-header-\($0)", String(repeating: "v", count: 250)) })
        #expect(Redaction.block(all).text.utf8.count <= Redaction.maxHeaderBlockBytes)
        #expect(Redaction.block(all).truncated)
    }

    @Test func addressHeadersKeepTheirQueryOnlyAsTheModeAllows() {
        let url = "http://127.0.0.1:3000/app/page"
        let tagged = headers([("Referer", "http://127.0.0.1:3000/a?token=hunter2&q=hi"), ("Location", "/next?a=1")], url: url)
        #expect(value("referer", in: tagged) == "http://127.0.0.1:3000/a?token=*short&q=*short")
        #expect(value("location", in: tagged) == "http://127.0.0.1:3000/next?a=*short", "a relative address resolves against the request")
        let clear = headers([("Referer", "http://127.0.0.1:3000/a?token=hunter2")], url: url, mode: { _ in .clear })
        #expect(value("referer", in: clear) == "http://127.0.0.1:3000/a?token=hunter2")
        #expect(value("origin", in: headers([("Origin", "not a url")])) == Self.hidden, "an address that cannot be read is not shown")
    }

    // MARK: Bodies

    @Test func formFieldsNamedLikeCredentialsAreHidden() {
        let body = "user=ann&password=hunter2&pass=x&pwd=y&otp=123456&token=abc&secret=s&card=4111&card_number=4111&user%5Bpassword%5D=z&"
            + "Confirm+Password=p&passengers=3&note=hello+world&flag"
        let hidden = Self.hidden
        #expect(
            Redaction.hideForm(body)
                == "user=ann&password=\(hidden)&pass=\(hidden)&pwd=\(hidden)&otp=\(hidden)&token=\(hidden)&secret=\(hidden)&card=\(hidden)&"
                + "card_number=\(hidden)&user%5Bpassword%5D=\(hidden)&Confirm+Password=\(hidden)&passengers=3&note=hello+world&flag")
    }

    @Test func jsonKeysNamedLikeCredentialsAreHiddenAtAnyDepth() throws {
        let json = """
            {"user":"ann","password":"hunter2","profile":{"apiKey":"k","items":[{"token":"t","id":1},{"cardNumber":"4111"}],"pass":"x"},
             "passengers":3,"data":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig-nature","header":"Bearer abcdefghijkl","ok":true,"none":null}
            """
        let out = try #require(Redaction.hideJSON(json))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let hidden = Self.hidden
        #expect(object["user"] as? String == "ann" && object["passengers"] as? Int == 3 && object["ok"] as? Bool == true)
        #expect(object["password"] as? String == hidden)
        #expect(object["data"] as? String == hidden, "a JWT is hidden under any key")
        #expect(object["header"] as? String == hidden, "a bearer value is hidden under any key")
        let profile = try #require(object["profile"] as? [String: Any])
        #expect(profile["apiKey"] as? String == hidden && profile["pass"] as? String == hidden)
        let items = try #require(profile["items"] as? [[String: Any]])
        #expect(items[0]["token"] as? String == hidden && items[0]["id"] as? Int == 1 && items[1]["cardNumber"] as? String == hidden)
        for secret in ["hunter2", "4111", "abcdefghijkl", "sig-nature"] {
            #expect(!out.contains(secret), "\(secret) leaked: \(out)")
        }
    }

    @Test func textAndXmlBodiesHideCredentialPairs() {
        let hidden = Self.hidden
        let text = Redaction.hideText("name=ann\npassword: hunter2\nAuthorization: Bearer abc def\nnote: ok & \"token\": \"t0k\", 'secret'='s'")
        #expect(text == "name=ann\npassword: \(hidden)\nAuthorization: \(hidden)\nnote: ok & \"token\": \(hidden), 'secret'=\(hidden)")
        let xml = Redaction.hideText("<user id=\"1\" token=\"abc\"><password>hunter2</password><name>ann</name><card_number>4111</card_number></user>")
        #expect(xml == "<user id=\"1\" token=\(hidden)><password>\(hidden)</password><name>ann</name><card_number>\(hidden)</card_number></user>")
        // A JSON body cut at the intake limit is not valid JSON; its pairs are still hidden.
        #expect(Redaction.hideCredentials("{\"a\":1,\"password\":\"hunter2\",\"b\":\"cut", kind: .json) == "{\"a\":1,\"password\":\(hidden),\"b\":\"cut")
    }

    @Test(arguments: [
        "password", "Password", "user[password]", "new_password", "confirmPassword", "pass", "user_pass", "pwd", "otp", "OTP", "token", "accessToken",
        "refresh_token", "id_token", "secret", "clientSecret", "card", "card_number", "cvv", "apiKey", "api-key", "X-Api-Key", "authorization",
        "session", "session_id", "csrfmiddlewaretoken", "_csrf", "passcode",
    ])
    func credentialNamesAreHidden(name: String) {
        #expect(Redaction.isHiddenKey(name))
    }

    @Test(arguments: [
        "passengers", "username", "email", "notes", "cardinal", "discard", "author", "pinned", "description", "id", "key", "code", "bypass",
        "compass", "name", "title", "items",
    ])
    func ordinaryNamesAreShown(name: String) {
        #expect(!Redaction.isHiddenKey(name))
    }

    // MARK: Limits

    @Test func aBodyIsCutToItsLimitAndSaysSo() throws {
        var budget = Redaction.captureBodyBytes
        let raw = PageDiagnostics.RawBody(text: String(repeating: "a", count: 100_000), contentType: "text/plain", size: 100_000)
        let result = Redaction.body(raw, side: "response", budget: &budget, scrub: { $0 })
        guard case .text(let kept)? = result.fields["responseBody"] else {
            Issue.record("no body")
            return
        }
        #expect(kept.utf8.count == Redaction.maxBodyBytes)
        #expect(result.fields["responseBodyBytes"] == 100_000)
        #expect(result.fields["responseBodyNote"] == .text("truncated: the first 32768 of 100000 bytes"))
        #expect(result.truncated)
        #expect(budget == Redaction.captureBodyBytes - Redaction.maxBodyBytes)
    }

    @Test func aCaptureKeepsAtMostItsBodyBudget() {
        var budget = Redaction.captureBodyBytes
        var kept = 0
        var refused = 0
        for _ in 0..<80 {
            let raw = PageDiagnostics.RawBody(text: String(repeating: "b", count: Redaction.maxBodyBytes), contentType: "application/json")
            let result = Redaction.body(raw, side: "request", budget: &budget, scrub: { $0 })
            if case .text(let text)? = result.fields["requestBody"] {
                kept += text.utf8.count
            } else {
                refused += 1
                #expect(result.fields["requestBodyNote"]?.description.contains("used up") == true)
            }
        }
        #expect(kept <= Redaction.captureBodyBytes)
        #expect(kept == 64 * Redaction.maxBodyBytes, "the 2 MiB budget holds 64 full bodies")
        #expect(refused == 16)
        #expect(budget == 0)
        var small = 10
        let last = Redaction.body(.init(text: String(repeating: "c", count: 50), contentType: "text/plain"), side: "request", budget: &small, scrub: { $0 })
        #expect(last.fields["requestBody"] == .text(String(repeating: "c", count: 10)), "what is left of the budget is the limit")
        #expect(small == 0)
    }

    @Test func binaryAndNonTextBodiesAreSummarizedNotShown() {
        var budget = Redaction.captureBodyBytes
        let image = Redaction.body(.init(contentType: "image/png", size: 1_234, binary: true), side: "response", budget: &budget, scrub: { $0 })
        #expect(image.fields["responseBody"] == nil)
        #expect(image.fields["responseBodyNote"] == .text("not captured: image/png body, 1234 bytes"))
        let multipart = Redaction.body(
            .init(text: "--b\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\nhunter2\r\n--b--", contentType: "multipart/form-data; boundary=b", size: 70),
            side: "request", budget: &budget, scrub: { $0 })
        #expect(multipart.fields["requestBody"] == nil, "a multipart body is summarized, never shown")
        #expect(multipart.fields["requestBodyNote"] == .text("not captured: multipart/form-data body, 70 bytes"))
        let stream = Redaction.body(.init(text: "x", contentType: "application/octet-stream"), side: "response", budget: &budget, scrub: { $0 })
        #expect(stream.fields["responseBody"] == nil)
        #expect(budget == Redaction.captureBodyBytes, "a summary uses none of the budget")
    }

    @Test func aSecretThatStraddlesTheCutLeavesNoFragment() {
        let scrubber = MCPSecretScrubber()
        let secret = "Zx9-test-Pa$$word!"
        scrubber.register(secret)
        var budget = Redaction.captureBodyBytes
        // The secret starts a few characters before the 32 KiB limit, so the cut would fall inside it.
        let text = String(repeating: "a", count: Redaction.maxBodyBytes - 6) + secret + " tail"
        let result = Redaction.body(.init(text: text, contentType: "text/plain"), side: "request", budget: &budget, scrub: scrubber.scrub)
        guard case .text(let kept)? = result.fields["requestBody"] else {
            Issue.record("no body")
            return
        }
        #expect(kept.contains("‹"), "the secret was replaced before the text was cut: …\(kept.suffix(30))")
        for fragment in ["Zx9", "Pa$$", "word!", "test-"] {
            #expect(!kept.contains(fragment), "a fragment of the secret is left: \(fragment)")
        }
    }

    @Test func registeredSecretsAreScrubbedFromHeadersAndBodiesTogether() {
        let scrubber = MCPSecretScrubber()
        let secret = "Zx9-test-Pa$$word!"
        scrubber.register(secret)
        var budget = Redaction.captureBodyBytes
        let input = PageDiagnostics.DetailInput(
            url: "http://127.0.0.1:1/",
            requestHeaders: headers([("X-Note", "typed \(secret)")]),
            responseHeaders: nil,
            requestBody: .init(text: "{\"note\":\"\(secret)\",\"n\":1}", contentType: "application/json"),
            responseBody: .init(text: "echo \(secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")", contentType: "text/plain"))
        let result = PageDiagnostics.detailFields(
            input, options: .init(headers: true, bodies: true), budget: &budget, scrub: scrubber.scrub)
        let everything = result.fields.values.map(\.description).joined(separator: "\n")
        #expect(!everything.contains(secret) && !everything.contains("Pa%24%24"), "\(everything)")
        #expect(everything.contains(MCPSecretScrubber.replacement))
    }

    /// A page chooses the text a body is made of. None of these may take more than a moment to hide: patterns that backtrack
    /// without bound turn 64 KiB of this into minutes on the main thread.
    @Test(.timeLimit(.minutes(1)), arguments: [
        String(repeating: "a", count: 100_000), String(repeating: "<a ", count: 30_000), String(repeating: "<a>x", count: 30_000),
        String(repeating: "=", count: 100_000), String(repeating: "k=v ", count: 30_000), String(repeating: "a.", count: 40_000),
        String(repeating: "password=\"", count: 8_000), String(repeating: "a: ", count: 30_000),
    ])
    func hostileBodiesAreHiddenInBoundedTime(text: String) {
        let start = ContinuousClock.now
        for type in ["text/plain", "application/xml", "application/json", "application/x-www-form-urlencoded"] {
            var budget = Redaction.captureBodyBytes
            _ = Redaction.body(.init(text: text, contentType: type, size: text.utf8.count), side: "response", budget: &budget, scrub: { $0 })
        }
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func detailFieldsFollowTheOptions() {
        var budget = Redaction.captureBodyBytes
        let input = PageDiagnostics.DetailInput(
            url: "http://127.0.0.1:1/", requestHeaders: headers([("A", "b")]), responseHeaders: headers([("C", "d")]),
            requestBody: .init(text: "x", contentType: "text/plain"), responseBody: .init(text: "y", contentType: "text/plain"))
        let onlyHeaders = PageDiagnostics.detailFields(input, options: .init(headers: true), budget: &budget, scrub: { $0 }).fields
        #expect(Set(onlyHeaders.keys) == ["requestHeaders", "responseHeaders"])
        let onlyBodies = PageDiagnostics.detailFields(input, options: .init(bodies: true), budget: &budget, scrub: { $0 }).fields
        #expect(Set(onlyBodies.keys) == ["requestBody", "responseBody"])
        #expect(PageDiagnostics.detailFields(input, options: .init(), budget: &budget, scrub: { $0 }).fields.isEmpty)
    }

    // MARK: Policy

    private func policy(
        tier: Bool = true, headers: Bool = true, bodies: Bool = true, clear: Bool = false, console: Bool = false
    ) -> PageDiagnostics.DetailPolicy {
        PageDiagnostics.DetailPolicy(
            options: .init(headers: headers, bodies: bodies, console: console, clearQueries: clear), tier: tier, anyPortHosts: ["127.0.0.1"],
            isDeveloperSite: { MCPDeveloperAccess.matches($0, sites: ["staging.test:8443"], includesThisMac: true) })
    }

    @Test func detailCoversOnlyDeveloperSitesWhileTheTierHolds() {
        let on = policy()
        #expect(on.network("http://127.0.0.1:3000/api"))
        #expect(on.network("http://localhost:5173/x"))
        #expect(on.network("https://staging.test:8443/x"))
        #expect(!on.network("https://staging.test/x"), "another port is another site")
        #expect(!on.network("https://example.com/x"))
        #expect(!on.network("http://127.0.0.2/x"))
        #expect(!on.network("not a url") && !on.network(nil))
        #expect(!policy(tier: false).network("http://127.0.0.1:3000/api"), "no tier, no detail")
        #expect(!policy(headers: false, bodies: false).network("http://127.0.0.1:3000/api"), "no opt-in, no detail")
        #expect(!PageDiagnostics.DetailPolicy.off.network("http://127.0.0.1:3000/api"))
    }

    @Test func queryValuesAreClearOnlyForDeveloperSitesThatAskedForIt() throws {
        let asked = policy(clear: true)
        guard case .clear = asked.queryValues(for: "http://127.0.0.1:3000/a?x=1", tagged: DiagnosticsTestKey.values) else {
            Issue.record("not clear")
            return
        }
        guard case .tagged = asked.queryValues(for: "https://example.com/a?x=1", tagged: DiagnosticsTestKey.values) else {
            Issue.record("third party must stay tagged")
            return
        }
        guard case .tagged = policy().queryValues(for: "http://127.0.0.1:3000/a?x=1", tagged: DiagnosticsTestKey.values) else {
            Issue.record("not asked")
            return
        }
        guard case .tagged = policy(tier: false, clear: true).queryValues(for: "http://127.0.0.1:3000/a?x=1", tagged: DiagnosticsTestKey.values) else {
            Issue.record("no tier")
            return
        }
    }

    // MARK: Previews

    @Test func previewsAreBoundedAndHideCredentialKeys() throws {
        let deep: [String: Any] = ["a": ["b": ["c": ["d": 1]]], "password": "hunter2", "list": Array(0..<100), "text": String(repeating: "x", count: 5_000)]
        let preview = try #require(Redaction.preview([deep, "plain", 3]))
        #expect(preview.text.utf8.count <= Redaction.maxPreviewBytes)
        #expect(!preview.text.contains("hunter2") && preview.text.contains(Self.hidden))
        let shallow = try #require(Redaction.preview([["a": ["b": ["c": ["d": 1]]]]]))
        #expect(shallow.text == "[{\"a\":{\"b\":{\"c\":\"[object]\"}}}]", "containers deeper than 3 levels are replaced")
        let fromPage = Redaction.preview(json: "[{\"token\":\"t0k\",\"ok\":1}]")
        #expect(fromPage.text == "[{\"ok\":1,\"token\":\"\(Self.hidden)\"}]")
        let cut = Redaction.preview(json: "[{\"password\":\"hunter2\",\"x\":\"" + String(repeating: "y", count: 3_000))
        #expect(cut.text.utf8.count <= Redaction.maxPreviewBytes && cut.truncated)
        #expect(!cut.text.contains("hunter2"), "a preview cut by the page still hides its credentials")
    }
}

private extension PageDiagnostics.Field {
    var description: String {
        switch self {
        case .text(let text):
            text
        case .number(let number):
            String(number)
        }
    }
}
