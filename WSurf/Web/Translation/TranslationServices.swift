// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
@preconcurrency import Translation

/// The process's only Translation framework objects, and the one queue every call to them goes through.
///
/// The framework streams language status to each live `LanguageAvailability` through one shared multicaster over XPC.
/// Releasing one while a status reply was still on its way crashed the process inside the framework
/// (`-[_LTLanguageStatusMulticaster _reconnectIfStreamingWithConnectionIdentifier:...]` on the
/// `com.apple.translation.text` reply thread, macOS 26.6). So each availability and each session is made once and never
/// released, and calls run one at a time instead of overlapping.
@MainActor
final class TranslationServices {
    static let shared = TranslationServices()

    // ponytail: one availability per strategy and one session per model and language pair, kept for the life of the process.
    // A person uses a handful of pairs; add eviction only if that ever grows.
    private var availabilities: [TranslationModel?: LanguageAvailability] = [:]
    private var sessions: [String: TranslationSession] = [:]
    private var supported: [String: Bool] = [:]
    private var tail: Task<Void, Never>?

    /// Calls queued or running.
    private(set) var pending = 0

    /// The framework objects made so far, for a test that checks none is replaced or released.
    var liveObjects: Set<ObjectIdentifier> {
        Set(availabilities.values.map(ObjectIdentifier.init) + sessions.values.map(ObjectIdentifier.init))
    }

    /// The pair's status for `model`'s strategy, or for the system's default strategy when `model` is nil.
    func status(from source: Locale.Language, to target: Locale.Language, using model: TranslationModel?) async -> LanguageAvailability.Status {
        await serially { [self] in
            await availability(for: model).status(from: source, to: target)
        }
    }

    /// Whether the system can translate the pair at all. That does not change while the app runs, so each pair is asked once.
    func isSupported(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        let key = "\(TranslationLanguage.key(source))>\(TranslationLanguage.key(target))"
        if let known = supported[key] {
            return known
        }
        let answer = await status(from: source, to: target, using: nil) != .unsupported
        supported[key] = answer
        return answer
    }

    /// Translates one block with the pair's session, which every page and tab in that pair shares.
    func translate(
        _ segments: [PageTranslationSegment], using model: TranslationModel, from source: Locale.Language, to target: Locale.Language
    ) async -> [Int: String]? {
        await serially { [self] in
            await PageTranslationRuns.translate(segments, with: session(for: model, from: source, to: target))
        }
    }

    /// Returns once every call queued so far has finished. Tests end with this, so no call is still running when the next
    /// test starts.
    func waitUntilIdle() async {
        while let last = tail {
            await last.value
            if tail == last {
                return
            }
        }
    }

    /// Runs `work` after every call queued before it. The call is not tied to its caller's task: a closed tab stops caring
    /// about the answer, but the framework call still finishes instead of being torn down half way.
    func serially<Value: Sendable>(_ work: @escaping @MainActor () async -> Value) async -> Value {
        let previous = tail
        pending += 1
        let call = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { @MainActor [self] in
            _ = await call.value
            pending -= 1
        }
        return await call.value
    }

    private func availability(for model: TranslationModel?) -> LanguageAvailability {
        if let made = availabilities[model] {
            return made
        }
        let made = model?.makeAvailability() ?? LanguageAvailability()
        availabilities[model] = made
        return made
    }

    private func session(for model: TranslationModel, from source: Locale.Language, to target: Locale.Language) -> TranslationSession {
        let key = "\(model)|\(TranslationLanguage.key(source))|\(TranslationLanguage.key(target))"
        if let made = sessions[key] {
            return made
        }
        let made = model.makeSession(from: source, to: target)
        sessions[key] = made
        return made
    }
}
