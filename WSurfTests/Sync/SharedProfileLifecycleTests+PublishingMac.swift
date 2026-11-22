// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfCore

extension SharedProfileLifecycleTests {
    @Test func bothProfileCatalogsKeepThePublishingMacAcrossTheWire() throws {
        let id = UUID()
        let item = SharedSpaceItem(id: id, kind: .profile, profileID: id, title: "Work")
        let card = VaultProfileCard(name: "Work", symbol: "briefcase", color: "blue")

        func check<Row: Codable>(_ original: Row) throws {
            let encoded = try JSONEncoder().encode(original)
            var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let long = String(repeating: "č", count: 140)
            for (name, expected) in [("  Studio\nMac  ", "Studio Mac"), ("Katin MacBook Air", "Katin MacBook Air"), (long, String(long.prefix(64)))] {
                fields["publicationSource"] = ["macName": name]
                let received = try JSONDecoder().decode(Row.self, from: JSONSerialization.data(withJSONObject: fields))
                let saved = try JSONEncoder().encode(received)
                let restored = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
                #expect((restored["publicationSource"] as? [String: String])?["macName"] == expected)
            }
            let legacy = try JSONDecoder().decode(Row.self, from: encoded)
            let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
            #expect(saved["publicationSource"] == nil)
        }

        try check(item)
        try check(card)
    }

    @Test func sameNamedProfilesKeepTheirPublishingMacWhenLinkedOrRepublished() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        func mac(_ name: String, profile: Profile) -> CloudSharedSpaces {
            let pins = ProfilePinStore.store(for: .temporary())
            let host = CloudSharedSpaces(stateFile: root.appending(path: name + ".json"), profiles: [profile], windows: { [] },
                                         computerName: { name }, spaces: { _ in nil }, pins: { _ in pins })
            host.attach(FakeSyncEngine(cloud: cloud, delegate: host.catalog))
            return host
        }
        let id = UUID()
        let oldJSON = #"{"id":"\#(id.uuidString)","name":"Work","symbol":"person","color":"blue"}"#
        let upgraded = try JSONDecoder().decode(Profile.self, from: Data(oldJSON.utf8))
        let other = Profile(id: UUID(), name: "Work", symbol: "person", color: .teal)
        let local = Profile(id: UUID(), name: "Local", symbol: "person", color: .gray)
        let studio = mac("Studio", profile: upgraded), air = mac("Air", profile: other), pro = mac("Pro", profile: local)
        let firstID = try await studio.publishProfile(upgraded)
        await studio.refresh()
        let secondID = try await air.publishProfile(other)
        await air.refresh()
        try await pro.enable(.profiles, for: local)

        let list = pro.available(.profiles, for: local)
        #expect(firstID != secondID && Set(list.map(\.id)) == [firstID, secondID])
        let titles = Set(list.map { ProfileSummary.publishedName($0.title, source: $0.publicationSource) })
        #expect(titles.contains("Work — Studio") && titles.contains("Work — Air"))
        let selected = try #require(list.first { $0.id == firstID })
        try await pro.joinProfile(selected, in: local)
        _ = try await pro.publishProfile(local)
        await pro.refresh()
        let persisted = try #require(cloud.record(selected.recordID).flatMap(SharedSpaceItem.init(record:)))
        #expect(persisted.publicationSource?.macName == "Studio")
        #expect(ProfileSummary.displayName(for: local, sharedSpaces: pro, vaults: nil) == "Local — Studio")
        #expect(ProfileSummary.displayName(for: upgraded, sharedSpaces: studio, vaults: nil) == "Work — Studio")

        let next = CloudProfileInstance(.shared, id: UUID(), owner: cloud.user)
        try pro.replaceInstance(for: local, with: next)
        await pro.refresh()
        let replacement = try #require(pro.catalog.item(next.id, in: .profiles))
        #expect(replacement.publicationSource?.macName == "Pro")
        #expect(ProfileSummary.displayName(for: local, sharedSpaces: pro, vaults: nil) == "Local — Pro")
    }

    @Test func aReceivingMacDoesNotClaimAnUnattributedProfileOrLink() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        let legacy = UUID(), unpublished = UUID()
        let row = SharedSpaceItem(id: legacy, kind: .profile, profileID: legacy, title: "Work")
        cloud.createZone(SharedCatalogCategory.profiles.zone)
        _ = cloud.save(try #require(row.record(fields: nil)))
        for id in [legacy, unpublished] {
            let profile = Profile(id: UUID(), name: "Local", symbol: "person", color: .gray)
            let pins = ProfilePinStore.store(for: .temporary())
            let host = CloudSharedSpaces(stateFile: root.appending(path: id.uuidString), profiles: [profile], windows: { [] },
                                         computerName: { "Receiver" }, spaces: { _ in nil }, pins: { _ in pins })
            host.attach(FakeSyncEngine(cloud: cloud, delegate: host.catalog))
            try await host.enable(.profiles, for: profile)
            try #require(host.linkProfile(profile.id, to: id))
            _ = try await host.publishProfile(profile)
            await host.refresh()
            let saved = try #require(host.catalog.item(id, in: .profiles))
            #expect(saved.publicationSource?.macName == nil)
            #expect(ProfileSummary.displayName(for: profile, sharedSpaces: host, vaults: nil) == "Local")
        }
    }

    @Test func adoptedVaultProfilesKeepTheSourceThroughEditingRestartAndNewPublication() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "profiles.json")
        let store = ProfileStore(file: file)
        let source = ProfilePublicationSource(macName: "Studio")
        for incoming: ProfilePublicationSource? in [nil, source] {
            let profile = try #require(store.adopt(id: UUID(), name: "Work", symbol: "person", color: .gray, publicationSource: incoming))
            store.rename(profile, to: "Other name")
            store.setAppearance(of: profile, symbol: "briefcase", color: .teal)
            let reopened = ProfileStore(file: file)
            let saved = try #require(reopened.profiles.first { $0.id == profile.id })
            let host = CredentialVaultSyncHost(profiles: { reopened.profiles }, computerName: { "Receiver" })
            let card = try #require(host.profileCard(profileID: profile.id))
            #expect(card.name == "Other name" && card.publicationSource == incoming)
            #expect(saved.name == "Other name")
            let title = ProfileSummary.displayName(for: saved, sharedSpaces: nil, vaults: nil)
            #expect(title == (incoming == nil ? "Other name" : "Other name — Studio"))
        }
    }

    @Test func aSecondVaultKeepsThePublisherOfItsProfileInstance() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let (studio, _) = try rig.mac()
        let instance = UUID(), sameName = UUID()
        let source = ProfilePublicationSource(macName: "Studio"), otherSource = ProfilePublicationSource(macName: "Air")
        studio.sync.profileInstance = { profile, _ in profile == rig.profile ? instance : nil }
        studio.host.addProfile(rig.profile, name: "Work", source: source)
        try await studio.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await studio.pump()
        studio.host.addProfile(sameName, name: "Work", source: otherSource)
        let separateVault = try studio.host.addVault(profile: sameName)
        try await studio.sync.enable(profileID: sameName, vaultID: separateVault.vaultID)
        try await studio.pump()

        let reader = SimulatedMac(cloud: rig.cloud, root: rig.root.appending(path: "peer"))
        reader.start()
        try await reader.engine.fetchNow()
        let found = reader.sync.remoteProfiles()
        #expect(Set(found.map { ProfileSummary.publishedName($0.card.name, source: $0.card.publicationSource) }) == ["Work — Studio", "Work — Air"])
        reader.host.addProfile(rig.profile, name: "Work", source: ProfilePublicationSource(macName: "Peer"))
        reader.sync.profileInstance = { _, _ in instance }
        let second = try reader.host.addVault(profile: rig.profile)
        try await reader.sync.enable(profileID: rig.profile, vaultID: second.vaultID)
        try await reader.pump()
        let zone = SyncZone.vault(profileID: rig.profile, vaultID: second.vaultID, instanceID: instance)
        let cloudRecord = try #require(rig.cloud.record(.init(zone: zone, name: VaultSync.vaultRecordName)))
        let payload = try #require(VaultRecordPayload.decode(cloudRecord.payload))
        #expect(payload.profile.publicationSource == source)
        #expect(reader.sync.publicationSource(for: rig.profile) == source)
    }
}
