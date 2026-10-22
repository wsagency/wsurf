// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// What the user is shown before a connection's reply goes into a page's prompt: all of the reply, none of it hidden, and the
/// page's message cut before the reply ever is.
@MainActor
struct PromptReplyConsentTests {
    @Test func spacesBreaksTabsAndInvisibleCharactersAreDrawn() {
        #expect(PageDialogText.visible("a b\nc\r\nd\te") == "a·b⏎c⏎⏎d⇥e")
        #expect(PageDialogText.visible("x\u{00A0}y\u{200B}z\u{FEFF}\u{7}") == "x·y‹U+200B›z‹U+FEFF›‹U+0007›")
        #expect(PageDialogText.visible("\u{3164}") == "‹U+3164›")
        #expect(PageDialogText.visible("plain text, ünïcode 日本") == "plain·text,·ünïcode·日本")
    }

    @Test func aCutIsMarkedAndAShortTextIsNotCut() {
        let long = String(repeating: "m", count: 1_000)
        let cut = PageDialogText.excerpt(long)
        #expect(cut.unicodeScalars.count == 301 && cut.hasSuffix("…"))
        #expect(PageDialogText.excerpt("short") == "short")
        #expect(PageDialogText.excerpt(String(repeating: "m", count: 300)).hasSuffix("…") == false)
    }

    @Test func theMessageIsCutBeforeTheReplyIsAndTheReplyIsWhole() {
        let message = String(repeating: "m", count: 1_000)
        let reply = String(repeating: "r", count: PageDialogText.maxReplyScalars)
        let text = AgentActionConsent.promptReplyText(reply: reply, to: message, consequence: nil)
        #expect(text.contains(reply), "the whole reply is shown")
        #expect(!text.contains(String(repeating: "m", count: 301)) && text.contains(String(repeating: "m", count: 300) + "…"))
    }

    @Test func paddingCannotPushTheEndOfAReplyOutOfSight() {
        let reply = "x" + String(repeating: " ", count: 250) + "\ny"
        let text = AgentActionConsent.promptReplyText(reply: reply, to: "Name?", consequence: nil)
        #expect(text.contains("x" + String(repeating: "·", count: 250) + "⏎y"))
        #expect(!text.contains("\ny”"), "the break inside the reply is a mark, not a line")
    }

    @Test func aConsequenceIsNamedInTheQuestion() {
        let text = AgentActionConsent.promptReplyText(reply: "DELETE", to: "Type DELETE to confirm", consequence: .deletion)
        #expect(text.contains(String(localized: SensitiveAction.Category.deletion.consequence)))
        #expect(!AgentActionConsent.promptReplyText(reply: "Alice", to: "Name?", consequence: nil).contains("can’t be undone"))
    }
}
