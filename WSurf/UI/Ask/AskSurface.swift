// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

struct AskSurface: View {
    enum Placement: Equatable {
        case toolbar
        case startPage

        var rowHeight: CGFloat {
            self == .toolbar ? 36 : 44
        }
        var orbSize: CGFloat {
            self == .toolbar ? 18 : 26
        }
        var cornerRadius: CGFloat {
            Theme.Radius.card
        }
        var textSize: CGFloat {
            self == .toolbar ? 12.5 : 13.5
        }
        var rowInset: CGFloat {
            self == .toolbar ? 6 : 8
        }
        var controlSpacing: CGFloat {
            self == .toolbar ? 6 : 10
        }
        var iconSlot: CGFloat {
            orbSize + 2
        }
        var messageLineLimit: Int {
            self == .toolbar ? 4 : 6
        }
        var placeholder: String {
            String(localized: "Search, “@” to ask, or enter website name")
        }
        var mirrorsPageURL: Bool {
            self == .toolbar
        }
        var showsSiteControls: Bool {
            self == .toolbar
        }
    }

    @State private var model: AskSurfaceModel
    /// Results, questions and context grow above the row instead of below it, for a bar at the bottom of the window.
    private let opensUpward: Bool

    init(placement: Placement, browser: BrowserModel, coordinator: AppCoordinator, opensUpward: Bool = false) {
        _model = State(initialValue: AskSurfaceModel(
            placement: placement,
            browser: browser,
            coordinator: coordinator
        ))
        self.opensUpward = opensUpward
    }

    var body: some View {
        let sections = model.resultSections()
        let activity = model.activity
        let restingContent = model.restingContent
        let status = surfaceStatus(activity: activity)
        let contextPages = sections.contains { $0.id == "ask" } ? model.contextPages : []

        VStack(spacing: 0) {
            if opensUpward {
                extras(sections: sections, contextPages: contextPages)
            }

            AskSurfaceRow(
                model: model,
                sections: sections,
                restingContent: restingContent,
                placeholder: model.placeholder,
                accessibilityValue: model.accessibilityValue,
                security: model.security
            )
            .contentShape(Rectangle())
            .contextMenu {
                AskSurfaceAddressMenu(model: model)
            }

            if !opensUpward {
                extras(sections: sections, contextPages: contextPages)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            AskSurfaceBackdrop(
                placement: model.placement,
                status: status,
                isThinking: activity.isThinking,
                isRunning: activity.isRunning
            )
        }
        .modifier(AskSurfaceMaterial(
            placement: model.placement,
            tint: status?.color,
            cornerRadius: model.placement.cornerRadius,
            isPrivate: model.isPrivate
        ))
        .overlay {
            AskSurfaceBorder(
                cornerRadius: model.placement.cornerRadius,
                isPrivate: model.isPrivate,
                status: status,
                isFocused: model.isFocused
            )
        }
        .overlay(alignment: opensUpward ? .bottom : .top) {
            if model.placement == .toolbar {
                AskSurfaceLoadingLine(model: model)
            }
        }
        .transformEnvironment(\.colorScheme) { if model.isPrivate { $0 = .dark } }
        .transformEnvironment(\.chromeIsLight) { if model.isPrivate { $0 = false } }
        .contentShape(RoundedRectangle(cornerRadius: model.placement.cornerRadius, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: model.placement.rowHeight, alignment: opensUpward ? .bottom : .top)
        .animation(Theme.Motion.settle, value: model.isFocused)
        .animation(Theme.Motion.settle, value: model.isListening)
        .animation(Theme.Motion.drift, value: status)
        .animation(Theme.Motion.settle, value: model.agentMessage)
        .animation(Theme.Motion.settle, value: model.pendingQuestion)
        .animation(Theme.Motion.settle, value: model.coordinator.notice)
        .onAppear { model.prepare() }
        .onChange(of: model.currentURL) { _, url in
            model.currentURLDidChange(url)
        }
        .onChange(of: model.activeTabID) { _, _ in
            model.activeTabDidChange()
        }
        .onChange(of: model.coordinator.addressBarFocusToken) { _, _ in
            model.focusFromAddressCommand()
        }
    }

    /// The pending question, the results and the pages attached to a question: below the row, or above it, mirrored, when
    /// the surface opens upward, so the row stays nearest the window edge either way.
    @ViewBuilder
    private func extras(sections: [OmniboxSection], contextPages: [AskContextPage]) -> some View {
        if opensUpward {
            AskContextStrip(pages: contextPages)
            results(sections)
            question
        } else {
            question
            results(sections)
            AskContextStrip(pages: contextPages)
        }
    }

    @ViewBuilder
    private var question: some View {
        if model.pendingQuestion != nil {
            if !opensUpward {
                Divider()
                    .padding(.horizontal, 12)
            }

            AskQuestionBlock(
                questions: model.coordinator.agentQuestions,
                placement: model.placement
            )
            .transition(.opacity)

            if opensUpward {
                Divider()
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private func results(_ sections: [OmniboxSection]) -> some View {
        if !sections.isEmpty {
            if !opensUpward {
                Divider()
                    .padding(.horizontal, 12)
            }

            OmniboxList(
                sections: sections,
                settings: model.coordinator.context.settings,
                query: model.resultQuery,
                selection: model.interaction.selection,
                density: .compact,
                containerRadius: model.placement.cornerRadius,
                onSelect: { model.hoverSuggestion(at: $0, in: sections) },
                onRun: { model.run(at: $0, in: sections) }
            )
            .transition(.opacity)

            if opensUpward {
                Divider()
                    .padding(.horizontal, 12)
            }
        }
    }

    private func surfaceStatus(activity: AskSurfaceActivity) -> AskSurfaceStatus? {
        if model.isListening {
            return .listening
        }
        if model.coordinator.statusMessage != nil {
            return .warning
        }
        if activity.isRunning {
            return .agent
        }
        return nil
    }
}

/// The page's loading line, in a view of its own: the page's progress changes many times a second, and only this view reads it, so
/// the whole surface is not built again for each step.
private struct AskSurfaceLoadingLine: View {
    let model: AskSurfaceModel

    var body: some View {
        if let tab = model.browser.activeTab {
            AddressLoadingIndicator(
                progress: tab.progress,
                isLoading: tab.isLoading,
                isSuppressed: model.isFocused || model.pendingQuestion != nil
            )
            .id(tab.id)
            .frame(height: max(model.placement.rowHeight, model.interaction.rowHeight))
            .clipShape(RoundedRectangle(cornerRadius: model.placement.cornerRadius, style: .continuous))
        }
    }
}
