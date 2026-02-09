import Foundation

struct GeneratedSet: Identifiable, Equatable, Codable {
    let id: UUID
    let sourceRareID: UUID
    let timestamp: Date
    let seed: UInt64
    // Transient: not encoded/decoded
    let skins: [Skin]

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceRareID
        case timestamp
        case seed
        // intentionally no 'skins' key
    }

    init(id: UUID, sourceRareID: UUID, timestamp: Date, seed: UInt64, skins: [Skin]) {
        self.id = id
        self.sourceRareID = sourceRareID
        self.timestamp = timestamp
        self.seed = seed
        self.skins = skins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceRareID = try container.decode(UUID.self, forKey: .sourceRareID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        seed = try container.decode(UInt64.self, forKey: .seed)
        // provide empty skins on decode; caller can populate later
        skins = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceRareID, forKey: .sourceRareID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(seed, forKey: .seed)
        // intentionally skip 'skins'
    }
}

struct GeneratedSkinMeta: Codable, Equatable {
    let generatedFromSetID: UUID
    let rarity: BlockRarity
    let indexInSet: Int
}
