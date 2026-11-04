// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The save coordinator keeps the frames each page announced. A page that closes, and a document that goes away, take theirs
/// with them, so a long run of opening and closing tabs does not pile up frames (each keeps its web page alive).
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AutofillSaveFramesTests {
    private let coordinator = AutofillSaveCoordinator.shared

    /// A page nothing was loaded into, with the coordinator installed on it, and its tab's session.
    private func makePage(in context: BrowserProfileContext) -> (page: BrowserPage, session: AutofillSaveSession) {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration), context: context)
        let session = AutofillSaveSession()
        coordinator.install(in: page, session: session)
        return (page, session)
    }

    /// What the page script posts when a document starts: the document's ID and the frame it runs in.
    @discardableResult
    private func announce(in page: BrowserPage, main: Bool = true) -> String {
        let documentID = UUID().uuidString
        let frame = BrowserFrame(
            id: documentID, documentID: documentID, url: URL(string: "https://login.example/")!, isMainFrame: main,
            securityOrigin: BrowserSecurityOrigin(protocol: "https", host: "login.example", port: 0)
        )
        coordinator.receive(BrowserScriptMessage(
            page: page, body: ["action": "ready", "documentID": documentID, "url": "https://login.example/"],
            frameInfo: frame, name: "wsurfAutofillSave"
        ))
        return documentID
    }

    private func tracked(_ page: BrowserPage) -> Set<String> {
        Set((coordinator.frames[ObjectIdentifier(page)]?.values ?? [:]).keys)
    }

    @Test func closingManyPagesLeavesNoFramesBehind() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let baseline = coordinator.frames.count

        for _ in 0..<40 {
            let (page, session) = makePage(in: context)
            let main = announce(in: page)
            let child = announce(in: page, main: false)
            #expect(tracked(page) == [main, child])

            await page.close()

            #expect(coordinator.frames[ObjectIdentifier(page)] == nil, "a closed page's frames were kept")
            withExtendedLifetime(session) {}
        }

        #expect(coordinator.frames.count <= baseline, "\(coordinator.frames.count - baseline) frame lists outlived their pages")
        await context.endPrivateSession()
    }

    @Test func aRetiredDocumentIsForgottenAndTheOthersStay() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let (page, session) = makePage(in: context)
        let main = announce(in: page)
        let first = announce(in: page, main: false)
        let second = announce(in: page, main: false)
        #expect(tracked(page) == [main, first, second])

        page.invalidateCredentialContexts(documentID: first)
        #expect(tracked(page) == [main, second])

        page.invalidateCredentialContexts(documentID: main)
        page.invalidateCredentialContexts(documentID: second)
        #expect(coordinator.frames[ObjectIdentifier(page)] == nil, "a page with no documents left kept an empty list")

        withExtendedLifetime(session) {}
        await page.close()
        await context.endPrivateSession()
    }

    /// A navigation that has only started can still fail or become a download, and then the document it would have replaced
    /// is the one on screen. The frames stay until the page closes or a new main document announces itself.
    @Test func aNavigationThatHasOnlyStartedKeepsTheDocumentsOfThePage() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let (page, session) = makePage(in: context)
        let main = announce(in: page)

        page.invalidateCredentialContexts()
        #expect(tracked(page) == [main])

        let next = announce(in: page)
        #expect(tracked(page) == [next], "the next main document replaces the old ones")

        withExtendedLifetime(session) {}
        await page.close()
        #expect(tracked(page).isEmpty)
        await context.endPrivateSession()
    }
}
