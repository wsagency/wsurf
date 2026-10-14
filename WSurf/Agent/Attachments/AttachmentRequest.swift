// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AnyLanguageModel
import Foundation

nonisolated enum AttachmentRequest {
    static func images(_ attachments: [AssistantAttachment], textOnly: Bool) -> [Transcript.ImageSegment] {
        guard !textOnly else { return [] }
        return attachments.flatMap(\.images).map { .init(data: $0.data, mimeType: $0.mimeType) }
    }

    static let hostedImageTokens = 1_600

    /// Conservative on-device charge per image. The system model costs 19 to 195 input tokens per image
    /// whatever its size (measured on macOS 27.0 with the importer's 1,600 px photos and 1,200x1,552 PDF
    /// pages; the peak of every shape tried was 195), so 256 leaves about 30% headroom.
    /// ponytail: empirical margin, not a documented bound. Upgrade path: the framework's tokenCount(for:)
    /// once it counts image prompts (it throws ModelManagerError 1001 on macOS 27.0).
    static let onDeviceImageTokens = 256

    /// Per-image charge used by every budget check: preflight, run loop and retained-transcript estimates.
    static func imageTokens(onDevice: Bool) -> Int {
        onDevice ? onDeviceImageTokens : hostedImageTokens
    }

    static func imageTokens(for provider: Provider) -> Int {
        imageTokens(onDevice: provider.isOnDevice)
    }

    /// `imageTokens` is the per-image charge for the model that will receive them; see `imageTokens(onDevice:)`.
    static func validate(
        _ attachments: [AssistantAttachment], message: String, textOnly: Bool, windowTokens: Int, imageTokens: Int
    ) throws {
        try AssistantAttachment.validate(attachments)
        guard !attachments.isEmpty else { return }
        if textOnly, attachments.contains(where: { !$0.images.isEmpty && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw AttachmentFailure.message(String(localized: "No readable text was found in an image. Choose a model that can read images to send it."))
        }
        let characters = AssistantAttachment.prompt(message, attachments: attachments, textOnly: textOnly).count
        let attachedImageTokens = textOnly ? 0 : attachments.reduce(0) { $0 + $1.images.count * imageTokens }
        guard characters / 3 + attachedImageTokens < windowTokens / 2 else {
            throw AttachmentFailure.message(String(localized: "These attachments exceed this model’s context budget. Attach fewer pages or choose a model with a larger context window."))
        }
    }
}
