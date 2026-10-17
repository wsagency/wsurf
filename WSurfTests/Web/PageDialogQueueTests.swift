// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Who answers a page's dialog: a connection that controls the tab, or the user.
@MainActor
struct PageDialogQueueTests {
    private typealias Answer = PageDialogQueue.Answer
    private let connection = UUID()
    private let other = UUID()

    /// Stands in for the native sheet: it records that it was shown and stays open until the test closes it.
    @MainActor
    private final class Sheet {
        private(set) var shown = 0
        private var continuation: CheckedContinuation<PageDialogQueue.Answer, Never>?
        private var closedWith: PageDialogQueue.Answer?

        func show() async -> PageDialogQueue.Answer {
            shown += 1
            if let closedWith {
                return closedWith
            }
            return await withCheckedContinuation { continuation = $0 }
        }

        func close(accepted: Bool = true, text: String? = nil) {
            let answer = Answer(accepted: accepted, text: text)
            closedWith = answer
            continuation?.resume(returning: answer)
            continuation = nil
        }
    }

    private func request(
        _ kind: PageDialogQueue.Kind = .confirm, _ message: String = "Keep going?", defaultText: String? = nil
    ) -> PageDialogQueue.Request {
        .init(kind: kind, message: message, origin: "http://127.0.0.1:8080", defaultText: defaultText)
    }

    private func held(
        _ queue: PageDialogQueue, _ request: PageDialogQueue.Request, sheet: Sheet
    ) -> Task<PageDialogQueue.Answer?, Never> {
        Task { await queue.run(request) { await sheet.show() } }
    }

    private func claimed(isAuthorized: @escaping () -> Bool = { true }) -> (PageDialogQueue, PageDialogQueue.Claim) {
        let queue = PageDialogQueue()
        return (queue, queue.claim(connection: connection, isAuthorized: isAuthorized))
    }

    // MARK: Routing

    @Test func aTabNobodyControlsTakesTheNativeSheetAtOnce() async {
        let queue = PageDialogQueue()
        let sheet = Sheet()
        sheet.close(accepted: false)
        #expect(!queue.isIntercepting)
        let answer = await queue.run(request()) { await sheet.show() }
        #expect(answer == Answer(accepted: false))
        #expect(sheet.shown == 1)
        #expect(!queue.hasOpenDialog)
    }

    @Test func aClaimHoldsTheDialogUntilItsConnectionAnswers() async throws {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        let running = held(queue, request(.prompt, "Your name?", defaultText: "Anon"), sheet: sheet)
        #expect(await waitUntil { queue.pending(for: connection).count == 1 })
        let summary = try #require(queue.pending(for: connection).first)
        #expect(summary.kind == .prompt && summary.message == "Your name?" && summary.defaultText == "Anon")
        #expect(summary.origin == "http://127.0.0.1:8080" && !summary.userMustAnswer)
        #expect(queue.pending(for: other).isEmpty, "another connection does not see it")
        #expect(!queue.answer(summary.id, connection: other, with: Answer(accepted: true)))
        #expect(queue.answer(summary.id, connection: connection, with: Answer(accepted: true, text: "Alice")))
        #expect(await running.value == Answer(accepted: true, text: "Alice"))
        #expect(sheet.shown == 0, "the user never saw a sheet")
        #expect(!queue.hasOpenDialog)
        #expect(!queue.answer(summary.id, connection: connection, with: Answer(accepted: true)), "a dialog is answered once")
    }

    @Test func aPromptAcceptedWithoutTextGetsThePagesDefaultAndOtherKindsGetNone() async throws {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        let prompt = held(queue, request(.prompt, "Name?", defaultText: "Anon"), sheet: sheet)
        #expect(await waitUntil { queue.pending(for: connection).count == 1 })
        #expect(queue.answer(try #require(queue.pending(for: connection).first).id, connection: connection, with: Answer(accepted: true)))
        #expect(await prompt.value == Answer(accepted: true, text: "Anon"))
        let confirm = held(queue, request(), sheet: sheet)
        #expect(await waitUntil { queue.pending(for: connection).count == 1 })
        #expect(queue.answer(try #require(queue.pending(for: connection).first).id, connection: connection, with: Answer(accepted: true, text: "x")))
        #expect(await confirm.value == Answer(accepted: true, text: nil))
    }

    @Test func aConnectionThatLostItsAuthorizationDoesNotReceiveDialogs() async {
        var authorized = true
        let (queue, claim) = claimed(isAuthorized: { authorized })
        defer { claim.end() }
        authorized = false
        let sheet = Sheet()
        sheet.close()
        #expect(!queue.isIntercepting)
        _ = await queue.run(request()) { await sheet.show() }
        #expect(sheet.shown == 1)
    }

    @Test func aLeaseHoldsAlertsForItsConnectionBetweenCalls() async throws {
        let queue = PageDialogQueue()
        queue.leaseHolder = { connection }
        #expect(queue.isIntercepting)
        let sheet = Sheet()
        let running = held(queue, request(.alert, "Saved"), sheet: sheet)
        #expect(await waitUntil { queue.pending(for: connection).count == 1 })
        #expect(queue.answer(try #require(queue.pending(for: connection).first).id, connection: connection, with: Answer(accepted: true)))
        #expect(await running.value != nil)
        #expect(sheet.shown == 0)
    }

    // MARK: The user keeps the dialogs a connection must not answer

    @Test(arguments: [
        "Enter your password", "Verification code?", "Your PIN", "One-time passcode", "Card number", "Enter the CVV", "2FA token",
        "Security code", "Type your secret",
    ])
    func aPromptThatAsksForASecretIsNeverHeldForAConnection(message: String) async throws {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        let running = held(queue, request(.prompt, message), sheet: sheet)
        #expect(await waitUntil { sheet.shown == 1 }, "the native sheet is up at once")
        let summary = try #require(queue.pending(for: connection).first)
        #expect(summary.userMustAnswer, "the connection can see that it is waiting but not answer it")
        #expect(!queue.answer(summary.id, connection: connection, with: Answer(accepted: true, text: "hunter2")))
        sheet.close(accepted: true, text: "typed by the user")
        #expect(await running.value == Answer(accepted: true, text: "typed by the user"))
        #expect(!queue.hasOpenDialog)
    }

    @Test(arguments: ["What is your name?", "Shipping address?", "Tell us your favourite colour", "Search for"])
    func anOrdinaryPromptIsHeldForTheConnection(message: String) async throws {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        let running = held(queue, request(.prompt, message), sheet: sheet)
        #expect(await waitUntil { queue.pending(for: connection).count == 1 })
        let summary = try #require(queue.pending(for: connection).first)
        #expect(!summary.userMustAnswer && sheet.shown == 0)
        #expect(queue.answer(summary.id, connection: connection, with: Answer(accepted: false)))
        #expect(await running.value == Answer(accepted: false))
    }

    @Test func aSecretPromptDoesNotShowTheValueThePagePrefilled() async throws {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        let running = held(queue, request(.prompt, "Enter your password", defaultText: "hunter2"), sheet: sheet)
        #expect(await waitUntil { sheet.shown == 1 })
        let summary = try #require(queue.pending(for: connection).first)
        #expect(summary.defaultText == nil)
        sheet.close(accepted: false)
        _ = await running.value
    }

    @Test func aLeaseAloneNeverTakesABeforeUnloadAndTheUserSeesItAtOnce() async throws {
        let queue = PageDialogQueue()
        queue.leaseHolder = { connection }
        let sheet = Sheet()
        let running = held(queue, request(.beforeUnload, ""), sheet: sheet)
        #expect(await waitUntil { sheet.shown == 1 })
        #expect(try #require(queue.pending(for: connection).first).userMustAnswer)
        sheet.close()
        _ = await running.value
    }

    @Test func stayingOnAPageIsLimitedSoAConnectionCannotKeepTheUserThere() async throws {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        for _ in 0..<PageDialogQueue.maxAgentStays {
            let running = held(queue, request(.beforeUnload, ""), sheet: sheet)
            #expect(await waitUntil { queue.pending(for: connection).count == 1 })
            #expect(queue.answer(try #require(queue.pending(for: connection).first).id, connection: connection, with: Answer(accepted: false)))
            #expect(await running.value == Answer(accepted: false))
        }
        #expect(sheet.shown == 0)
        let user = held(queue, request(.beforeUnload, ""), sheet: sheet)
        #expect(await waitUntil { sheet.shown == 1 }, "after the limit the next one is the user's")
        #expect(try #require(queue.pending(for: connection).first).userMustAnswer)
        sheet.close(accepted: true)
        #expect(await user.value == Answer(accepted: true))
        // A document that commits starts the count again, and leaving never counts.
        queue.documentCommitted()
        let again = held(queue, request(.beforeUnload, ""), sheet: Sheet())
        #expect(await waitUntil { queue.pending(for: connection).first?.userMustAnswer == false })
        #expect(queue.answer(try #require(queue.pending(for: connection).first).id, connection: connection, with: Answer(accepted: true)))
        #expect(await again.value == Answer(accepted: true))
    }

    @Test func aClaimOutlivesItsCallForAMoment() async {
        let (queue, claim) = claimed()
        let clock = TestClock()
        queue.clock = clock
        claim.endSoon()
        #expect(queue.isIntercepting, "a navigation's beforeunload comes after the call that started it")
        #expect(await waitUntil { clock.pendingCount == 1 })
        clock.advance(by: .seconds(1))
        await Task.yield()
        #expect(queue.isIntercepting)
        clock.advance(by: .seconds(2))
        #expect(await waitUntil { !queue.isIntercepting })
    }

    // MARK: Falling back to the user

    @Test func anUnansweredDialogGoesToTheUserAfterTheTimeout() async throws {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let clock = TestClock()
        queue.clock = clock
        let sheet = Sheet()
        let running = held(queue, request(), sheet: sheet)
        #expect(await waitUntil { clock.pendingCount == 1 })
        clock.advance(by: .seconds(59))
        await Task.yield()
        #expect(sheet.shown == 0)
        clock.advance(by: .seconds(2))
        #expect(await waitUntil { sheet.shown == 1 })
        let summary = try #require(queue.pending(for: connection).first)
        #expect(summary.userMustAnswer)
        #expect(!queue.answer(summary.id, connection: connection, with: Answer(accepted: true)), "late answers cannot answer for the user")
        sheet.close(accepted: false)
        #expect(await running.value == Answer(accepted: false))
        #expect(!queue.hasOpenDialog)
    }

    @Test func aConnectionThatEndsHandsItsDialogsToTheUser() async throws {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        let mine = held(queue, request(), sheet: sheet)
        #expect(await waitUntil { queue.pending(for: connection).count == 1 })
        queue.handBack(connection: other)
        #expect(sheet.shown == 0, "another connection ending changes nothing")
        queue.handBack(connection: connection)
        #expect(await waitUntil { sheet.shown == 1 })
        sheet.close()
        #expect(await mine.value != nil)
    }

    @Test func aPageThatGoesAwayNeedsNoAnswerAndShowsNoSheet() async {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        let running = held(queue, request(), sheet: sheet)
        #expect(await waitUntil { queue.hasOpenDialog })
        queue.cancelAll()
        #expect(await running.value == nil)
        #expect(sheet.shown == 0)
        #expect(!queue.hasOpenDialog)
    }

    @Test func dialogsBeyondTheLimitGoStraightToTheUser() async {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        let running = (0..<PageDialogQueue.maxOpen).map { _ in held(queue, request(), sheet: sheet) }
        #expect(await waitUntil { queue.pending(for: connection).count == PageDialogQueue.maxOpen })
        let overflow = held(queue, request(), sheet: sheet)
        #expect(await waitUntil { sheet.shown == 1 })
        sheet.close()
        _ = await overflow.value
        queue.cancelAll()
        for task in running {
            _ = await task.value
        }
    }

    // MARK: Work a dialog blocks

    @Test func aWaitEndsWhenADialogOpensAndAnsweringWaitsForTheBlockedWork() async {
        let (queue, claim) = claimed()
        defer { claim.end() }
        let sheet = Sheet()
        var finished = false
        let blocked = Task { () -> Bool in
            _ = await queue.run(request(.alert, "Saved")) { await sheet.show() }
            finished = true
            return true
        }
        let outcome = await queue.race(blocked)
        guard case .dialog? = outcome else {
            Issue.record("expected the dialog to end the wait, got \(String(describing: outcome))")
            return
        }
        #expect(!finished, "the work is still blocked behind the dialog")
        queue.park(blocked)
        let id = queue.pending(for: connection).first?.id ?? ""
        #expect(queue.answer(id, connection: connection, with: Answer(accepted: true)))
        await queue.settleParked()
        #expect(finished, "answering returns once the work the dialog blocked has finished")
        #expect(sheet.shown == 0)
    }

    @Test func workThatFinishesBeforeAnyDialogIsReturned() async {
        let queue = PageDialogQueue()
        let outcome = await queue.race(Task { 42 })
        guard case .finished(let value)? = outcome else {
            Issue.record("expected the work to finish, got \(String(describing: outcome))")
            return
        }
        #expect(value == 42)
    }

    // MARK: What a connection may read

    @Test func dialogTextIsBoundedCleanedAndFlagged() {
        let flood = String(repeating: "a", count: 5_000)
        let (cut, truncated) = PageDialogText.forAgent(flood)
        #expect(cut.unicodeScalars.count == PageDialogText.maxScalars && truncated)
        let (short, shortTruncated) = PageDialogText.forAgent("Are you sure?\nTab\there\u{7}bell")
        #expect(short == "Are you sure?\nTab here bell" && !shortTruncated)
    }

    @Test func linksInDialogTextLoseCredentialsQueriesAndFragments() {
        let text = "Open https://user:pw@example.com:8443/a/b?token=abc#frag. Then http://localhost:3000/x?y=1, or mailto://x@y?z=1)."
        let cleaned = PageDialogText.forAgent(text).text
        #expect(cleaned == "Open https://example.com:8443/a/b. Then http://localhost:3000/x, or mailto:).")
        for secret in ["pw", "token", "abc", "frag", "y=1"] {
            #expect(!cleaned.contains(secret), "\(secret)")
        }
    }

    @Test func anOriginIsSchemeHostAndPortOnly() {
        #expect(PageDialogText.origin(ofURL: "http://127.0.0.1:50000/path?x=1#y") == "http://127.0.0.1:50000")
        #expect(PageDialogText.origin(ofURL: "https://Example.COM/") == "https://example.com")
        #expect(PageDialogText.origin(scheme: "https", host: "::1", port: 8443) == "https://[::1]:8443")
        #expect(PageDialogText.origin(scheme: "https", host: "", port: 0) == "")
        #expect(PageDialogText.origin(ofURL: "not a url") == "")
    }
}
