// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Darwin
import Foundation
import MCP
import Testing

@testable import WSurf

@Suite(.timeLimit(.minutes(1)))
struct MCPStdioTransportTests {
    @Test func pipeDeliversPartialAndCoalescedFramesAndFinishesAtEOF() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = MCPStdioTransport(
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor
        )
        try await transport.connect()
        try await transport.connect()
        var messages = await transport.receive().makeAsyncIterator()
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":".utf8))
        try input.fileHandleForWriting.write(contentsOf: Data("1}\n\n{\"id\":2}\nunfinished".utf8))
        #expect(try await messages.next() == Data("{\"id\":1}".utf8))
        #expect(try await messages.next() == Data("{\"id\":2}".utf8))
        try input.fileHandleForWriting.close()
        #expect(try await messages.next() == nil)
        await #expect(throws: MCPError.self) { try await transport.connect() }
        await #expect(throws: MCPError.self) { try await transport.send(Data()) }
        await transport.disconnect()
    }

    @Test func outputIsNewlineDelimitedAndDisconnectFinishesIdleInput() async throws {
        let input = Pipe()
        let output = Pipe()
        let inputDescriptor = input.fileHandleForReading.fileDescriptor
        let outputDescriptor = output.fileHandleForWriting.fileDescriptor
        let transport = MCPStdioTransport(input: inputDescriptor, output: outputDescriptor)
        try await transport.connect()
        try await transport.send(Data("{\"id\":3}".utf8))
        #expect(output.fileHandleForReading.availableData == Data("{\"id\":3}\n".utf8))
        var messages = await transport.receive().makeAsyncIterator()
        await transport.disconnect()
        await transport.disconnect()
        #expect(try await messages.next() == nil)
        #expect(fcntl(inputDescriptor, F_GETFD) >= 0)
        #expect(fcntl(outputDescriptor, F_GETFD) >= 0)
        await #expect(throws: MCPError.self) { try await transport.send(Data()) }
        await #expect(throws: MCPError.self) { try await transport.connect() }
    }

    @Test func duplicatedDescriptorsOutliveTheirCallersAndCloseAtDisconnect() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = MCPStdioTransport(
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor
        )
        try await transport.connect()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        var messages = await transport.receive().makeAsyncIterator()
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":4}\n".utf8))
        #expect(try await messages.next() == Data("{\"id\":4}".utf8))
        try await transport.send(Data("{\"id\":5}".utf8))
        #expect(output.fileHandleForReading.availableData == Data("{\"id\":5}\n".utf8))
        let outputEOF = Task.detached { try output.fileHandleForReading.readToEnd() }
        await transport.disconnect()
        #expect(try await outputEOF.value?.isEmpty != false)
    }

    @Test func oversizedInputFailsWithoutWaitingForANewline() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = MCPStdioTransport(
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor
        )
        try await transport.connect()
        let writer = Task.detached {
            try input.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: MCPMessageFramer.maximumBytes + 1))
        }
        await #expect(throws: MCPError.self) {
            for try await _ in await transport.receive() {}
        }
        try await writer.value
        await transport.disconnect()
    }

    @Test func pendingMessageOverflowFailsAndClosesOwnedOutput() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = MCPStdioTransport(
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor
        )
        try await transport.connect()
        try output.fileHandleForWriting.close()
        let outputEOF = Task.detached { try output.fileHandleForReading.readToEnd() }
        let frames = (0 ..< 65).map { "{\"id\":\($0)}\n" }.joined()
        try input.fileHandleForWriting.write(contentsOf: Data(frames.utf8))
        // Wait for shutdown before consuming, so the 64-message buffer really fills.
        #expect(try await outputEOF.value?.isEmpty != false)
        var received: [Data] = []
        do {
            for try await message in await transport.receive() {
                received.append(message)
            }
            Issue.record("Expected pending-message overflow")
        } catch MCPError.invalidRequest {
            #expect(received.count == 64)
            #expect(received.first == Data("{\"id\":0}".utf8))
            #expect(received.last == Data("{\"id\":63}".utf8))
        }
        await #expect(throws: MCPError.self) { try await transport.connect() }
    }

    @Test func cancellingAnIdleReceiverClosesOwnedDescriptors() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = MCPStdioTransport(
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor
        )
        try await transport.connect()
        try output.fileHandleForWriting.close()
        let outputEOF = Task.detached { try output.fileHandleForReading.readToEnd() }
        let messages = await transport.receive()
        let reader = Task {
            for try await _ in messages {}
        }
        reader.cancel()
        try await reader.value
        #expect(try await outputEOF.value?.isEmpty != false)
        await #expect(throws: MCPError.self) { try await transport.connect() }
        await #expect(throws: MCPError.self) { try await transport.send(Data()) }
    }

    @Test func disconnectCancelsAnInFlightWrite() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = MCPStdioTransport(
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor
        )
        try await transport.connect()
        let sent = Task { try await transport.send(Data(repeating: 65, count: 1_048_576)) }
        let firstByte = Task.detached { try output.fileHandleForReading.read(upToCount: 1) }
        #expect(try await firstByte.value == Data([65]))
        await transport.disconnect()
        await #expect(throws: (any Error).self) { try await sent.value }
    }

    @Test(arguments: [false, true])
    func releasingTransportWhileInputStaysOpen(_ disconnectFirst: Bool) async throws {
        let input = Pipe()
        let output = Pipe()
        weak var released: MCPStdioTransport?
        let messages: AsyncThrowingStream<Data, any Error>
        do {
            let transport = MCPStdioTransport(
                input: input.fileHandleForReading.fileDescriptor,
                output: output.fileHandleForWriting.fileDescriptor
            )
            released = transport
            try await transport.connect()
            messages = await transport.receive()
            if disconnectFirst {
                await transport.disconnect()
            }
        }
        #expect(await waitUntil { released == nil })
        var iterator = messages.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }
}
