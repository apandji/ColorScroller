import Foundation
import SwiftUI

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

// MARK: - Seeded PRNG (splitmix64)

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
    mutating func bool() -> Bool {
        next() % 2 == 0
    }
    mutating func pick<T>(from array: [T]) -> T {
        array[int(in: 0...(array.count - 1))]
    }
}

// MARK: - Name Generator (adjective + noun, deterministic via PRNG)

enum SkinNameGenerator {

    private static let adjectives: [String] = [
        "Dusty", "Electric", "Frozen", "Velvet", "Solar",
        "Misty", "Neon", "Burnt", "Faded", "Deep",
        "Pale", "Wild", "Cosmic", "Warm", "Cool",
        "Soft", "Bold", "Hazy", "Vivid", "Silent",
        "Golden", "Silver", "Crystal", "Smoky", "Rustic",
        "Arctic", "Molten", "Twilight", "Shadow", "Lunar",
        "Silk", "Midnight", "Powder", "Honey", "Copper",
        "Marble", "Mossy", "Cloudy", "Dewy", "Glowing",
        "Muted", "Bright", "Sheer", "Gentle", "Fierce",
        "Dreamy", "Crisp", "Dusky", "Radiant", "Washed"
    ]

    private static let nouns: [String] = [
        "Coral", "Sage", "Dusk", "Ember", "Frost",
        "Bloom", "Storm", "Haze", "Slate", "Nectar",
        "Fern", "Plum", "Petal", "Ash", "Mist",
        "Dew", "Sky", "Moss", "Clay", "Smoke",
        "Pearl", "Opal", "Jade", "Rust", "Sand",
        "Shell", "Wave", "Breeze", "Flame", "Drift",
        "Stone", "Glow", "Reef", "Brook", "Pine",
        "Orchid", "Cedar", "Iris", "Luna", "Nova",
        "Flint", "Thistle", "Clover", "Dahlia", "Saffron",
        "Poppy", "Peony", "Willow", "Sparrow", "Lichen"
    ]

    /// Returns a deterministic name like "Frozen Ember" from the PRNG state.
    static func generate(rng: inout SeededPRNG) -> String {
        let adj = rng.pick(from: adjectives)
        let noun = rng.pick(from: nouns)
        return "\(adj) \(noun)"
    }
}

// MARK: - Palette Generator (behavior-seeded, thematically coherent)

enum PaletteGenerator {

    /// Generates a full batch of 10 skins (6 common, 3 rare, 1 special)
    /// anchored around a single hue neighborhood derived from behavior.
    static func generateBatch(seed: UInt64) -> [Skin] {
        var rng = SeededPRNG(seed: seed)
        var skins: [Skin] = []

        // --- Batch-wide palette parameters ---
        let anchorHue  = rng.double(in: 0.0...1.0)
        let satCenter  = rng.double(in: 0.50...0.90)
        let briCenter  = rng.double(in: 0.55...0.95)
        let hueSpread  = rng.double(in: 0.05...0.12)  // ±18°–43° in hue space

        // Helper: build a Color near the anchor with per-skin jitter
        func paletteColor(rng: inout SeededPRNG) -> Color {
            let h = (anchorHue + rng.double(in: -hueSpread...hueSpread))
                .truncatingRemainder(dividingBy: 1.0)
            let hue = h < 0 ? h + 1.0 : h
            let sat = max(0.0, min(1.0, satCenter + rng.double(in: -0.12...0.12)))
            let bri = max(0.0, min(1.0, briCenter + rng.double(in: -0.10...0.10)))
            return Color(hue: hue, saturation: sat, brightness: bri)
        }

        // --- 6 Commons (solid colors) ---
        for _ in 0..<6 {
            let name = SkinNameGenerator.generate(rng: &rng)
            let color = paletteColor(rng: &rng)
            skins.append(Skin(
                id: UUID(),
                name: name,
                rarity: .common,
                style: .solid(color)
            ))
        }

        // --- 3 Rares (gradients, 2–3 color stops) ---
        for _ in 0..<3 {
            let name = SkinNameGenerator.generate(rng: &rng)
            let stopCount = rng.bool() ? 2 : 3
            var stops: [Color] = []
            for _ in 0..<stopCount {
                stops.append(paletteColor(rng: &rng))
            }
            skins.append(Skin(
                id: UUID(),
                name: name,
                rarity: .rare,
                style: .gradient(stops)
            ))
        }

        // --- 1 Special (stripes, dots, SF Symbols, or emoji — palette-colored) ---
        let specialName = SkinNameGenerator.generate(rng: &rng)
        let colorA = paletteColor(rng: &rng)
        let colorB = paletteColor(rng: &rng)

        let sfSymbols = [
            "star.fill", "heart.fill", "moon.stars.fill", "bolt.fill",
            "flame.fill", "leaf.fill", "sparkle", "cloud.fill",
            "sun.max.fill", "drop.fill", "pawprint.fill", "snowflake"
        ]
        let emojis = [
            "😺", "🔥", "🌸", "✨", "🦋", "🍀",
            "💎", "🌙", "⭐️", "🫧", "🪷", "🎀"
        ]

        let specialVariant = rng.int(in: 0...3)
        let specialStyle: BlockStyle
        switch specialVariant {
        case 0:
            specialStyle = .stripes(colorA, colorB)
        case 1:
            specialStyle = .dots(colorA, colorB)
        case 2:
            let sym = rng.pick(from: sfSymbols)
            specialStyle = .symbols(sym, colorA, colorB)
        default:
            let em = rng.pick(from: emojis)
            specialStyle = .emoji(em, colorA)
        }

        skins.append(Skin(
            id: UUID(),
            name: specialName,
            rarity: .special,
            style: specialStyle
        ))

        return skins
    }
}
