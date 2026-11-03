// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation
import Testing

@testable import WSurf

/// The Minimal bar's Hide bar choice: never, while the page scrolls, or once the bar has gone unused for a few seconds. The
/// model takes the choice and the times as inputs, so no case writes the app-wide setting or waits seconds.
@MainActor
@Suite(.serialized)
struct MinimalBarHidingTests {
    /// What a timed choice waits, in place of its seconds.
    private static let wait: Duration = .milliseconds(400)

    @MainActor
    @Observable
    final class Choice {
        var value: MinimalBarHiding

        init(_ value: MinimalBarHiding) {
            self.value = value
        }
    }

    private func makeReveal(_ choice: Choice, keeps: @escaping () -> Bool = { false }) -> MicroReveal {
        MicroReveal(
            hideDelay: .milliseconds(40), hostFlash: .milliseconds(80), restsRevealed: true,
            hiding: { choice.value }, idleDelay: { $0.interval.map { _ in Self.wait } }, keeps: keeps
        )
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        await waitUntil(timeout: .seconds(8), condition)
    }

    private func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    // MARK: - The model

    @Test func aTimedChoiceHidesTheBarOnceItHasGoneUnused() async {
        let reveal = makeReveal(Choice(.fiveSeconds))
        reveal.start()
        defer { reveal.stop() }

        #expect(reveal.isRevealed)
        await pause(.milliseconds(100))
        #expect(reveal.isRevealed, "not before its time")
        #expect(await eventually { !reveal.isRevealed }, "and then it goes, with no scrolling at all")
    }

    @Test func scrollingMeansNothingToATimedChoice() async {
        let reveal = makeReveal(Choice(.tenSeconds))
        reveal.start()
        defer { reveal.stop() }

        reveal.scrolled(towardTop: false)
        #expect(reveal.isRevealed, "scrolling down does not put the bar away")
        #expect(!reveal.isScrolledAway)
        #expect(await eventually { !reveal.isRevealed }, "its time does")

        reveal.scrolled(towardTop: true)
        #expect(!reveal.isRevealed, "and scrolling up does not bring it back")
    }

    @Test func whileScrollingNeverTimesOut() async {
        let reveal = makeReveal(Choice(.whileScrolling))
        reveal.start()
        defer { reveal.stop() }

        await pause(Self.wait * 2)
        #expect(reveal.isRevealed, "the same as before the choice existed: only the page puts the bar away")
        reveal.scrolled(towardTop: false)
        #expect(!reveal.isRevealed)
    }

    @Test func neverKeepsTheBarOverAScrolledPageAndForever() async {
        let reveal = makeReveal(Choice(.never))
        reveal.start()
        defer { reveal.stop() }

        reveal.scrolled(towardTop: false)
        await pause(Self.wait * 2)
        #expect(reveal.isRevealed)
    }

    @Test func thePointerAtTheEdgeWakesTheBarAndItRestsForItsWholeTimeAfter() async {
        let reveal = makeReveal(Choice(.fiveSeconds))
        reveal.start()
        defer { reveal.stop() }
        #expect(await eventually { !reveal.isRevealed })

        reveal.pointer(inZone: true)
        #expect(reveal.isRevealed)
        await pause(Self.wait * 2)
        #expect(reveal.isRevealed, "it stays while the pointer is on it")

        reveal.pointer(inZone: false)
        await pause(.milliseconds(120))
        #expect(reveal.isRevealed, "and it rests for its whole time once the pointer has left, not for a moment")
        #expect(await eventually { !reveal.isRevealed })
    }

    @Test func whatHoldsTheBarDelaysItsTimeUntilItLetsGo() async {
        var asking = true
        let reveal = makeReveal(Choice(.fiveSeconds), keeps: { asking })
        reveal.start()
        defer { reveal.stop() }

        await pause(Self.wait * 2)
        #expect(reveal.isRevealed, "a prompt, a save offer, the address being edited or an open tab list keep the bar")

        asking = false
        await pause(.milliseconds(120))
        #expect(reveal.isRevealed, "the time counts from when it let go")
        #expect(await eventually { !reveal.isRevealed })
    }

    @Test func anotherSiteWakesAnIdleBarAndItRestsAgain() async {
        let reveal = makeReveal(Choice(.fiveSeconds))
        reveal.start()
        defer { reveal.stop() }
        #expect(await eventually { !reveal.isRevealed })

        reveal.siteChanged()
        #expect(reveal.isRevealed)
        await pause(.milliseconds(250))
        #expect(reveal.isRevealed, "past the new site's moment, its bar rests for its time")
        #expect(await eventually { !reveal.isRevealed })
    }

    @Test func anotherChoiceStartsFromABarAtRest() async {
        let choice = Choice(.whileScrolling)
        let reveal = makeReveal(choice)
        reveal.start()
        defer { reveal.stop() }
        reveal.scrolled(towardTop: false)
        #expect(!reveal.isRevealed)

        choice.value = .never
        #expect(await eventually { reveal.isRevealed }, "the bar the page had put away is back")
        choice.value = .fiveSeconds
        #expect(await eventually { !reveal.isRevealed }, "and the new time counts")

        choice.value = .never
        #expect(await eventually { reveal.isRevealed }, "a bar that timed out is back too")
    }

    @Test func aRevealThatComesBackStartsItsCountAgain() async {
        let reveal = makeReveal(Choice(.fiveSeconds))
        reveal.start()
        #expect(await eventually { !reveal.isRevealed })
        reveal.stop()

        reveal.start()
        defer { reveal.stop() }
        #expect(reveal.isRevealed, "a stopped reveal does not keep a bar that timed out")
        #expect(await eventually { !reveal.isRevealed })
    }

    @Test func theMicroBarIgnoresTheChoice() async {
        let reveal = MicroReveal(hideDelay: .milliseconds(40), hostFlash: .milliseconds(80), hiding: { .never })
        reveal.start()
        defer { reveal.stop() }
        await pause(.milliseconds(120))
        #expect(!reveal.isRevealed, "it rests hidden whatever the Minimal window chose")
    }

    // MARK: - The setting

    @Test func theMinimalBarReadsTheAppWideChoiceLive() {
        let coordinator = AppCoordinator(browser: BrowserModel(context: BrowserProfileContext(profile: .privateBrowsing()), windowID: UUID()))
        let reveal = coordinator.makeMinimalReveal()

        #expect(reveal.restsRevealed)
        #expect(reveal.hiding() == BrowserSettings.application.minimalBarHiding)
    }

    @Test func theChoicesAreTheTimesTheMenuNames() {
        #expect(MinimalBarHiding.allCases == [.never, .whileScrolling, .fiveSeconds, .tenSeconds, .thirtySeconds])
        #expect(MinimalBarHiding.allCases.map(\.interval) == [nil, nil, .seconds(5), .seconds(10), .seconds(30)])
        #expect(Set(MinimalBarHiding.allCases.map { String(localized: $0.label) }).count == 5, "each has its own label")
    }
}
