// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

/// What goes into a record, and what comes back out of one.
struct SyncRecordCodecTests {
    private func tab(_ url: String = "https://example.test/", title: String = "Example") -> SessionNode {
        SessionNode(id: UUID(), title: title, url: url)
    }

    private func folder(_ title: String, _ children: [SessionNode]) -> SessionNode {
        SessionNode(id: UUID(), title: title, children: children)
    }

    private func sample() -> DeviceSessionPayload {
        DeviceSessionPayload(
            seq: 7,
            running: true,
            favorites: [tab("https://mail.test/", title: "Mail")],
            pins: [folder("Work", [tab("https://wiki.test/"), folder("Deep", [tab("https://deep.test/")])]), tab("https://news.test/")],
            windows: [
                SessionWindow(id: UUID(), nodes: [tab("https://a.test/"), folder("Read later", [tab("https://b.test/"), tab("https://c.test/")])]),
                SessionWindow(id: UUID(), nodes: [tab("https://d.test/")]),
            ],
            omittedTabs: 3
        )
    }

    /// The JSON inside a fitted record, as dictionaries.
    private func json(of payload: DeviceSessionPayload) throws -> [String: Any] {
        let record = try #require(SessionCodec.encodeFitted(payload))
        let raw = try (record as NSData).decompressed(using: .lzfse) as Data
        return try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    @Test func deviceInfoRoundTrips() throws {
        let info = DeviceInfo(name: "Ana’s iPhone", kind: .iphone, appVersion: "0.1.7")

        #expect(try SessionCodec.decodeDevice(SessionCodec.encode(info)) == info)
    }

    @Test func sessionPayloadRoundTrips() throws {
        let payload = sample()

        let record = try #require(SessionCodec.encodeFitted(payload))

        #expect(try SessionCodec.decodeSession(record) == payload)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let window = UUID().uuidString
        let node = UUID().uuidString
        let text = """
        {"seq":1,"running":true,"favorites":[],"pins":[],"omittedTabs":0,"future":{"a":1},
         "windows":[{"id":"\(window)","layout":"grid","nodes":[{"id":"\(node)","title":"T","url":"https://a.test/","icon":"x"}]}]}
        """
        let packed = try (Data(text.utf8) as NSData).compressed(using: .lzfse) as Data

        let decoded = try SessionCodec.decodeSession(packed)
        let again = try json(of: decoded)

        #expect(decoded.windows.first?.nodes.first?.url == "https://a.test/")
        #expect(again["future"] == nil)
        let windows = try #require(again["windows"] as? [[String: Any]])
        #expect(windows.first?["layout"] == nil)
    }

    @Test func unknownDeviceKindReadsAsOther() throws {
        let data = Data(#"{"name":"Headset","kind":"vision","appVersion":"2"}"#.utf8)

        #expect(try SessionCodec.decodeDevice(data).kind == .other)
    }

    @Test func recordsCarryOnlyTitlesLinksAndIDs() throws {
        let payload = sample()
        let top = try json(of: payload)
        let window = try #require((top["windows"] as? [[String: Any]])?.first)
        let nodes = try #require(window["nodes"] as? [[String: Any]])
        let leaf = try #require(nodes.first { $0["url"] != nil })
        let branch = try #require(nodes.first { $0["children"] != nil })
        let device = try #require(
            JSONSerialization.jsonObject(with: SessionCodec.encode(DeviceInfo(name: "n", kind: .mac, appVersion: "1"))) as? [String: Any]
        )

        #expect(Set(top.keys) == ["seq", "running", "favorites", "pins", "windows", "omittedTabs"])
        #expect(Set(window.keys) == ["id", "nodes"])
        #expect(Set(leaf.keys) == ["id", "title", "url"])
        #expect(Set(branch.keys) == ["id", "title", "children"])
        #expect(Set(device.keys) == ["name", "kind", "appVersion"])
    }

    @Test(arguments: [
        ("http://example.com/", true),
        ("HTTPS://example.com/a?b=c", true),
        ("file:///etc/hosts", false),
        ("data:text/html,hello", false),
        ("about:blank", false),
        ("javascript:alert(1)", false),
        ("wsurf://settings", false),
        ("https://", false),
        ("", false),
    ])
    func onlyWebLinksBecomeTabs(url: String, isWeb: Bool) {
        let node = SessionNode.tab(id: UUID(), title: "T", url: url)

        #expect((node != nil) == isWeb)
    }

    @Test func longTitlesAreShortenedAndLongLinksLeftOut() throws {
        let long = try #require(SessionNode.tab(id: UUID(), title: String(repeating: "é", count: 1_000), url: "https://example.test/"))
        let padded = try #require(SessionNode.tab(id: UUID(), title: "  \n Title \t", url: "https://example.test/"))
        let base = "https://example.test/"
        let atLimit = base + String(repeating: "a", count: SessionNode.maxURLBytes - base.utf8.count)
        let overLimit = atLimit + "a"

        #expect(long.title.count == 200)
        #expect(padded.title == "Title")
        #expect(SessionNode.tab(id: UUID(), title: "T", url: atLimit) != nil)
        #expect(SessionNode.tab(id: UUID(), title: "T", url: overLimit) == nil)
    }

    @Test func oversizedSessionDropsLooseTabsFromTheEnd() throws {
        func unique(_ index: Int) -> SessionNode {
            SessionNode(id: UUID(), title: UUID().uuidString, url: "https://example.test/\(UUID().uuidString)/\(index)")
        }
        let loose = (0..<100).map(unique)
        let folders = (0..<20).map { index in folder(UUID().uuidString, (0..<5).map { unique(index * 5 + $0) }) }
        let all = loose + folders
        let favorite = unique(900)
        let pin = unique(901)
        let payload = DeviceSessionPayload(
            running: true,
            favorites: [favorite],
            pins: [pin],
            windows: [SessionWindow(id: UUID(), nodes: all)]
        )

        let record = try #require(SessionCodec.encodeFitted(payload, budget: 4_096))
        let back = try SessionCodec.decodeSession(record)

        let kept = try #require(back.windows.first).nodes
        #expect(record.count <= 4_096)
        #expect(back.favorites == [favorite])
        #expect(back.pins == [pin])
        #expect(!kept.isEmpty && kept.count < all.count)
        #expect(kept == Array(all.prefix(kept.count)))
        #expect(back.omittedTabs + kept.reduce(0) { $0 + $1.tabCount } == 200)
    }

    @Test func sessionThatCannotFitIsNotEncoded() {
        let pins = (0..<200).map { SessionNode(id: UUID(), title: UUID().uuidString, url: "https://example.test/\(UUID().uuidString)/\($0)") }
        let payload = DeviceSessionPayload(
            running: true,
            favorites: [],
            pins: pins,
            windows: [SessionWindow(id: UUID(), nodes: [tab()])]
        )

        #expect(SessionCodec.encodeFitted(payload, budget: 1_024) == nil)
    }

    @Test func payloadBudgetLeavesHeadroomUnderTheRecordLimit() {
        #expect(SessionCodec.maxPayloadBytes <= 800_000)
    }

    @Test func remoteLinkOpensOnlyWebURLs() throws {
        func decoded(_ url: String) throws -> SessionNode {
            let text = #"{"id":"\#(UUID().uuidString)","title":"T","url":"\#(url)"}"#
            return try JSONDecoder().decode(SessionNode.self, from: Data(text.utf8))
        }

        #expect(try decoded("javascript:alert(1)").webURL == nil)
        #expect(try decoded("file:///etc/hosts").webURL == nil)
        #expect(try decoded("https://example.test/a").webURL == URL(string: "https://example.test/a"))
        #expect(folder("Folder", []).webURL == nil)
    }
}
