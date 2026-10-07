// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Observation

@MainActor
protocol AgentTurnBrowsing: AnyObject {
    var agentConsentWindow: ExtensionWindowAdapter? { get }
    func ensureAgentTabID() -> UUID
    func agentSpaceID(forTab tabID: UUID) -> UUID
    func agentContextSummary(mentionedTabIDs: [UUID]) -> String?
    func setAgentWorking(_ isWorking: Bool, inSpace spaceID: UUID)
}

extension AgentTurnBrowsing {
    var agentConsentWindow: ExtensionWindowAdapter? {
        nil
    }
}

extension BrowserModel: AgentTurnBrowsing {
    var agentConsentWindow: ExtensionWindowAdapter? {
        context.extensions.adapter(for: self)
    }

    func ensureAgentTabID() -> UUID {
        ensureActiveTab().id
    }

    func agentSpaceID(forTab tabID: UUID) -> UUID {
        spaceID(of: tabID)
    }

    func agentContextSummary(mentionedTabIDs: [UUID]) -> String? {
        contextSummary(mentionedTabIDs: mentionedTabIDs)
    }

    func setAgentWorking(_ isWorking: Bool, inSpace spaceID: UUID) {
        for tab in spaceTabs(spaceID) {
            tab.setAgentWorking(isWorking)
        }
    }
}

@MainActor
protocol AgentTurnLogging: AnyObject {
    func beginTask(_ prompt: String, tabID: UUID) -> UUID
    func setAttachments(_ attachments: [AssistantAttachment], textOnly: Bool, taskID: UUID)
    func completeTask(_ taskID: UUID, response: String)
    func cancelTask(_ taskID: UUID)
    func removeTab(_ tabID: UUID)
    func reassign(from tabID: UUID, to newTabID: UUID)
}

extension AgentTurnLogging {
    func setAttachments(_ attachments: [AssistantAttachment], textOnly: Bool, taskID: UUID) {}
}

extension ConversationLog: AgentTurnLogging {}

@MainActor
@Observable
final class AgentTurnModel {
    private(set) var reply: AgentReplyModel

    private(set) var runnerName = "none"
    private(set) var activeTask: AgentTaskContext?
    private(set) var supportsCompaction = false
    private(set) var compactingSpaceID: UUID?
    private(set) var compactionMessage: LocalizedStringResource?
    private(set) var compactionMessageSpaceID: UUID?

    @ObservationIgnored private let browser: any AgentTurnBrowsing
    @ObservationIgnored private var log: any AgentTurnLogging
    @ObservationIgnored private let speech: any SpeechOutput
    @ObservationIgnored private var modelSettings: LLMSettings
    @ObservationIgnored private var actionPolicy: AgentActionPolicy
    @ObservationIgnored private var runner: (any AgentRunner)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var completion: ((Result<AgentTurnResult, any Error>) -> Void)?
    @ObservationIgnored private var compactionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSpaceMoves: [(from: UUID, to: UUID)] = []
    @ObservationIgnored var onTurnFinished: (() -> Void)?

    var onCancel: (() -> Void)?

    init(
        browser: any AgentTurnBrowsing,
        log: any AgentTurnLogging,
        speech: any SpeechOutput,
        modelSettings: LLMSettings = .current,
        actionPolicy: AgentActionPolicy,
        reply: AgentReplyModel = AgentReplyModel()
    ) {
        self.browser = browser
        self.log = log
        self.speech = speech
        self.modelSettings = modelSettings
        self.actionPolicy = actionPolicy
        self.reply = reply
    }

    func adopt(log: any AgentTurnLogging) {
        guard self.log !== log else { return }
        cancel()
        forgetEveryConversation()
        self.log = log
        reply = AgentReplyModel()
    }

    func adopt(context: BrowserProfileContext) {
        adopt(log: context.conversationLog)
        modelSettings = context.modelSettings
        actionPolicy = context.actionPolicy
    }

    /// Stop the old owner's work without deleting the transferred tab's conversation.
    func detachTab(_ tabID: UUID, inSpace spaceID: UUID) {
        cancel()
        runner?.discardSession(forTab: tabID)
        if spaceID != tabID {
            runner?.discardSession(forTab: spaceID)
        }
        if reply.spaceID == tabID || reply.spaceID == spaceID {
            reply = AgentReplyModel()
        }
    }

    var isRunning: Bool {
        activeTask != nil
    }
    var activeTabID: UUID? {
        activeTask?.tabID
    }
    var activeSpaceID: UUID? {
        activeTask?.spaceID
    }

    func use(_ runner: (any AgentRunner)?) {
        cancelCompaction()
        self.runner = runner
        runnerName = runner?.name ?? "none"
        supportsCompaction = runner?.supportsCompaction == true
    }

    func compactContext(inSpace spaceID: UUID) {
        guard !isRunning, compactingSpaceID == nil, let runner, runner.supportsCompaction else { return }
        compactingSpaceID = spaceID
        compactionMessage = nil
        compactionMessageSpaceID = spaceID
        let modelSettings = modelSettings
        compactionTask = Task { [weak self] in
            let message: LocalizedStringResource
            do {
                let changed = try await LLMSettings.$scoped.withValue(modelSettings) {
                    try await runner.compactContext(forTab: spaceID)
                }
                message = changed ? "Context compacted" : "No context to compact"
            } catch {
                message = "Couldn’t compact. Context unchanged."
            }
            guard !Task.isCancelled, let self else { return }
            compactingSpaceID = nil
            compactionMessage = message
            compactionTask = nil
        }
    }

    private func cancelCompaction() {
        compactionTask?.cancel()
        compactionTask = nil
        compactingSpaceID = nil
        compactionMessage = nil
        compactionMessageSpaceID = nil
    }

    @discardableResult
    func run(
        utterance: String,
        mentionedTabIDs: [UUID] = [],
        attachments: [AssistantAttachment] = [],
        attachmentTextOnly: Bool = false,
        isContinuation: Bool = false,
        trace: LatencyTrace? = nil,
        showsInChrome: Bool = true,
        speechOverride: (any SpeechOutput)? = nil,
        completion: ((Result<AgentTurnResult, any Error>) -> Void)? = nil
    ) -> Bool {
        guard let runner else {
            trace?.end()
            return false
        }

        cancel()
        self.completion = completion
        let tabID = browser.ensureAgentTabID()
        let spaceID = browser.agentSpaceID(forTab: tabID)
        let contextualized: String
        if let context = browser.agentContextSummary(mentionedTabIDs: mentionedTabIDs) {
            contextualized = "\(context)\n\(utterance)"
        } else {
            contextualized = utterance
        }
        let traceID = LLMSettings.$scoped.withValue(modelSettings) {
            log.beginTask(isContinuation ? "" : utterance, tabID: spaceID)
        }
        let task = AgentTaskContext(
            id: traceID,
            tabID: tabID,
            spaceID: spaceID,
            mentionedTabIDs: mentionedTabIDs,
            attachments: attachments,
            attachmentTextOnly: attachmentTextOnly,
            isContinuation: isContinuation
        )
        log.setAttachments(attachments, textOnly: attachmentTextOnly, taskID: task.id)
        browser.setAgentWorking(true, inSpace: spaceID)
        activeTask = task
        reply.bind(toSpace: spaceID, showsInChrome: showsInChrome)

        let speech = speechOverride ?? speech
        let modelSettings = modelSettings
        let actionPolicy = actionPolicy
        let consentWindow = browser.agentConsentWindow
        runTask = Task { [weak self, reply] in
            await LLMSettings.$scoped.withValue(modelSettings) {
                await AgentActionConsent.$scopedPolicy.withValue(actionPolicy) {
                    await AgentActionConsent.$scopedWindow.withValue(consentWindow) {
                        await runner.run(
                            utterance: contextualized,
                            task: task,
                            into: reply,
                            speech: speech
                        )
                    }
                }
            }
            trace?.mark("turnComplete")
            trace?.end()

            guard let self, activeTask?.id == task.id else { return }
            log.completeTask(task.id, response: reply.text ?? "")
            browser.setAgentWorking(false, inSpace: task.spaceID)
            activeTask = nil
            runTask = nil
            applyPendingSpaceMoves()
            let completed = self.completion
            self.completion = nil
            onTurnFinished?()
            completed?(.success(.init(taskID: task.id, text: reply.text ?? "")))
        }
        return true
    }

    func cancel() {
        cancelCompaction()
        let hadActiveTurn = activeTask != nil || runTask != nil
        onCancel?()
        runTask?.cancel()
        runTask = nil
        if let activeTask {
            browser.setAgentWorking(false, inSpace: activeTask.spaceID)
            log.cancelTask(activeTask.id)
            self.activeTask = nil
        }
        reply.clear()
        if hadActiveTurn {
            reply = AgentReplyModel()
        }
        let completed = completion
        completion = nil
        applyPendingSpaceMoves()
        completed?(.failure(CancellationError()))
    }

    func reassignSpace(from spaceID: UUID, to newSpaceID: UUID) {
        guard spaceID != newSpaceID else { return }
        if compactingSpaceID == spaceID {
            cancelCompaction()
        }
        guard activeTask?.spaceID != spaceID else {
            pendingSpaceMoves.append((from: spaceID, to: newSpaceID))
            return
        }
        log.reassign(from: spaceID, to: newSpaceID)
        runner?.transferSession(from: spaceID, to: newSpaceID)
        if reply.spaceID == spaceID {
            reply.bind(toSpace: newSpaceID, showsInChrome: reply.showsInChrome)
        }
    }

    private func applyPendingSpaceMoves() {
        let moves = pendingSpaceMoves
        pendingSpaceMoves = []
        for move in moves {
            reassignSpace(from: move.from, to: move.to)
        }
    }

    func forgetEveryConversation() {
        cancelCompaction()
        runner?.discardAllSessions()
    }

    @discardableResult
    func closeTab(_ tabID: UUID) -> Bool {
        if compactingSpaceID == tabID {
            cancelCompaction()
        }
        let endedActiveTurn = activeTask?.tabID == tabID || activeTask?.spaceID == tabID
        if endedActiveTurn {
            cancel()
        }
        runner?.discardSession(forTab: tabID)
        log.removeTab(tabID)
        return endedActiveTurn
    }
}
