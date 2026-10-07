// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

struct AgentProgressMonitorTests {
    @Test func changedDocumentsKeepRepeatedVisualActionsMovingWithoutPageSelector() {
        var monitor = AgentProgressMonitor(policy: .interactive)
        for index in 1...8 {
            #expect(monitor.observe(
                name: "clickAtPoint", arguments: "{\"x\":100,\"y\":100}",
                output: "CONTROL: Browser action completed. Updated screenshot captured.",
                failed: false, visualPage: "resolved-tab", visualDocument: "document-\(index)"
            ) == .proceed)
        }
    }

    @Test func screenshotAndActionVariationsDoNotHideUnchangedVisualPage() {
        var monitor = AgentProgressMonitor(policy: .interactive)
        let decisions = (1...6).map { index in
            monitor.observe(
                name: index.isMultiple(of: 2) ? "clickAtPoint" : "typeAtPointer",
                arguments: "{\"x\":\(index * 10),\"y\":100}",
                output: "CONTROL: Browser action completed. Updated screenshot \(index).",
                failed: false, visualPage: "resolved-tab", visualDocument: "same-document"
            )
        }
        #expect(decisions == [.proceed, .proceed, .recover, .proceed, .proceed, .pause])
    }

    @Test func resolvedTabChangeKeepsRepeatedVisualActionsMoving() {
        var monitor = AgentProgressMonitor(policy: .interactive)
        for index in 1...8 {
            #expect(monitor.observe(
                name: "clickAtPoint", arguments: "{}",
                output: "CONTROL: Browser action completed.",
                failed: false, visualPage: "tab-\(index)", visualDocument: "same-document"
            ) == .proceed)
        }
    }

    @Test func changedFailureStateStillRecoversThenPauses() {
        var monitor = AgentProgressMonitor(policy: .interactive)
        let decisions = (1...6).map { index in
            monitor.observe(name: "clickAtPoint", arguments: "{}", output: "Input unverified.",
                            failed: true, visualPage: "resolved-tab", visualDocument: "document-\(index)")
        }
        #expect(decisions == [.proceed, .proceed, .recover, .proceed, .proceed, .pause])
    }

    private func output(_ id: Int, text: String = "Pending", page: String = "same-page") -> String {
        "<page-content untrusted=\"true\">\npageID: \(page)\nPAGE TEXT:\n\(text)\n\nCONTROLS:\n[1] button \"Refresh\"\n\nobservationID: snapshot\(id)\n</page-content>"
    }

    @Test func freshObservationIDsCannotHideRepeatedReads() {
        var monitor = AgentProgressMonitor(policy: .interactive)
        let decisions = (1...6).map { monitor.observe(name: "readPage", arguments: "{}", output: output($0), failed: false) }
        #expect(decisions == [.proceed, .proceed, .recover, .proceed, .proceed, .pause])
    }

    @Test func actionCredentialsAndJSONOrderDoNotHideAStall() {
        var monitor = AgentProgressMonitor(policy: .interactive)
        for index in 1...3 {
            let arguments = index == 2 ? "{\"ref\":1,\"observationID\":\"two\"}" : "{\"observationID\":\"\(index)\",\"ref\":1}"
            #expect(monitor.observe(name: "clickOnPage", arguments: arguments, output: output(index), failed: false)
                == (index == 3 ? .recover : .proceed))
        }
    }

    @Test func changedContentTargetsAndPaginationRemainProgress() {
        var monitor = AgentProgressMonitor(policy: .interactive)
        for index in 1...6 {
            #expect(monitor.observe(name: "readPage", arguments: "{}", output: output(index, text: "Row \(index)"), failed: false) == .proceed)
            #expect(monitor.observe(name: "readPage", arguments: "{\"textOffset\":\(index)}", output: output(index), failed: false) == .proceed)
            #expect(monitor.observe(name: "readPage", arguments: "{}", output: output(index, page: "page\(index)"), failed: false) == .proceed)
        }
    }

    @Test func pageContentThatLooksLikeMetadataIsPreserved() {
        var monitor = AgentProgressMonitor(policy: .interactive)
        for index in 1...6 {
            #expect(monitor.observe(name: "readPage", arguments: "{}", output: output(index, text: "observationID: page-text-\(index)"), failed: false) == .proceed)
        }
    }

    @Test func scopedExecutionPolicyDoesNotChangeUserSettings() {
        AgentExecutionPolicy.$scoped.withValue(.init(maxModelRequests: 7)) {
            #expect(AgentExecutionPolicy.current.maxModelRequests == 7)
        }
        #expect(AgentExecutionPolicy.scoped == nil)
    }
}
