// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import WSurf

/// Whether the model reads only text is decided from the window's own profile settings, in the composer and on the
/// send path alike. `LLMSettings.current` is the original profile's store, which a named or private window must not use.
@MainActor
struct AttachmentTextOnlyTests {
    private static let model = "p3-attachment-test-model"

    private func coordinator() -> AppCoordinator {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let coordinator = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID()))
        coordinator.selectedProvider = ProviderCatalog.openAI
        coordinator.selectedModel = Self.model
        return coordinator
    }

    private func settings() -> LLMSettings {
        let suite = AppDatabase.defaultsSuite("AttachmentTextOnly-\(UUID().uuidString)")
        return LLMSettings(defaults: InMemoryUserDefaults(inheriting: UserDefaults(suiteName: suite)!))
    }

    private func image() throws -> Data {
        let image = NSImage(size: NSSize(width: 600, height: 160))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 160).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    /// Adds an image whose text reading stays open until the returned gate is opened.
    private func draftReading(
        _ gate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)
    ) async throws -> AttachmentDraft {
        let draft = AttachmentDraft { _ in
            for await _ in gate.stream {
                break
            }
            return "INVOICE 42"
        }
        draft.add([.bytes(try image(), name: "receipt.png", type: .png)])
        try #require(await waitForObservation { !draft.isImporting })
        try #require(draft.isRecognizing)
        return draft
    }

    @Test func aProfileThatMarksTheModelTextOnlyHoldsSendUntilTheTextIsRead() async throws {
        let coordinator = coordinator()
        // Only this window's profile knows the model reads no images; the original profile's store has no entry.
        ModelImageSupport.record(false, for: ProviderCatalog.openAI, model: Self.model, settings: coordinator.modelSettings)
        #expect(
            ModelImageSupport.acceptsImages(for: ProviderCatalog.openAI, model: Self.model),
            "the premise: the original profile's store has no entry, so the composer used to answer that it reads images"
        )
        let textOnly = coordinator.attachmentTextOnly
        #expect(textOnly)

        let gate = AsyncStream<Void>.makeStream()
        let draft = try await draftReading(gate)
        #expect(!draft.isReady(textOnly: textOnly))

        gate.continuation.yield()
        #expect(await waitForObservation { !draft.isRecognizing })
        #expect(draft.files.first?.text == "INVOICE 42")
        #expect(draft.isReady(textOnly: textOnly))
    }

    @Test func aProfileThatSaysTheModelReadsImagesDoesNotWaitWhateverTheOriginalProfileSays() async throws {
        let coordinator = coordinator()
        ModelImageSupport.record(true, for: ProviderCatalog.openAI, model: Self.model, settings: coordinator.modelSettings)
        // `LLMSettings.current` is this one while the scope lasts, as the original profile's store is outside it.
        let other = settings()
        ModelImageSupport.record(false, for: ProviderCatalog.openAI, model: Self.model, settings: other)
        let textOnly = LLMSettings.$scoped.withValue(other) { coordinator.attachmentTextOnly }
        #expect(!textOnly)

        let gate = AsyncStream<Void>.makeStream()
        let draft = try await draftReading(gate)
        #expect(draft.isReady(textOnly: textOnly))
        gate.continuation.finish()
    }
}
