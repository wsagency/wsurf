// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Network

/// A loopback HTTP server for WebKit integration tests. Routes are fixed so
/// tests cannot depend on the public network or a live service.
/// Network callbacks stay on `queue`; all state read by them is immutable.
nonisolated final class HTTPFixtureServer: @unchecked Sendable {
    struct Response: Sendable {
        let status: String
        let headers: [String: String]
        let body: Data
        var gate: ResponseGate?

        static func html(
            _ body: String,
            headers additionalHeaders: [String: String] = [:],
            gate: ResponseGate? = nil
        ) -> Response {
            var headers = additionalHeaders
            headers["Content-Type"] = "text/html; charset=utf-8"
            return Response(
                status: "200 OK",
                headers: headers,
                body: Data(body.utf8),
                gate: gate
            )
        }

        static func bytes(_ body: Data, contentType: String) -> Response {
            Response(
                status: "200 OK",
                headers: ["Content-Type": contentType],
                body: body
            )
        }

        static func download(_ body: Data, filename: String) -> Response {
            Response(
                status: "200 OK",
                headers: [
                    "Content-Disposition": "attachment; filename=\"\(filename)\"",
                    "Content-Type": "application/octet-stream",
                ],
                body: body
            )
        }

        static func redirect(to url: URL) -> Response {
            Response(status: "302 Found", headers: ["Location": url.absoluteString], body: Data())
        }

        fileprivate var encoded: Data {
            var fields = headers
            fields["Content-Length"] = String(body.count)
            fields["Connection"] = "close"
            let head = (["HTTP/1.1 \(status)"] + fields.map { "\($0): \($1)" })
                .joined(separator: "\r\n") + "\r\n\r\n"
            return Data(head.utf8) + body
        }
    }

    /// A request as the fixture read it: header names are lowercased, and the body is whatever arrived.
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    enum StartError: Error {
        case cancelled
        case invalidURL
        case missingPort
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "WSurf.tests.http-fixture")
    private let routes: [String: Response]
    private let waitsForBody: Bool
    private let respond: (@Sendable (Request) -> Response?)?

    private init(
        listener: NWListener,
        routes: [String: Response],
        waitsForBody: Bool,
        respond: (@Sendable (Request) -> Response?)?
    ) {
        self.listener = listener
        self.routes = routes
        self.waitsForBody = waitsForBody
        self.respond = respond
    }

    deinit {
        listener.cancel()
    }

    /// `waitsForBody` answers a request that has a body only after the body arrived, so closing the connection never cuts a POST off.
    /// Off by default: the other tests send no bodies, and their timing is left as it was.
    /// `respond` answers first, on the server's queue, for a test that needs state; nil falls back to `routes`.
    static func start(
        routes: [String: Response],
        waitsForBody: Bool = false,
        respond: (@Sendable (Request) -> Response?)? = nil
    ) async throws -> HTTPFixtureServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = HTTPFixtureServer(listener: listener, routes: routes, waitsForBody: waitsForBody, respond: respond)
        listener.newConnectionHandler = { [weak server] connection in
            server?.accept(connection)
        }

        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: StartError.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
        guard listener.port != nil else { throw StartError.missingPort }
        return server
    }

    func url(_ path: String = "/") throws -> URL {
        guard let port = listener.port else { throw StartError.missingPort }
        guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)") else {
            throw StartError.invalidURL
        }
        return url
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(from: connection, accumulated: Data())
    }

    private func receiveRequest(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = accumulated
            if let data {
                request.append(data)
            }
            let separator = request.range(of: Data("\r\n\r\n".utf8))
            let bodyPending = waitsForBody && separator.map { Self.bodyLength(ofHead: request[..<$0.lowerBound]) > request.count - $0.upperBound } == true
            guard (separator != nil && !bodyPending) || complete || error != nil else {
                receiveRequest(from: connection, accumulated: request)
                return
            }
            sendResponse(for: request, over: connection)
        }
    }

    /// The `Content-Length` of a request head, or 0 (a chunked body is not waited for).
    private static func bodyLength(ofHead head: Data) -> Int {
        let lines = String(decoding: head, as: UTF8.self).lowercased().split(separator: "\r\n")
        guard let line = lines.first(where: { $0.hasPrefix("content-length:") }) else { return 0 }
        return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func sendResponse(for request: Data, over connection: NWConnection) {
        let separator = request.range(of: Data("\r\n\r\n".utf8))
        let lines = String(decoding: request[..<(separator?.lowerBound ?? request.endIndex)], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let headers = lines.dropFirst().reduce(into: [String: String]()) { headers, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let received = Request(
            method: parts.first.map(String.init) ?? "",
            path: path,
            headers: headers,
            body: separator.map { Data(request[$0.upperBound...]) } ?? Data()
        )
        let response = respond?(received) ?? routes[path] ?? Response(
            status: "404 Not Found",
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<h1>Not found</h1>".utf8)
        )
        let send = { @Sendable in
            connection.send(content: response.encoded, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        if let gate = response.gate {
            gate.submit(send)
        } else {
            send()
        }
    }
}
