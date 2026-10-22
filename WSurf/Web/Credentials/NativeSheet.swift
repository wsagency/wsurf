// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices

/// The one way a credential prompt is shown as a sheet: it is dismissed physically when the awaiting task is cancelled or its deadline
/// passes, so a cancelled request never leaves its sheet alive.
@MainActor
enum NativeSheet {
    enum Presented { case response(NSApplication.ModalResponse), expired, cancelled }

    /// Waits for a sheet already on `anchor` to finish closing. The system's passkey sheet (a vault unlock) is still attached
    /// for a moment after its answer arrives, and the step that follows asks for the same window. `false` when a sheet is
    /// still there at the bound: the caller refuses, it never queues behind it.
    static func waitForSheetToClose(on anchor: ASPresentationAnchor, limit: Duration = .seconds(3)) async -> Bool {
        // ponytail: polls every 50 ms for up to `limit`; observe NSWindow.didEndSheetNotification if the poll ever shows in a profile.
        let end = ContinuousClock.now.advanced(by: limit)
        while anchor.attachedSheet != nil, ContinuousClock.now < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return anchor.attachedSheet == nil
    }

    /// Runs `alert` as a sheet that ends at the deadline or when the awaiting task is cancelled. Cancellation ends only this alert's
    /// own sheet; an already-cancelled task never shows one.
    static func present(_ alert: NSAlert, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> Presented {
        guard !Task.isCancelled else { return .cancelled }
        final class Flag { var expired = false }
        let flag = Flag()
        let window = alert.window
        // No deadline (a conditional request) means no timer: the sheet ends by an answer or by cancellation.
        let timer = deadline.map { deadline in
            Task { @MainActor in
                guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
                flag.expired = true
                anchor.endSheet(window, returnCode: .abort)
            }
        }
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: anchor) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in anchor.endSheet(window, returnCode: .abort) }
        }
        timer?.cancel()
        if flag.expired {
            return .expired
        }
        if Task.isCancelled {
            return .cancelled
        }
        return .response(response)
    }
}
