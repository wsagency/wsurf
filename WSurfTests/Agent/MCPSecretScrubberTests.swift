// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing

@testable import WSurf

/// The registry that hides typed test secrets: what it matches, what it refuses, and that it never prints or keeps a value.
@MainActor
struct MCPSecretScrubberTests {
    /// Every kind of character an encoder treats differently: quotes, angle brackets, an ampersand, a slash, a space, non-ASCII.
    private static let awkward = "Tr0ub4dor&3 \"x\"<y>/é"
    private static let hidden = MCPSecretScrubber.replacement

    private func json(_ text: String) throws -> String {
        let data = try JSONEncoder().encode(text)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    @Test func aSecretIsHiddenInEveryFormAnOutputCanTakeIt() throws {
        let scrubber = MCPSecretScrubber()
        #expect(scrubber.register(Self.awkward) == .registered)
        let secret = Self.awkward
        let forms: [String: String] = [
            "as typed": secret,
            "percent, strict": secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "",
            "encodeURIComponent": "Tr0ub4dor%263%20%22x%22%3Cy%3E%2F%C3%A9",
            "form body": "Tr0ub4dor%263+%22x%22%3Cy%3E%2F%C3%A9",
            "lower-case hex": "tr0ub4dor%263%20%22x%22%3cy%3e%2f%c3%a9",
            "json": try json(secret),
            "html, as the assistant wraps page text": AgentToolkit.untrusted(secret),
            "html entities": "Tr0ub4dor&amp;3 &quot;x&quot;&lt;y&gt;/é",
            "json of the wrapped page text": try json(AgentToolkit.untrusted("Welcome " + secret)),
        ]
        for (name, form) in forms {
            let output = scrubber.scrub("before " + form + " after")
            #expect(output.contains(Self.hidden), "\(name) was not recognised: \(output)")
            #expect(!output.contains("Tr0ub4dor"), "\(name) leaked: \(output)")
            #expect(!output.lowercased().contains("tr0ub4dor"), "\(name) leaked in another case: \(output)")
        }
        // The real wrapper, the real JSON text block: what the session actually hands to the transport.
        let value: Value = .object(["content": .string(AgentToolkit.untrusted("Welcome back, \(secret)!"))])
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let cleaned = scrubber.scrub(text)
        #expect(cleaned.contains(Self.hidden))
        #expect(!cleaned.contains("Tr0ub4dor"))
        #expect(!cleaned.contains("%C3%A9"))
    }

    @Test func matchingIgnoresAsciiCaseAndMergesNeighbours() {
        let scrubber = MCPSecretScrubber()
        scrubber.register("hunter2!")
        #expect(scrubber.scrub("HUNTER2!") == Self.hidden)
        #expect(scrubber.scrub("a Hunter2! b") == "a \(Self.hidden) b")
        // Touching matches become one replacement, and unrelated text is untouched.
        #expect(scrubber.scrub("hunter2!HUNTER2!") == Self.hidden)
        #expect(scrubber.scrub("hunter2! and hunter2!") == "\(Self.hidden) and \(Self.hidden)")
        #expect(scrubber.scrub("nothing to hide: [12] 8080") == "nothing to hide: [12] 8080")
        #expect(scrubber.scrub("") == "")
    }

    @Test func whitespaceCollapsedAndCutValuesAreSecretsToo() {
        let scrubber = MCPSecretScrubber()
        let secret = "alpha   beta gamma\tdelta epsilon zeta eta theta"
        scrubber.register(secret)
        // The page runtime collapses whitespace, and a control row cuts a value to its first 30 characters.
        let collapsed = "alpha beta gamma delta epsilon zeta eta theta"
        #expect(!scrubber.scrub("= \"\(collapsed)\"").contains("alpha"))
        let cut = String(collapsed.prefix(30))
        #expect(scrubber.scrub("[3] field \"Token\" = \"\(cut)\"") == "[3] field \"Token\" = \"\(Self.hidden)\"")
    }

    @Test func tooShortAndTooManySecretsAreRefused() {
        let scrubber = MCPSecretScrubber()
        #expect(scrubber.register("abc") == .tooShort)
        #expect(scrubber.register("é1") == .tooShort)
        #expect(scrubber.isEmpty)
        // "[12]" and ports must survive: a refused value hides nothing.
        #expect(scrubber.scrub("[12] abc") == "[12] abc")
        #expect(scrubber.register("abcd") == .registered)
        #expect(scrubber.register("ABCD") == .registered, "the same value in another case is the same secret")
        #expect(scrubber.count == 1)
        for index in 1..<MCPSecretScrubber.maximumSecrets {
            #expect(scrubber.register("secret-\(index)") == .registered)
        }
        #expect(scrubber.count == MCPSecretScrubber.maximumSecrets)
        #expect(scrubber.register("one-too-many") == .tooMany)
        #expect(scrubber.register("secret-1") == .registered, "a known secret is not new")
        #expect(scrubber.scrub("one-too-many") == "one-too-many")
    }

    @Test func wipingForgetsEverythingAndNothingPrintsAValue() {
        let scrubber = MCPSecretScrubber()
        scrubber.register("correct horse battery staple")
        #expect(scrubber.scrub("correct horse battery staple") == Self.hidden)

        var dumped = ""
        dump(scrubber, to: &dumped)
        for text in [scrubber.description, scrubber.debugDescription, "\(scrubber)", String(describing: scrubber), String(reflecting: scrubber), dumped] {
            #expect(!text.contains("horse"), "a description showed the secret: \(text)")
            #expect(text.contains("1"), "a description should still say how many: \(text)")
        }

        scrubber.wipe()
        #expect(scrubber.isEmpty)
        #expect(scrubber.count == 0)
        #expect(scrubber.wasUsed, "a wiped registry still knows it held secrets, so a late result is dropped")
        #expect(scrubber.scrub("correct horse battery staple") == "correct horse battery staple")
        #expect(scrubber.register("fresh secret") == .registered)
    }

    @Test func resultsAreScrubbedInTextAndStructuredContentButKeepTheirShape() {
        let scrubber = MCPSecretScrubber()
        scrubber.register("s3cr3t-value")
        let structured: Value = .object([
            "content": .string("echo s3cr3t-value"),
            "list": .array([.string("S3CR3T-VALUE"), .int(7), .bool(true), .null]),
            "s3cr3t-value": .string("key"),
        ])
        let result = CallTool.Result(
            content: [
                .text(text: "typed s3cr3t-value", annotations: nil, _meta: nil),
                .image(data: "s3cr3t-value-looks-like-base64", mimeType: "image/jpeg", annotations: nil, _meta: nil),
            ], structuredContent: Optional.some(structured), isError: true)
        let cleaned = scrubber.scrub(result)

        #expect(cleaned.isError == true)
        guard case .text(let text, _, _) = cleaned.content[0] else {
            Issue.record("the text block stays a text block")
            return
        }
        #expect(text == "typed \(Self.hidden)")
        guard case .image(let data, let type, _, _) = cleaned.content[1] else {
            Issue.record("the image stays an image")
            return
        }
        #expect(data == "s3cr3t-value-looks-like-base64", "pixels are covered at the source, not by text matching")
        #expect(type == "image/jpeg")
        let object = cleaned.structuredContent?.objectValue
        #expect(object?["content"]?.stringValue == "echo \(Self.hidden)")
        #expect(object?["list"]?.arrayValue?.first?.stringValue == Self.hidden)
        #expect(object?["list"]?.arrayValue?.count == 4)
        #expect(object?[Self.hidden]?.stringValue == "key", "object keys come from the page too")
        #expect(object?["s3cr3t-value"] == nil)

        // With nothing registered a result is returned as it was.
        #expect(MCPSecretScrubber().scrub(result) == result)
    }

    @Test func recordsTheUserReadsHideOnlyValuesConfirmedAsWrittenIntoASecretField() {
        let scrubber = MCPSecretScrubber()
        scrubber.register("Pay $500 to X")  // the agent chose to register a phrase
        scrubber.register("hunter2-real")  // a value that went into a password field
        scrubber.confirm("HUNTER2-REAL")
        scrubber.confirm("never registered")

        let record = "Pay $500 to X using hunter2-real"
        // What goes back to the agent hides everything registered.
        #expect(scrubber.scrub(record) == "\(Self.hidden) using \(Self.hidden)")
        // A record of what the agent did hides only the confirmed value, and says it did.
        #expect(scrubber.scrubForAudit(record) == "Pay $500 to X using \(MCPSecretScrubber.auditReplacement)")
        #expect(MCPSecretScrubber.auditReplacement != Self.hidden)
        // The phrase cannot be turned into a hidden value afterwards by confirming something else.
        #expect(scrubber.scrubForAudit("Pay $500 to X") == "Pay $500 to X")

        scrubber.wipe()
        #expect(scrubber.scrubForAudit(record) == record)
    }
}
