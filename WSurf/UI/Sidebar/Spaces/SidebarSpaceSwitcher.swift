// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// The spaces of every profile as a row of icons at the foot of the sidebar, shown once there is more than one. A click
/// jumps to a space of this profile (no glide in this version) or switches to another profile; a row dragged onto an
/// icon of this profile moves there.
struct SidebarSpaceSwitcher: View {
    let coordinator: AppCoordinator
    var axis: Axis = .horizontal

    private var entries: [SpaceEntry] {
        coordinator.spaceEntries
    }

    var body: some View {
        Group {
            if axis == .horizontal {
                ViewThatFits(in: .horizontal) {
                    dots
                    ScrollView(.horizontal) { dots }
                        .scrollIndicators(.never)
                }
                .frame(maxWidth: .infinity)
            } else {
                dots
            }
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            let live = Set(ids)
            coordinator.sidebarDrag.spaceDotFrames = coordinator.sidebarDrag.spaceDotFrames.filter { live.contains($0.key) }
        }
        .onDisappear {
            coordinator.sidebarDrag.spaceDotFrames = [:]
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Spaces"))
    }

    private var dots: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        return layout {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                SpaceDot(
                    entry: entry,
                    isForeign: entry.profile.id != coordinator.context.profile.id,
                    shortcut: SpaceShortcut.label(at: index),
                    isCurrent: entry.id == coordinator.browser.currentSpaceID,
                    isArmed: coordinator.sidebarDrag.armedSpaceID == entry.id
                ) {
                    coordinator.switchSpace(to: entry)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    coordinator.sidebarDrag.spaceDotFrames[entry.id] = $0
                }
                .contextMenu { menu(for: entry) }
            }
        }
    }

    @ViewBuilder
    private func menu(for entry: SpaceEntry) -> some View {
        if entry.profile.id == coordinator.context.profile.id {
            Button {
                coordinator.showSpaceEditor(for: entry.space)
            } label: {
                Label("Edit Space…", systemImage: "pencil")
            }
        }
        Button {
            coordinator.showNewSpaceEditor()
        } label: {
            Label("New Space…", systemImage: "plus")
        }
        if coordinator.canDeleteSpace(entry.space) {
            Divider()
            Button(role: .destructive) {
                Task { await coordinator.confirmDeleteSpace(entry.space) }
            } label: {
                Label("Delete Space…", systemImage: "trash")
            }
        }
    }
}

private struct SpaceDot: View {
    let entry: SpaceEntry
    /// A space of another profile: choosing it switches the window to that profile.
    let isForeign: Bool
    let shortcut: String?
    let isCurrent: Bool
    let isArmed: Bool
    let action: () -> Void

    private var name: String {
        isForeign ? String(localized: "\(entry.space.name) — \(entry.profile.name) profile") : entry.space.name
    }

    private var help: String {
        guard let shortcut else { return name }
        return "\(name) \(shortcut)"
    }

    var body: some View {
        QuietIconButton(
            symbol: entry.space.symbol,
            isOn: isCurrent || isArmed,
            tint: isCurrent ? entry.space.color.tint : nil,
            help: help,
            action: action
        )
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
