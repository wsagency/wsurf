// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import WSurfCore

/// Only one regular window presents a decision. The durable choice belongs to the catalog, even when the window shows another profile.
struct DeletedCloudProfilePrompt: View {
    let coordinator: AppCoordinator

    private struct Decision: Equatable {
        let profile: Profile
        let instance: CloudProfileInstance
    }

    private var decision: Decision? {
        guard !coordinator.isClosed, !coordinator.isMicro, !coordinator.profiles.isPrivate,
              coordinator.application?.externalLinkTarget === coordinator else { return nil }
        let ledger = coordinator.profiles.cloudLedger
        for profile in coordinator.profiles.profiles {
            if let retired = ledger.pending[profile.id] {
                return Decision(profile: profile, instance: retired)
            }
        }
        return nil
    }

    var body: some View {
        Color.clear.task(id: decision) {
            guard let choice = decision else { return }
            while !Task.isCancelled, decision == choice {
                guard let window = coordinator.nativeWindow, window.isVisible, window.attachedSheet == nil,
                      let app = coordinator.application, !app.showingCloudProfileDecision else {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                app.showingCloudProfileDecision = true
                await present(choice, on: window)
                app.showingCloudProfileDecision = false
            }
        }
    }

    private func response(to alert: NSAlert, on parent: NSWindow) async -> NSApplication.ModalResponse {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancel }
            return await alert.beginSheetModal(for: parent)
        } onCancel: {
            Task { @MainActor in
                if alert.window.sheetParent === parent {
                    parent.endSheet(alert.window, returnCode: .cancel)
                }
            }
        }
    }

    private func present(_ choice: Decision, on window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = String(localized: "This profile was deleted from iCloud")
        alert.informativeText = String(localized: "“\(choice.profile.name)” is still on this Mac. Create a new iCloud instance to share it again, or delete the local copy.")
        alert.addButton(withTitle: String(localized: "Create New Instance"))
        alert.addButton(withTitle: String(localized: "Delete from This Mac"))
        let answer = await response(to: alert, on: window)
        guard !Task.isCancelled, decision == choice, let service = CloudSync.shared else { return }
        do {
            if answer == .alertFirstButtonReturn {
                try await service.createNewInstance(of: choice.profile, retiring: choice.instance)
            } else if answer == .alertSecondButtonReturn {
                let confirm = NSAlert()
                confirm.alertStyle = .warning
                confirm.messageText = String(localized: "Delete \"\(choice.profile.name)\"?")
                let note = try await CredentialErasureNote.warning(for: choice.profile, rechecking: [], localOnly: true)
                confirm.informativeText = note.message
                confirm.addButton(withTitle: String(localized: "Cancel"))
                confirm.addButton(withTitle: String(localized: "Delete profile")).hasDestructiveAction = true
                guard await response(to: confirm, on: window) == .alertSecondButtonReturn, !Task.isCancelled, decision == choice else { return }
                try await service.verifyDecision(choice.instance, profile: choice.profile.id)
                try await coordinator.deleteProfile(choice.profile, confirmedVaults: [], scope: .localOnly(choice.instance)).get()
            }
        } catch {
            guard !coordinator.isClosed else { return }
            let failure = NSAlert()
            failure.messageText = String(localized: "WSurf couldn’t save this change. Try again.")
            failure.informativeText = error.localizedDescription
            _ = await response(to: failure, on: window)
        }
    }
}
