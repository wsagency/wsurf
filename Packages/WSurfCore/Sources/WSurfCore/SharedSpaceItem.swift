// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

nonisolated public enum SharedCatalogCategory: String, CaseIterable, Codable, Sendable {
    case profiles, spaces, pins

    public var zone: String { "shared-" + rawValue }
}

nonisolated struct SharedCatalogReceipt: Codable, Equatable {
    let submission: UUID
}

private nonisolated struct SharedCatalogPayload: Encodable {
    let item: SharedSpaceItem
    let receipt: SharedCatalogReceipt?

    func encode(to encoder: Encoder) throws {
        try item.encode(to: encoder)
        // The extra key is encrypted with the row. Older clients decode the original item fields.
        try receipt?.encode(to: encoder)
    }
}

/// One encrypted record per row. The record name is independent of its Space, parent, title, URL or window.
nonisolated public struct SharedSpaceItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case profile, space, folder, tab, pin, pinFolder
    }

    public let id: UUID
    public let kind: Kind
    public let profileID: UUID
    public var spaceID: UUID?
    /// A profile pin made from an already-shared tab. Kept in the pins category only.
    public var sharedTabID: UUID?
    public var parentID: UUID?
    public var order: String
    public var title: String
    public var url: String?
    public var customTitle: String?
    public var symbol: String?
    public var color: String?
    public var favorite: Bool
    public var removed: Bool

    public init(
        id: UUID, kind: Kind, profileID: UUID, spaceID: UUID? = nil, parentID: UUID? = nil, order: String = "",
        title: String = "", url: String? = nil, customTitle: String? = nil, symbol: String? = nil,
        color: String? = nil, favorite: Bool = false, removed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.profileID = profileID
        self.spaceID = spaceID
        self.parentID = parentID
        self.order = order
        self.title = title
        self.url = url
        self.customTitle = customTitle
        self.symbol = symbol
        self.color = color
        self.favorite = favorite
        self.removed = removed
    }

    public var category: SharedCatalogCategory {
        switch kind {
        case .profile:
            .profiles
        case .space, .tab, .folder:
            .spaces
        case .pin, .pinFolder:
            .pins
        }
    }

    public var recordID: SyncRecordID {
        SyncRecordID(zone: category.zone, name: id.uuidString)
    }

    public var tombstone: Self {
        Self(id: id, kind: kind, profileID: profileID, spaceID: spaceID, removed: true)
    }

    public func record(fields: Data?) -> SyncRecord? {
        record(fields: fields, receipt: nil)
    }

    func record(fields: Data?, receipt: SharedCatalogReceipt?) -> SyncRecord? {
        guard isValid, let payload = try? JSONEncoder().encode(SharedCatalogPayload(item: self, receipt: receipt)),
              payload.count <= SessionCodec.maxPayloadBytes else { return nil }
        return SyncRecord(id: recordID, type: category == .pins ? .sharedPin : .sharedSpaceItem, schema: 1, payload: payload, systemFields: fields)
    }

    public init?(record: SyncRecord) {
        guard record.schema == 1, record.payload.count <= SessionCodec.maxPayloadBytes,
              let item = try? JSONDecoder().decode(Self.self, from: record.payload),
              item.recordID == record.id, record.type == (item.category == .pins ? .sharedPin : .sharedSpaceItem), item.isValid
        else { return nil }
        self = item
    }

    private var isValid: Bool {
        guard parentID != id, spaceID != id, sharedTabID == nil || kind == .pin, order.utf8.count <= 512,
              order.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { return false }
        switch kind {
        case .profile:
            return id == profileID && spaceID == nil && parentID == nil && url == nil
        case .space:
            return spaceID == nil && parentID == nil && url == nil
        case .folder:
            return spaceID != nil && url == nil
        case .tab:
            guard spaceID != nil else { return false }
        case .pinFolder:
            return spaceID == nil && url == nil
        case .pin:
            guard spaceID == nil else { return false }
        }
        if removed {
            return url == nil
        }
        guard let url else { return false }
        return SessionNode.tab(id: id, title: title, url: url) != nil
    }
}
