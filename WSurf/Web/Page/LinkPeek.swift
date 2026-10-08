// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class LinkPeek {
    enum Phase: Equatable {
        case loading
        case ready(LinkPeekSummary)
        case stillLoading
        case mediaOnly
        case noText
        case failed
    }

    static func emptyPhase(for page: LinkPeekPage) -> Phase {
        guard page.didFinishLoading else { return .stillLoading }
        return page.mediaCount > 0 ? .mediaOnly : .noText
    }

    struct Shown: Equatable {
        let url: URL
        let tabID: UUID
        var anchor: CGPoint
        var snapshot: NSImage?
        var phase: Phase
        var isStreaming = false

        var host: String {
            url.displayHost ?? ""
        }
    }

    nonisolated struct Candidate: Equatable {
        let url: URL
        let tabID: UUID
        let anchor: CGPoint
    }

    private(set) var shown: Shown?
    @ObservationIgnored private var shownContextID: UUID?

    static let trigger: NSEvent.ModifierFlags = .shift
    private static let holdDelay: Duration = .milliseconds(180)
    private static let rememberedSummaries = 24
    private static let rememberedSnapshots = 6

    private struct RememberedKey: Hashable {
        let contextID: UUID
        let url: URL
    }
    private struct Remembered {
        let summary: LinkPeekSummary
        var snapshot: NSImage?
    }

    @ObservationIgnored private let loader = LinkPeekLoader()
    @ObservationIgnored private var candidate: Candidate?
    @ObservationIgnored private var candidateContext: BrowserProfileContext?
    @ObservationIgnored private var pending: URL?
    @ObservationIgnored private var pendingContextID: UUID?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignActiveObserver: NSObjectProtocol?
    @ObservationIgnored private var remembered: [RememberedKey: Remembered] = [:]
    @ObservationIgnored private var order: [RememberedKey] = []
    @ObservationIgnored private var isSuppressed = false
    private(set) var isHeld = false

    func isEnabled(in context: BrowserProfileContext) -> Bool {
        context.settings.peeksAtLinks
            && LLMSettings.$scoped.withValue(context.modelSettings, operation: { LinkSummarizer.isAvailable })
    }

    // MARK: - Lifecycle

    func begin() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .scrollWheel {
                    self?.scrolled()
                } else {
                    self?.triggerChanged(isDown: event.modifierFlags.contains(Self.trigger))
                }
            }
            return event
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forget()
            }
        }
    }

    func end() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        resignActiveObserver = nil
        forget()
        loader.release()
    }

    // MARK: - Pointing

    func hovered(
        _ url: URL?,
        flags: NSEvent.ModifierFlags,
        tabID: UUID,
        anchor: CGPoint,
        context: BrowserProfileContext
    ) {
        guard context.settings.peeksAtLinks, !isSuppressed else { return }
        guard let url, LinkPeekLoader.canPeek(url) else {
            candidate = nil
            candidateContext = nil
            release()
            return
        }
        candidate = Candidate(url: url, tabID: tabID, anchor: anchor)
        candidateContext = context
        guard flags.contains(Self.trigger) else {
            release()
            return
        }
        isHeld = false
        start()
    }

    func show(_ url: URL, tabID: UUID, anchor: CGPoint, context: BrowserProfileContext) {
        guard context.settings.peeksAtLinks, !isSuppressed else { return }
        guard LinkPeekLoader.canPeek(url), isEnabled(in: context) else { return }
        candidate = Candidate(url: url, tabID: tabID, anchor: anchor)
        candidateContext = context
        isHeld = true
        start()
    }

    func forget() {
        candidate = nil
        candidateContext = nil
        dismiss()
    }

    func dismiss() {
        isHeld = false
        clear()
    }

    private func release() {
        guard !isHeld else { return }
        clear()
    }

    private func clear() {
        guard shown != nil || pending != nil || work != nil else { return }
        work?.cancel()
        work = nil
        pending = nil
        pendingContextID = nil
        loader.stop()
        if shown != nil {
            shown = nil
            shownContextID = nil
        }
    }

    func suppress() {
        isSuppressed = true
        forget()
    }

    func resume() {
        isSuppressed = false
    }

    private func scrolled() {
        guard shown != nil else { return }
        dismiss()
    }

    private func triggerChanged(isDown: Bool) {
        guard isDown else {
            release()
            return
        }
        start()
    }

    private func start() {
        guard !isSuppressed, let candidate, let context = candidateContext else { return }
        guard !(shown?.url == candidate.url && shownContextID == context.contextID),
              !(pending == candidate.url && pendingContextID == context.contextID) else { return }
        guard isEnabled(in: context) else { return }

        work?.cancel()
        pending = candidate.url
        pendingContextID = context.contextID
        let target = candidate
        work = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled else { return }
            await self?.peek(at: target, context: context)
        }
    }

    private func peek(at target: Candidate, context: BrowserProfileContext) async {
        let key = RememberedKey(contextID: context.contextID, url: target.url)
        if let kept = remembered[key] {
            present(target, context: context, phase: .ready(kept.summary), snapshot: kept.snapshot)
            return
        }
        present(target, context: context, phase: .loading)

        do {
            let page = try await loader.load(target.url, context: context)
            try Task.checkCancellation()
            guard shown?.url == target.url, shownContextID == context.contextID else { return }
            shown?.snapshot = page.snapshot

            guard page.hasReadableContent else {
                settle(target.url, context: context, to: Self.emptyPhase(for: page))
                return
            }
            let streamed = await LLMSettings.$scoped.withValue(context.modelSettings) {
                await LinkSummarizer.summarize(page, url: target.url) { [weak self] partial in
                    self?.stream(partial, for: target.url, context: context)
                }
            }
            guard let summary = streamed else {
                settle(target.url, context: context, to: .failed)
                return
            }
            remember(summary, snapshot: page.snapshot, for: target.url, context: context)
            settle(target.url, context: context, to: .ready(summary))
        } catch is CancellationError {
            return
        } catch {
            settle(target.url, context: context, to: .failed)
        }
    }

    private func present(_ target: Candidate, context: BrowserProfileContext, phase: Phase, snapshot: NSImage? = nil) {
        withAnimation(Theme.Motion.quick) {
            shown = Shown(
                url: target.url,
                tabID: target.tabID,
                anchor: target.anchor,
                snapshot: snapshot,
                phase: phase
            )
            shownContextID = context.contextID
        }
    }

    private func stream(_ summary: LinkPeekSummary, for url: URL, context: BrowserProfileContext) {
        guard !Task.isCancelled, shown?.url == url, shownContextID == context.contextID else { return }
        guard case .ready = shown?.phase else {
            withAnimation(Theme.Motion.settle) {
                shown?.phase = .ready(summary)
                shown?.isStreaming = true
            }
            return
        }
        shown?.phase = .ready(summary)
    }

    private func settle(_ url: URL, context: BrowserProfileContext, to phase: Phase) {
        guard !Task.isCancelled, shown?.url == url, shownContextID == context.contextID else { return }
        withAnimation(Theme.Motion.settle) {
            shown?.phase = phase
            shown?.isStreaming = false
        }
    }

    func keptSummary(for url: URL, context: BrowserProfileContext) -> LinkPeekSummary? {
        remembered[RememberedKey(contextID: context.contextID, url: url)]?.summary
    }

    func keptSnapshot(for url: URL, context: BrowserProfileContext) -> NSImage? {
        remembered[RememberedKey(contextID: context.contextID, url: url)]?.snapshot
    }

    func remember(_ summary: LinkPeekSummary, snapshot: NSImage?, for url: URL, context: BrowserProfileContext) {
        let key = RememberedKey(contextID: context.contextID, url: url)
        if remembered[key] == nil {
            order.append(key)
        }
        remembered[key] = Remembered(summary: summary, snapshot: snapshot)
        while order.count > Self.rememberedSummaries {
            remembered.removeValue(forKey: order.removeFirst())
        }
        for old in order.dropLast(Self.rememberedSnapshots) {
            remembered[old]?.snapshot = nil
        }
    }
}
