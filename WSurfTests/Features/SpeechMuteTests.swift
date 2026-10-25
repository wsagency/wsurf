// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// A voice that says nothing and keeps what it was asked, and what the person's mute did to it.
@MainActor
private final class RecordingVoice: SpeechOutput {
    var isMuted = false
    var onSpeakingChange: ((Bool) -> Void)?
    private(set) var spoken: [String] = []
    private(set) var stops = 0

    func speak(_ text: String) {
        guard !isMuted else { return }
        spoken.append(text)
    }

    func stopSpeaking() {
        stops += 1
    }
}

/// Mute WSurf reaches the voices: the assistant's, which is silent while WSurf is muted whatever the person's own setting says
/// and is theirs again afterwards, a conversation by voice, and Read Aloud, which pauses and goes on from where it was.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct SpeechMuteTests {
    private func withApplication(_ body: @MainActor (BrowserApplication, AppCoordinator) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Speech mute")
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let main = app.newWindow(profile: profile, show: false)
        var failure: (any Error)?
        do {
            try await body(app, main)
        } catch {
            failure = error
        }
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    // MARK: - The assistant's voice

    @Test func theAssistantsVoiceIsSilentWhileSilencedWhateverTheSettingSaysAndSpeaksAgainAfter() {
        let inner = RecordingVoice()
        let voice = ProviderSpeechOutput(output: inner)

        voice.speak("heard")
        voice.isSilenced = true
        #expect(inner.isMuted, "silenced: the voice under it is muted")
        #expect(inner.stops >= 1, "what it was saying stops")
        voice.speak("not heard")
        #expect(inner.spoken == ["heard"], "and what it is asked to say meanwhile is dropped, not kept for later")

        voice.isSilenced = false
        #expect(!inner.isMuted)
        voice.speak("heard again")
        #expect(inner.spoken == ["heard", "heard again"])
    }

    @Test func thePersonsOwnMuteIsTheirsAndNeitherMutingNorUnmutingWSurfChangesIt() {
        let inner = RecordingVoice()
        let voice = ProviderSpeechOutput(output: inner)

        voice.isMuted = true
        voice.isSilenced = true
        voice.isSilenced = false
        #expect(voice.isMuted && inner.isMuted, "unmuting WSurf does not unmute a voice the person muted")
        voice.speak("still silent")
        #expect(inner.spoken.isEmpty)

        voice.isSilenced = true
        voice.isMuted = false
        #expect(inner.isMuted, "the person unmuting the voice while WSurf is muted does not unmute WSurf")
        voice.speak("silent for WSurf")
        #expect(inner.spoken.isEmpty)

        voice.isSilenced = false
        voice.speak("at last")
        #expect(inner.spoken == ["at last"], "both are off: it speaks")
    }

    @Test func aVoiceSwitchedInWhileWSurfIsMutedIsMuted() {
        let first = RecordingVoice()
        let voice = ProviderSpeechOutput(output: first)
        voice.isSilenced = true

        let second = RecordingVoice()
        voice.use(second)
        #expect(second.isMuted, "the voice of another provider starts silent too")
        voice.isSilenced = false
        #expect(!second.isMuted)
    }

    // MARK: - The windows

    @Test func mutingWSurfSilencesTheVoiceOfEveryWindowAndLeavesTheSettingAlone() async throws {
        try await withApplication { app, main in
            let second = app.newWindow(profile: main.profiles.current, show: false)
            let own = main.isSpeechMuted
            let stored = UserDefaults.standard.object(forKey: "speech.muted") as? Bool
            #expect(!main.speech.isSilenced && !second.speech.isSilenced)

            app.muteAll()
            #expect(main.speech.isSilenced && second.speech.isSilenced)
            #expect(main.isSpeechMuted == own && second.isSpeechMuted == own, "the assistant's own setting is not touched")

            app.unmuteAll()
            #expect(!main.speech.isSilenced && !second.speech.isSilenced)
            #expect(main.isSpeechMuted == own)
            #expect(UserDefaults.standard.object(forKey: "speech.muted") as? Bool == stored, "and nothing is saved by it")
        }
    }

    @Test func aWindowOpenedWhileWSurfIsMutedIsSilentFromTheStart() async throws {
        try await withApplication { app, main in
            app.muteAll()
            let later = app.newWindow(profile: main.profiles.current, show: false)
            #expect(later.speech.isSilenced)

            app.unmuteAll()
            #expect(!later.speech.isSilenced)
        }
    }

    @Test func theAssistantsOwnMuteChosenWhileWSurfIsMutedSurvivesTheUnmute() async throws {
        try await withApplication { app, main in
            if main.isSpeechMuted {
                main.toggleSpeechMute()
            }
            #expect(!main.isSpeechMuted)
            defer {
                if !main.isSpeechMuted {
                    main.toggleSpeechMute()
                }
            }

            app.muteAll()
            main.toggleSpeechMute()
            #expect(main.isSpeechMuted)
            app.unmuteAll()
            #expect(main.isSpeechMuted, "the person muted the assistant's voice in the meantime: it stays muted")
            #expect(!main.speech.isSilenced)
        }
    }

    @Test func readingAnAnswerAloudStaysSilentWhileWSurfIsMutedAndSpeaksOnceItIsNot() async throws {
        try await withApplication { app, main in
            let inner = RecordingVoice()
            main.speech.use(inner)
            let own = main.isSpeechMuted
            defer {
                if main.isSpeechMuted != own {
                    main.toggleSpeechMute()
                }
            }
            if !main.isSpeechMuted {
                main.toggleSpeechMute()
            }

            main.readAloud("Read on request")
            #expect(inner.spoken == ["Read on request"], "the person's own mute does not stop a reading they asked for")

            app.muteAll()
            main.readAloud("Read while WSurf is muted")
            #expect(inner.spoken == ["Read on request"], "WSurf's does")

            app.unmuteAll()
            main.readAloud("Read after")
            #expect(inner.spoken == ["Read on request", "Read after"])
        }
    }

    @Test func aConversationByVoiceEndsWhenWSurfIsMuted() async throws {
        try await withApplication { app, main in
            main.isVoiceConversationPresented = true
            app.muteAll()
            #expect(!main.isVoiceConversationPresented, "it ends, as it does when the person mutes the assistant's voice")
            app.unmuteAll()
            #expect(!main.isVoiceConversationPresented, "and unmuting does not start another")
        }
    }

    @Test func theMuteOfWSurfIsOnlyForTheSession() async throws {
        try await withApplication { app, main in
            app.muteAll()
            #expect(main.speech.isSilenced)
        }
        try await withApplication { app, main in
            #expect(!app.isMuted && !main.speech.isSilenced, "a new run of the app is not muted")
        }
    }

    // MARK: - Read Aloud

    private func listener(_ voice: RecordingVoice) -> ReaderListener {
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite("SpeechMute-\(UUID().uuidString)"))!
        return ReaderListener(output: voice, settings: BrowserSettings(defaults: defaults))
    }

    private let blocks: [Int: String] = [0: "First one. Second one.", 1: "Third one."]

    private func source() -> ReaderListener.Source {
        { block in blocks[block].map { ReaderSpeech.Passage(text: $0, language: nil) } }
    }

    @Test func aReadingPausesWhenWSurfIsMutedAndGoesOnFromTheSentenceItWasOn() async throws {
        let voice = RecordingVoice()
        let reading = listener(voice)
        reading.start(blocks: [0, 1], source: source())
        try #require(await waitUntil { voice.spoken == ["First one."] })

        reading.setSilenced(true)
        #expect(reading.state == .paused, "it waits where it is, as if the person had paused it")
        #expect(voice.isMuted && voice.stops >= 1, "and the voice stops at once")

        voice.onSpeakingChange?(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(voice.spoken == ["First one."], "nothing moves on in the meantime")
        #expect(reading.spot?.range == 0..<10)

        reading.setSilenced(false)
        #expect(reading.state == .playing)
        #expect(await waitUntil { voice.spoken == ["First one.", "First one."] }, "from the sentence it was on")
        #expect(!voice.isMuted)
    }

    @Test func aReadingThePersonPausedStaysPausedWhenWSurfIsUnmuted() async throws {
        let voice = RecordingVoice()
        let reading = listener(voice)
        reading.start(blocks: [0], source: source())
        try #require(await waitUntil { voice.spoken.count == 1 })

        reading.togglePause()
        #expect(reading.state == .paused)
        reading.setSilenced(true)
        reading.setSilenced(false)
        #expect(reading.state == .paused, "it was the person's pause, not WSurf's")
        try await Task.sleep(for: .milliseconds(150))
        #expect(voice.spoken.count == 1)
    }

    @Test func aReadingBegunWhileWSurfIsMutedWaitsAtItsFirstSentenceAndSpeaksWhenUnmuted() async throws {
        let voice = RecordingVoice()
        let reading = listener(voice)
        reading.setSilenced(true)

        reading.start(blocks: [0, 1], source: source())
        try #require(await waitUntil { reading.state == .paused })
        #expect(reading.spot?.range == 0..<10, "the sentence it will begin with is marked")
        #expect(voice.spoken.isEmpty)

        reading.setSilenced(false)
        #expect(await waitUntil { voice.spoken == ["First one."] })
        #expect(reading.state == .playing)
    }

    @Test func aStoppedReadingIsNotStartedByUnmuting() async throws {
        let voice = RecordingVoice()
        let reading = listener(voice)
        reading.start(blocks: [0], source: source())
        try #require(await waitUntil { voice.spoken.count == 1 })
        reading.setSilenced(true)

        reading.stop()
        reading.setSilenced(false)
        #expect(reading.state == .idle)
        try await Task.sleep(for: .milliseconds(150))
        #expect(voice.spoken.count == 1)
    }

    @Test func aReadingIsToldOnceAndNotWhenNothingChanges() {
        let voice = RecordingVoice()
        let reading = listener(voice)
        reading.setSilenced(false)
        #expect(voice.stops == 0 && !voice.isMuted)
        reading.setSilenced(true)
        reading.setSilenced(true)
        #expect(reading.isSilenced && voice.isMuted)
    }

    // MARK: - The tabs

    @Test func muteWSurfPausesTheReadingOfEveryTabAndTellsTabsMadeLater() async throws {
        try await withApplication { app, main in
            let voice = RecordingVoice()
            let reading = listener(voice)
            let tab = main.browser.newTab(adopting: WKWebView())
            tab.reader.speaker = reading
            #expect(!tab.reader.isSilenced)

            app.muteAll()
            #expect(tab.reader.isSilenced && reading.isSilenced)

            let later = main.browser.newTab(adopting: WKWebView())
            main.media.receiveScriptMessage("hello", from: later.page, isMainFrame: true)
            #expect(later.reader.isSilenced, "a tab made while WSurf is muted is told when its page starts")

            app.unmuteAll()
            #expect(!tab.reader.isSilenced && !reading.isSilenced)
            #expect(!later.reader.isSilenced)
        }
    }

    @Test func aReadingStartedOnATabThatWasToldIsMadeSilent() async throws {
        try await withApplication { app, main in
            let tab = main.browser.newTab(adopting: WKWebView())
            app.muteAll()
            let reading = tab.reader.listener
            #expect(reading.isSilenced, "a listener made after the mute is born silent")
            app.unmuteAll()
            #expect(!reading.isSilenced)
        }
    }
}
