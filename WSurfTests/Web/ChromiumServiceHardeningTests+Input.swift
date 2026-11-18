// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import CefKit
@testable import WSurf

extension ChromiumServiceHardeningTests {
    private static let inputOps = [CefRemote.Op.mouse, CefRemote.Op.key, CefRemote.Op.focus, CefRemote.Op.edit]

    private static func sendInputBatch(on client: ChromiumServiceClient) {
        for op in inputOps {
            let message = CefRemoteMessage(op, browser: 1)
            message.set(CefRemote.Key.kind, op == CefRemote.Op.edit ? "selectAll" : CefRemote.MouseKind.move)
            client.send(message)
        }
    }

    /// A reply on the sender's own connection is a barrier behind its input messages.
    private static func inputCount(on client: ChromiumServiceClient) throws -> Int64 {
        let reply = try client.call(CefRemoteMessage(CefRemote.Op.debugStats, browser: 1))
        try #require(reply.has(CefRemote.Key.inputEvents), "the browser exists and reported input statistics")
        return reply.int(CefRemote.Key.inputEvents)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func inputBeforeTheHostHelloStartsNothing() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        Self.sendInputBatch(on: client)
        let stats = try client.stats()
        #expect(!stats.bool(CefRemote.Key.started))
        #expect(stats.int(CefRemote.Key.count) == 0)
        #expect(stats.int(CefRemote.Key.contexts) == 0)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func onlyInputAndControlConnectionsCanSendInputAndClosingControlEndsThem() throws {
        let host = try ChromiumServiceClient()
        host.hostAnswersQuestions = true
        defer { host.finish() }
        try #require(try host.hello().bool(CefRemote.Key.success))
        try host.context("input-gate")
        try #require(try host.createBrowser(1, url: "about:blank", context: "input-gate").bool(CefRemote.Key.success))
        try #require(host.waitEvent(CefRemote.Event.browserReady) { $0.browser == 1 } != nil)
        try #require(try Self.inputCount(on: host) == 0)
        var peers: [ChromiumServiceClient] = []
        defer { peers.forEach { $0.close() } }
        for hello in [nil, CefRemote.Op.framesHello, CefRemote.Op.axHello] as [String?] {
            let peer = try ChromiumServiceClient(root: host.root)
            peers.append(peer)
            if let hello {
                try #require(try peer.call(CefRemoteMessage(hello)).bool(CefRemote.Key.success))
            }
            Self.sendInputBatch(on: peer)
            #expect(try Self.inputCount(on: peer) == 0, "\(hello ?? "unattached") cannot send input")
            if hello == nil {
                peer.close()
            }
        }
        // The control fallback and the attached input connection are positive controls over the same live browser.
        Self.sendInputBatch(on: host)
        #expect(try Self.inputCount(on: host) == Int64(Self.inputOps.count))
        let input = try ChromiumServiceClient(root: host.root)
        peers.append(input)
        try #require(try input.call(CefRemoteMessage(CefRemote.Op.inputHello)).bool(CefRemote.Key.success))
        Self.sendInputBatch(on: input)
        #expect(try Self.inputCount(on: input) == Int64(Self.inputOps.count * 2))

        let pid = try #require(host.pid)
        host.close()
        try #require(ChromiumServiceClient.secondsUntilGone(pid, within: 8) != nil)
        for peer in peers.dropFirst() {
            Self.sendInputBatch(on: peer)
            // A closed channel must fail, rather than return zero-valued statistics for a missing browser.
            do {
                _ = try peer.call(CefRemoteMessage(CefRemote.Op.debugStats, browser: 1), timeout: 1)
                Issue.record("a side connection still answered after its control connection and service ended")
            } catch is ChromiumServiceClient.Failure {
                // The service cancelled every attached peer; none can act on its old browser.
            }
        }
    }
}
