// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The editor's Files section: Add File…, and for each file Preview, Save Copy…, Open With… and Remove. A file is encrypted into the
/// vault as soon as it is added; it belongs to the entry once Save stores it. Preview and Open With decrypt a copy into this run's
/// private folder, removed when Quick Look closes (Open With: when the vault locks or WSurf quits). Nothing is decrypted until asked.
struct CredentialFilesSection: View {
    let model: CredentialSettingsModel
    @State private var isAdding = false
    @State private var previewURL: URL?
    @State private var pendingRemoval: CredentialAttachment?
    @State private var opening: CredentialAttachment?
    @State private var work: Task<Void, Never>?

    var body: some View {
        let files = model.draft?.attachments ?? []
        VStack(alignment: .leading, spacing: 10) {
            Text("Files").font(Theme.Font.rowTitle).accessibilityAddTraits(.isHeader)
            ForEach(files, content: row)
            HStack(spacing: 8) {
                Button {
                    chooseFiles()
                } label: {
                    Label("Add File…", systemImage: "plus")
                }
                .disabled(isAdding || files.count >= CredentialAttachment.entryLimit)
                if isAdding {
                    ProgressView().controlSize(.small)
                }
            }
            Text(verbatim: caption)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { old, _ in
            // Quick Look closed, or shows another file: the copy it showed goes.
            if let old {
                model.previewFolder.remove(old)
            }
        }
        .onDisappear {
            work?.cancel()
            if let previewURL {
                model.previewFolder.remove(previewURL)
            }
        }
        .confirmationDialog(
            "Remove File?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { file in
            Button("Remove File", role: .destructive) {
                model.removeFile(file.id)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { file in
            Text("“\(file.name)” is removed from this entry when you save. You can bring it back from History.")
        }
        .confirmationDialog(
            "Open in Another App?",
            isPresented: Binding(get: { opening != nil }, set: { if !$0 { opening = nil } }),
            presenting: opening
        ) { file in
            ForEach(Self.applications(for: file), id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path)) { open(file, with: app) }
            }
            Button("Cancel", role: .cancel) { opening = nil }
        } message: { _ in
            Text("""
                WSurf decrypts a copy for the app you choose. That app can keep its own copy, for example in its recent documents. \
                WSurf removes its copy when the vault locks or WSurf quits.
                """)
        }
    }

    private var caption: String {
        let limit = ByteCountFormatter.string(fromByteCount: CredentialAttachment.fileBytes, countStyle: .file)
        return String(localized: """
            Images, PDFs and any other files, up to \(limit) each and \(CredentialAttachment.entryLimit) per entry. They are encrypted \
            in the vault and aren’t included when you export credentials to another app.
            """)
    }

    private func row(_ file: CredentialAttachment) -> some View {
        let missing = !model.hasFile(file)
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        return HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(file.contentType) ?? .data))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                Text(verbatim: missing ? String(localized: "File missing") : size)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                preview(file)
            } label: {
                Image(systemName: "eye").accessibilityLabel("Preview \(file.name)")
            }
            .buttonStyle(.borderless)
            .help("Preview")
            .disabled(missing)
            Menu {
                Button("Save Copy…") { saveCopy(file) }
                    .disabled(missing)
                Button("Open With…") { opening = file }
                    .disabled(missing)
                Divider()
                Button("Remove…", role: .destructive) { pendingRemoval = file }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Actions for \(file.name)")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose files to keep encrypted with this entry.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        isAdding = true
        work = Task {
            await model.attempt { try await model.addFiles(urls) }
            isAdding = false
        }
    }

    /// The panel runs before anything is decrypted; the copy is written only after the person chose where.
    private func saveCopy(_ file: CredentialAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = VaultFilePreviewFolder.safeName(file.name)
        panel.message = String(localized: "The copy isn’t encrypted. Anyone who can open it can read it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        work = Task { await model.attempt { try await model.saveFileCopy(file, to: url) } }
    }

    private func preview(_ file: CredentialAttachment) {
        work = Task {
            await model.attempt {
                let url = try await model.temporaryCopy(of: file)
                guard !Task.isCancelled else {
                    model.previewFolder.remove(url)
                    return
                }
                previewURL = url
            }
        }
    }

    private func open(_ file: CredentialAttachment, with app: URL) {
        opening = nil
        work = Task {
            await model.attempt {
                let url = try await model.temporaryCopy(of: file)
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    /// The apps that say they open this kind of file, the default first; asked only when Open With… is chosen.
    private static func applications(for file: CredentialAttachment) -> [URL] {
        let type = UTType(file.contentType) ?? .data
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: type), let index = apps.firstIndex(of: preferred) {
            apps.insert(apps.remove(at: index), at: 0)
        }
        return Array(apps.prefix(8))
    }
}
