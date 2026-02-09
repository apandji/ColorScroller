import Foundation

struct RarityWeights: Codable, Equatable {
    let mono: Double
    let common: Double
    let rare: Double
    let special: Double
}

struct BehaviorSnapshot: Codable, Equatable {
    let totalBlocksViewed: Int
    let blocksSeen: Int
    let activeScrollSeconds: Double
    let isScrolling: Bool
    let currentIndex: Int
    let timeOfDayBucket: Int // 0..3
    let sessionLengthSeconds: Double
    let rarityWeights: RarityWeights
    let sourceRareID: UUID
}

enum BehaviorSeed {
    static func timeOfDayBucket(for date: Date = Date()) -> Int {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 6..<12: return 0 // morning
        case 12..<18: return 1 // afternoon
        case 18..<24: return 2 // evening
        default: return 3 // night
        }
    }

    static func makeSeed(from snap: BehaviorSnapshot) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(snap.totalBlocksViewed)
        hasher.combine(snap.blocksSeen)
        hasher.combine(snap.activeScrollSeconds.bitPattern)
        hasher.combine(snap.isScrolling)
        hasher.combine(snap.currentIndex)
        hasher.combine(snap.timeOfDayBucket)
        hasher.combine(snap.sessionLengthSeconds.bitPattern)
        hasher.combine(snap.rarityWeights.mono.bitPattern)
        hasher.combine(snap.rarityWeights.common.bitPattern)
        hasher.combine(snap.rarityWeights.rare.bitPattern)
        hasher.combine(snap.rarityWeights.special.bitPattern)
        hasher.combine(snap.sourceRareID)
        let h = hasher.finalize()
        return UInt64(bitPattern: Int64(h))
    }
}

struct SeededPRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func double(in range: ClosedRange<Double>) -> Double {
        let x = Double(next()) / Double(UInt64.max)
        return range.lowerBound + (range.upperBound - range.lowerBound) * x
    }
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let x = Double(next()) / Double(UInt64.max)
        return range.lowerBound + Int(Double(range.count - 1) * x + 0.5)
    }
}
