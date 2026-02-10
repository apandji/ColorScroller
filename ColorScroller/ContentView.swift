// Your complete updated code here
import SwiftUI
#if canImport(Combine)
import Combine
#endif
import UIKit
import AVFoundation
import os.lock

// MARK: - Models

enum BlockRarity: String, CaseIterable, Codable {
    case common, rare, special

    var label: String {
        switch self {
        case .common: return "COMMON"
        case .rare: return "RARE"
        case .special: return "SPECIAL"
        }
    }
}

enum BlockStyle: Equatable {
    case grayscale(Int)              // 0...100
    case solid(Color)                // common
    case gradient([Color])           // rare
    case stripes(Color, Color)       // special
    case dots(Color, Color)          // special
    case symbols(String, Color, Color) // special: SF Symbol name, symbol color, background
    case emoji(String, Color)          // special: emoji character(s), background color
}

/// A “skin” you can unlock (stable identity)
struct Skin: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let rarity: BlockRarity
    let style: BlockStyle

    static func == (lhs: Skin, rhs: Skin) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A feed item instance (unique per page) that *may* reference a skin.
struct FeedItem: Identifiable, Equatable {
    let id: UUID
    let skin: Skin?          // nil => monochrome
    let grayscale: Int?      // only used when skin == nil

    static func monochrome(_ shade: Int) -> FeedItem {
        FeedItem(id: UUID(), skin: nil, grayscale: shade)
    }

    static func fromSkin(_ skin: Skin) -> FeedItem {
        FeedItem(id: UUID(), skin: skin, grayscale: nil)
    }
}

// MARK: - Debug / Tuning

struct DebugTuning: Equatable {
    #if DEBUG
    var showDebugPanel: Bool = true
    #else
    var showDebugPanel: Bool = false
    #endif
    var toastCooldownSeconds: Double = 0.0
    var newUnlockChanceEarly: Double = 0.20
    var newUnlockChanceMid: Double = 0.12
    var newUnlockChanceLate: Double = 0.08
    var forceUnlockAll: Bool = false
}

// MARK: - Haptics (strong)

enum Haptics {
    static func swipe() {
        let gen = UIImpactFeedbackGenerator(style: .rigid)
        gen.prepare()
        gen.impactOccurred(intensity: 1.0)

        // second hit = feels "heavier" / more aggressive
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
            gen.prepare()
            gen.impactOccurred(intensity: 1.0)
        }
    }

    static func touch(intensity: CGFloat) {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        let clamped = max(0.0, min(1.0, intensity))
        gen.impactOccurred(intensity: clamped)
    }
}

// MARK: - Tone Player (minimal sine)

@MainActor
final class TonePlayer {
    static let shared = TonePlayer()

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    private var sampleRate: Double = 48_000
    private var phase: Double = 0

    // Shared state
    private var lock = os_unfair_lock_s()
    private var freq: Double = 440
    private var amp: Double = 0

    // Envelope state
    private var isOn: Bool = false
    private var envLevel: Double = 0
    private let attackTime: Double = 0.015
    private let releaseTime: Double = 0.10

    // Ding player (separate node so it doesn't conflict with the continuous tone)
    private var dingPlayer: AVAudioPlayerNode?
    private var dingBuffer: AVAudioPCMBuffer?

    private let readyLock = NSLock()
    private var isReady = false

    private init() {}

    func prepareIfNeeded() {
        readyLock.lock()
        guard !isReady else { readyLock.unlock(); return }
        isReady = true
        readyLock.unlock()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {}

        let format = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        let src = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }

            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in abl {
                for i in 0..<Int(frameCount) {
                    var sample: Float = 0

                    os_unfair_lock_lock(&self.lock)
                    let on = self.isOn
                    let f = self.freq
                    let a = self.amp
                    var level = self.envLevel
                    os_unfair_lock_unlock(&self.lock)

                    let atkInc = 1.0 / max(1.0, self.sampleRate * self.attackTime)
                    let relDec = 1.0 / max(1.0, self.sampleRate * self.releaseTime)

                    if on {
                        level = min(1.0, level + atkInc)
                    } else {
                        level = max(0.0, level - relDec)
                    }

                    let s = sin(self.phase) * a * level
                    sample = Float(s)

                    let inc = 2.0 * Double.pi * f / self.sampleRate
                    self.phase += inc
                    if self.phase > 2.0 * Double.pi { self.phase -= 2.0 * Double.pi }

                    let ptr = buffer.mData!.assumingMemoryBound(to: Float.self)
                    ptr[i] = sample

                    os_unfair_lock_lock(&self.lock)
                    self.envLevel = level
                    os_unfair_lock_unlock(&self.lock)
                }
            }

            return noErr
        }

        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
        source = src

        // Set up the ding player (separate node for one-shot chime)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        dingPlayer = player
        dingBuffer = Self.makeDingBuffer(sampleRate: sampleRate, format: format)

        do { try engine.start() } catch {}
    }

    /// Two-note ascending chime: E5 (659 Hz) → B5 (988 Hz), ~400ms
    private static func makeDingBuffer(sampleRate: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 0.40
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData else { return nil }
        let channels = Int(format.channelCount)

        let note1: Double = 659.0   // E5
        let note2: Double = 988.0   // B5
        var phase1: Double = 0
        var phase2: Double = 0

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate

            // Note 1 envelope: quick attack, 350ms decay
            let env1: Double
            if t < 0.008 { env1 = t / 0.008 }
            else { env1 = max(0, 1.0 - (t - 0.008) / 0.35) }

            // Note 2 starts 60ms later, same shape
            let t2 = t - 0.06
            let env2: Double
            if t2 < 0 { env2 = 0 }
            else if t2 < 0.008 { env2 = t2 / 0.008 }
            else { env2 = max(0, 1.0 - (t2 - 0.008) / 0.30) }

            let s1 = sin(phase1) * 0.18 * env1
            let s2 = sin(phase2) * 0.22 * env2
            let sample = Float(s1 + s2)

            phase1 += 2.0 * Double.pi * note1 / sampleRate
            phase2 += 2.0 * Double.pi * note2 / sampleRate

            for ch in 0..<channels {
                data[ch][frame] = sample
            }
        }
        return buffer
    }

    func ding() {
        prepareIfNeeded()
        guard engine.isRunning,
              let player = dingPlayer,
              let buffer = dingBuffer else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    func start(frequencyHz: Double, amplitude: Double) {
        prepareIfNeeded()
        guard engine.isRunning else { return }
        let clampedF = max(20, min(20_000, frequencyHz))
        os_unfair_lock_lock(&lock)
        freq = clampedF
        amp = max(0.0, min(1.0, amplitude))
        isOn = true
        os_unfair_lock_unlock(&lock)
    }

    func stop() {
        os_unfair_lock_lock(&lock)
        isOn = false
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - App State

@MainActor
final class ScrollerViewModel: ObservableObject {

    @Published var blocks: [FeedItem] = []
    @Published var seenCountBySkinID: [UUID: Int] = [:]

    @Published var unlockedSkins: [Skin] = []
    private var unlockedSkinIDs = Set<UUID>()

    @Published var blocksSeen: Int = 0
    @Published var totalBlocksViewed: Int = 0

    @Published var activeScrollSeconds: Double = 0
    @Published var isScrolling: Bool = false
    let sessionStart: Date = Date()

    @Published var currentUnlockToast: UnlockToast? = nil
    @Published var isUnlockPaused: Bool = false
    @Published var debug = DebugTuning()

    @Published var currentIndex: Int = 0

    private let pregenAhead = 14
    private let initialCount = 34

    private var rng = SystemRandomNumberGenerator()
    private var seenIndices = Set<Int>()
    private var lastGeneratedWasNewSkin: Bool = false
    private var commonsFullyUnlockedAtSeenCount: Int? = nil
    private var lastToastTime: Date = .distantPast

    struct UnlockToast: Equatable {
        let rarity: BlockRarity
        let name: String
    }

    // MARK: Catalogs (stable IDs)

    private let commonCatalog: [Skin] = [
        Skin(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Crimson",   rarity: .common,  style: .solid(.red)),
        Skin(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Tangerine", rarity: .common,  style: .solid(.orange)),
        Skin(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "Lemon",     rarity: .common,  style: .solid(.yellow)),
        Skin(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "Jade",    rarity: .common,  style: .solid(.green)),
        Skin(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, name: "Azure",     rarity: .common,  style: .solid(.blue)),
        Skin(id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, name: "Violet",    rarity: .common,  style: .solid(.purple)),
        Skin(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, name: "Magenta",   rarity: .common,  style: .solid(.pink)),
        Skin(id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!, name: "Mint",      rarity: .common,  style: .solid(.mint)),
        Skin(id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!, name: "Cyan",      rarity: .common,  style: .solid(.cyan)),
        Skin(id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!, name: "Indigo",    rarity: .common,  style: .solid(.indigo))
    ]

    private let rareCatalog: [Skin] = [
        Skin(id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!, name: "Sunrise",     rarity: .rare, style: .gradient([.orange, .pink])),
        Skin(id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!, name: "Ocean Glass", rarity: .rare, style: .gradient([.cyan, .indigo])),
        Skin(id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!, name: "Aurora",      rarity: .rare, style: .gradient([.green, .mint, .cyan])),
        Skin(id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!, name: "Grape Soda",  rarity: .rare, style: .gradient([.purple, .pink])),
        Skin(id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!, name: "Lava",        rarity: .rare, style: .gradient([.red, .orange, .yellow])),
        Skin(id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!, name: "Deep Space",  rarity: .rare, style: .gradient([.indigo, .purple, .black]))
    ]

    private let specialCatalog: [Skin] = [
        // Classic patterns
        Skin(id: UUID(uuidString: "13131313-1313-1313-1313-131313131313")!, name: "Barcode Pop",   rarity: .special, style: .stripes(.black, .white)),
        Skin(id: UUID(uuidString: "14141414-1414-1414-1414-141414141414")!, name: "Candy Stripe",  rarity: .special, style: .stripes(.pink, .white)),
        Skin(id: UUID(uuidString: "15151515-1515-1515-1515-151515151515")!, name: "Night Dots",    rarity: .special, style: .dots(.black, .white)),
        Skin(id: UUID(uuidString: "16161616-1616-1616-1616-161616161616")!, name: "Confetti Dots", rarity: .special, style: .dots(.purple, .yellow)),
        // SF Symbol patterns
        Skin(id: UUID(uuidString: "17171717-1717-1717-1717-171717171717")!, name: "Starfield",     rarity: .special, style: .symbols("star.fill", .yellow, .indigo)),
        Skin(id: UUID(uuidString: "18181818-1818-1818-1818-181818181818")!, name: "Heartbeat",     rarity: .special, style: .symbols("heart.fill", .pink, .black)),
        Skin(id: UUID(uuidString: "19191919-1919-1919-1919-191919191919")!, name: "Moonrise",      rarity: .special, style: .symbols("moon.stars.fill", .white, .indigo)),
        Skin(id: UUID(uuidString: "20202020-2020-2020-2020-202020202020")!, name: "Bolt Field",    rarity: .special, style: .symbols("bolt.fill", .orange, .black)),
        // Emoji patterns
        Skin(id: UUID(uuidString: "21212121-2121-2121-2121-212121212121")!, name: "Cat Party",     rarity: .special, style: .emoji("😺", .purple)),
        Skin(id: UUID(uuidString: "23232323-2323-2323-2323-232323232323")!, name: "Fire Walk",     rarity: .special, style: .emoji("🔥", .black)),
        Skin(id: UUID(uuidString: "24242424-2424-2424-2424-242424242424")!, name: "Bloom Garden",  rarity: .special, style: .emoji("🌸", .mint)),
        Skin(id: UUID(uuidString: "25252525-2525-2525-2525-252525252525")!, name: "Sparkle Night", rarity: .special, style: .emoji("✨", .indigo))
    ]

    init() {
        blocks = (0..<initialCount).map { _ in FeedItem.monochrome(Int.random(in: 5...95)) }
        ensurePregenIfNeeded(around: 0)
    }

    func tickActiveScrolling(dt: Double) {
        guard isScrolling else { return }
        activeScrollSeconds += dt
    }

    func onBecameVisible(index: Int) {
        totalBlocksViewed += 1

        if !seenIndices.contains(index) {
            seenIndices.insert(index)
            blocksSeen = max(blocksSeen, seenIndices.count)
        }

        var wasUnlock = false
        var skinRarity: BlockRarity? = nil

        if blocks.indices.contains(index), let skin = blocks[index].skin {
            skinRarity = skin.rarity
            wasUnlock = !unlockedSkinIDs.contains(skin.id)
            seenCountBySkinID[skin.id, default: 0] += 1
            attemptUnlock(skin: skin)
        }

        // Telemetry — passive, never blocks the UI
        BehaviorLogger.shared.logScroll(
            cardIndex: index,
            totalBlocksViewed: totalBlocksViewed,
            blocksSeen: blocksSeen,
            unlockedCount: unlockedSkins.count,
            activeScrollSeconds: activeScrollSeconds,
            sessionLengthSeconds: Date().timeIntervalSince(sessionStart),
            timeOfDayBucket: BehaviorSeed.timeOfDayBucket(),
            wasUnlock: wasUnlock,
            skinRarity: skinRarity
        )

        // Churn prediction → emergency dopamine
        let interventions = DopamineEngine.shared.evaluate(
            totalBlocksViewed: totalBlocksViewed,
            blocksSeen: blocksSeen,
            unlockedCount: unlockedSkins.count,
            activeScrollSeconds: activeScrollSeconds,
            sessionLengthSeconds: Date().timeIntervalSince(sessionStart),
            timeOfDayBucket: BehaviorSeed.timeOfDayBucket()
        )
        if !interventions.isEmpty {
            executeInterventions(interventions, around: index)
        }
    }

    /// Execute dopamine interventions triggered by churn prediction
    private func executeInterventions(_ interventions: Set<Intervention>, around index: Int) {
        if interventions.contains(.injectRare) {
            injectEmergencyReward(around: index)
        }
        if interventions.contains(.hapticBurst) {
            Haptics.touch(intensity: 0.6)
        }
        if interventions.contains(.chime) {
            TonePlayer.shared.ding()
        }
    }

    /// Replace the next 1–3 upcoming mono/common cards with locked rares/specials
    private func injectEmergencyReward(around index: Int) {
        // Find a locked skin to inject (prefer rares, fall back to specials)
        let allRares = rareCatalog + DynamicCatalogStore.shared.dynamicRares
        let lockedRares = allRares.filter { !unlockedSkinIDs.contains($0.id) }
        let allSpecials = specialCatalog + DynamicCatalogStore.shared.dynamicSpecials
        let lockedSpecials = allSpecials.filter { !unlockedSkinIDs.contains($0.id) }

        let pool = lockedRares.isEmpty ? lockedSpecials : lockedRares
        guard let reward = pool.randomElement(using: &rng) else { return }

        // Replace the next mono/common card within the next 3 positions
        for offset in 1...3 {
            let targetIdx = index + offset
            guard blocks.indices.contains(targetIdx) else { continue }
            let existing = blocks[targetIdx]
            // Only replace mono or common cards (don't stomp existing rares)
            if existing.skin == nil || existing.skin?.rarity == .common {
                blocks[targetIdx] = .fromSkin(reward)
                return  // one injection is enough
            }
        }
    }

    func ensurePregenIfNeeded(around index: Int) {
        let targetCount = max(blocks.count, index + pregenAhead + 1)
        if blocks.count < targetCount {
            appendBlocks(count: targetCount - blocks.count)
        }
        if index > blocks.count - pregenAhead - 2 {
            appendBlocks(count: pregenAhead)
        }
    }

    private func appendBlocks(count: Int) {
        for _ in 0..<count {
            blocks.append(generateFeedItem())
        }
    }

    private func raresFullyUnlocked() -> Bool {
        if debug.forceUnlockAll { return true }
        let allRareIDs = Set(rareCatalog.map(\.id))
        return unlockedSkinIDs.isSuperset(of: allRareIDs)
    }

    private func distribution(for seen: Int) -> (mono: Double, common: Double, rare: Double, special: Double) {
        let s = max(0, seen)

        // Once dynamic specials exist (from rare unlocks), give them a small
        // slice of the distribution so they can actually appear in the feed.
        let hasDynamicSpecials = !DynamicCatalogStore.shared.dynamicSpecials.isEmpty
        let earlySpecialWeight: Double = hasDynamicSpecials ? 0.05 : 0.0

        if s < 10 { return (1.0, 0, 0, 0) }
        if s < 30 { return (0.60, 0.40, 0, 0) }

        if s < 50 {
            let t = Double(s - 30) / 20.0
            let common = 0.40 + (0.90 - 0.40) * t
            return (1.0 - common, common, 0, 0)
        }

        if s < 55 { return (0, 1.0, 0, 0) }

        let raresAllowedByCommonGate: Bool = {
            if debug.forceUnlockAll { return true }
            guard let fullAt = commonsFullyUnlockedAtSeenCount else { return false }
            return s >= (fullAt + 10)
        }()

        if !raresAllowedByCommonGate {
            return (0, 1.0, 0, 0)
        }

        // Rares unlocked — specials can start appearing if dynamic specials exist
        if s < 70 {
            let t = Double(s - 55) / 15.0
            let rare = 0.20 + (0.30 - 0.20) * t
            return (0, 1.0 - rare - earlySpecialWeight, rare, earlySpecialWeight)
        }

        if s < 85 {
            return (0, 0.70 - earlySpecialWeight, 0.30, earlySpecialWeight)
        }

        if !raresFullyUnlocked() {
            return (0, 0.70 - earlySpecialWeight, 0.30, earlySpecialWeight)
        }

        // Full specials ramp (static + dynamic)
        let t = min(1.0, max(0.0, Double(s - 85) / 10.0))
        let special = max(earlySpecialWeight, 0.10 * t)
        let rare = 0.30 + (0.20 - 0.30) * t
        let common = 1.0 - special - rare
        return (0, common, rare, special)
    }

    private func pickRarityFromWeights(_ w: (mono: Double, common: Double, rare: Double, special: Double)) -> BlockRarity? {
        let roll = Double.random(in: 0...1, using: &rng)
        var acc = w.mono
        if roll < acc { return nil }
        acc += w.common
        if roll < acc { return .common }
        acc += w.rare
        if roll < acc { return .rare }
        return .special
    }

    private func newCandidateChance() -> Double {
        if debug.forceUnlockAll { return 0 }
        if blocksSeen < 30 { return debug.newUnlockChanceEarly }
        if blocksSeen < 70 { return debug.newUnlockChanceMid }
        return debug.newUnlockChanceLate
    }

    private func generateFeedItem() -> FeedItem {
        let w = distribution(for: blocksSeen)

        guard let rarity = pickRarityFromWeights(w) else {
            lastGeneratedWasNewSkin = false
            return .monochrome(Int.random(in: 5...95))
        }

        let catalog: [Skin] = {
            switch rarity {
            case .common: return commonCatalog
            case .rare: return rareCatalog
            case .special: return specialCatalog
            }
        }()

        let dynamicPool: [Skin] = {
            switch rarity {
            case .common: return DynamicCatalogStore.shared.dynamicCommons
            case .rare: return DynamicCatalogStore.shared.dynamicRares
            case .special: return DynamicCatalogStore.shared.dynamicSpecials
            }
        }()
        let allOfRarity: [Skin] = catalog + dynamicPool

        let unlockedOfRarity = allOfRarity.filter { unlockedSkinIDs.contains($0.id) }
        let lockedOfRarity = allOfRarity.filter { !unlockedSkinIDs.contains($0.id) }

        if lastGeneratedWasNewSkin {
            lastGeneratedWasNewSkin = false
            if let pick = unlockedOfRarity.randomElement(using: &rng) {
                return .fromSkin(pick)
            }
            return .monochrome(Int.random(in: 5...95))
        }

        let tryNew = (unlockedOfRarity.isEmpty || Double.random(in: 0...1, using: &rng) < newCandidateChance())

        if tryNew, let pick = lockedOfRarity.randomElement(using: &rng) {
            lastGeneratedWasNewSkin = true
            return .fromSkin(pick)
        }

        if let pick = unlockedOfRarity.randomElement(using: &rng) {
            lastGeneratedWasNewSkin = false
            return .fromSkin(pick)
        }

        if let pick = allOfRarity.randomElement(using: &rng) {
            lastGeneratedWasNewSkin = false
            return .fromSkin(pick)
        }

        lastGeneratedWasNewSkin = false
        return .monochrome(Int.random(in: 5...95))
    }

    private func attemptUnlock(skin: Skin) {
        guard !unlockedSkinIDs.contains(skin.id) else { return }
        unlockedSkinIDs.insert(skin.id)
        unlockedSkins.append(skin)

        if commonsFullyUnlockedAtSeenCount == nil {
            let allCommonIDs = Set(commonCatalog.map(\.id))
            if unlockedSkinIDs.isSuperset(of: allCommonIDs) {
                commonsFullyUnlockedAtSeenCount = blocksSeen
            }
        }

        // Inject behavior-driven generated set for STATIC rare unlocks only
        // (Dynamic rares don't trigger further generation — prevents infinite chain)
        let isStaticRare = skin.rarity == .rare && rareCatalog.contains(where: { $0.id == skin.id })
        if isStaticRare {
            let w = distribution(for: blocksSeen)
            let snap = BehaviorSnapshot(
                totalBlocksViewed: totalBlocksViewed,
                blocksSeen: blocksSeen,
                activeScrollSeconds: activeScrollSeconds,
                isScrolling: isScrolling,
                currentIndex: currentIndex,
                timeOfDayBucket: BehaviorSeed.timeOfDayBucket(),
                sessionLengthSeconds: Date().timeIntervalSince(sessionStart),
                rarityWeights: RarityWeights(
                    mono: w.mono, common: w.common, rare: w.rare, special: w.special
                ),
                sourceRareID: skin.id
            )
            let seed = BehaviorSeed.makeSeed(from: snap)
            let newSkins = PaletteGenerator.generateBatch(seed: seed)

            let set = GeneratedSet(id: UUID(), sourceRareID: skin.id, timestamp: Date(), seed: seed, skins: newSkins)
            DynamicCatalogStore.shared.inject(set: set, boostUntil: totalBlocksViewed + 100)
        }

        // Tell DopamineEngine about the unlock (resets drought counter)
        DopamineEngine.shared.recordUnlock(atViewCount: totalBlocksViewed)

        // --- Ding + pause so the player can appreciate the unlock ---
        TonePlayer.shared.ding()
        Haptics.touch(intensity: 0.9)

        isUnlockPaused = true
        let pauseDuration: UInt64 = 800_000_000 // 0.8s

        let now = Date()
        let cooldown = max(0, debug.toastCooldownSeconds)
        if cooldown == 0 || now.timeIntervalSince(lastToastTime) >= cooldown {
            lastToastTime = now
            currentUnlockToast = UnlockToast(rarity: skin.rarity, name: skin.name)

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: pauseDuration)
                guard let self else { return }
                self.isUnlockPaused = false
                // Keep toast visible a tiny bit longer than the pause
                try? await Task.sleep(nanoseconds: 400_000_000)
                if self.currentUnlockToast?.name == skin.name {
                    self.currentUnlockToast = nil
                }
            }
        } else {
            // Even without a toast, still pause briefly
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: pauseDuration)
                self?.isUnlockPaused = false
            }
        }
    }
}

// MARK: - Session Stats Persistence

enum SessionStats {
    private static let swipedKey  = "cs_lastSessionSwiped"
    private static let collectedKey = "cs_lastSessionCollected"

    static var lastSwiped: Int {
        UserDefaults.standard.integer(forKey: swipedKey)
    }
    static var lastCollected: Int {
        UserDefaults.standard.integer(forKey: collectedKey)
    }
    static func save(swiped: Int, collected: Int) {
        UserDefaults.standard.set(swiped, forKey: swipedKey)
        UserDefaults.standard.set(collected, forKey: collectedKey)
    }
}

// MARK: - Leaderboard Card

private struct LeaderboardEntry: Identifiable {
    let id: Int          // rank (1-based)
    let name: String
    let swiped: Int
    let collected: Int
    let isPlayer: Bool
}

struct LeaderboardCard: View {
    let lastSwiped: Int
    let lastCollected: Int

    @State private var livePulse = false
    @State private var chevronBounce = false

    // Internet-handle-style fake names
    private static let handles = [
        "void_echo", "pixel_drift", "static_hum", "neon_rain",
        "ghost_signal", "dead_scroll", "null_feed", "chrome_pulse",
        "blur_agent", "faded_loop", "lost_signal", "cold_pixel",
        "wave_rider", "night_code", "zero_bloom", "dark_scroll",
        "dim_feed", "raw_signal", "soft_glitch", "thin_static",
        "deep_haze", "flat_noise", "idle_current", "low_orbit"
    ]

    /// Seed changes every hour → leaderboard feels "live"
    private func hourSeed() -> UInt64 {
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        return UInt64(truncatingIfNeeded: hour) &* 2654435761
    }

    private var entries: [LeaderboardEntry] {
        var rng = SeededPRNG(seed: hourSeed())

        // Pick 7 unique handles
        var pool = Self.handles
        var names: [String] = []
        for _ in 0..<7 {
            let idx = rng.int(in: 0...(pool.count - 1))
            names.append(pool.remove(at: idx))
        }

        // Anchor fakes around the player's last session (min 200 so first-timers see activity)
        let anchor = max(lastSwiped, 200)
        var all: [(name: String, swiped: Int, collected: Int, isPlayer: Bool)] = []

        for name in names {
            let mult = rng.double(in: 0.3...3.5)
            let fakeSwiped = max(40, Int(Double(anchor) * mult))
            let fakeCollected = max(1, Int(Double(fakeSwiped) * rng.double(in: 0.012...0.045)))
            all.append((name, fakeSwiped, fakeCollected, false))
        }

        // Real player entry
        all.append(("You", lastSwiped, lastCollected, true))

        // Sort descending by swiped
        all.sort { $0.swiped > $1.swiped }

        return all.enumerated().map { idx, e in
            LeaderboardEntry(id: idx + 1, name: e.name, swiped: e.swiped, collected: e.collected, isPlayer: e.isPlayer)
        }
    }

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 0) {
                Spacer()

                // LIVE indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .opacity(livePulse ? 1.0 : 0.25)
                    Text("LIVE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        livePulse = true
                    }
                }
                .padding(.bottom, 10)

                Text("LEADERBOARD")
                    .font(.system(size: 26, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.bottom, 4)

                Text("colors scrolled")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 28)

                // Column headers
                HStack {
                    Text("#")
                        .frame(width: 26, alignment: .trailing)
                    Text("PLAYER")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                    Text("SWIPED")
                        .frame(width: 74, alignment: .trailing)
                    Text("FOUND")
                        .frame(width: 54, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.horizontal, 28)
                .padding(.bottom, 6)

                // Thin separator
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 4)

                // Entries
                ForEach(entries) { entry in
                    HStack {
                        Text("\(entry.id)")
                            .frame(width: 26, alignment: .trailing)
                            .foregroundStyle(entry.isPlayer ? .white : .white.opacity(0.35))

                        Text(entry.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                            .foregroundStyle(entry.isPlayer ? .white : .white.opacity(0.65))

                        Text(entry.swiped, format: .number)
                            .frame(width: 74, alignment: .trailing)
                            .foregroundStyle(entry.isPlayer ? .white : .white.opacity(0.5))

                        Text(entry.collected, format: .number)
                            .frame(width: 54, alignment: .trailing)
                            .foregroundStyle(entry.isPlayer ? .white : .white.opacity(0.4))
                    }
                    .font(.system(size: 14, weight: entry.isPlayer ? .bold : .regular, design: .monospaced))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 28)
                    .background {
                        if entry.isPlayer {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.07))
                                .padding(.horizontal, 20)
                        }
                    }
                }

                Spacer()

                // Swipe prompt
                VStack(spacing: 6) {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 24, weight: .semibold))
                        .offset(y: chevronBounce ? 4 : 0)
                    Text("swipe to begin")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.25))
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        chevronBounce = true
                    }
                }
                .padding(.bottom, 54)
            }
        }
    }
}

// MARK: - Content View (Vertical paging only + Haptics)

struct ContentView: View {
    @StateObject private var vm = ScrollerViewModel()
    @ObservedObject private var dopamine = DopamineEngine.shared
    @State private var lastFeedbackIndex: Int = -1
    @State private var scrollPosition: Int?          // nil = natural top (leaderboard)
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    @State private var showInventory = false

    @State private var isTouching: Bool = false
    @State private var toneVolume: Double = 0.3

    private let minFreq: Double = 240
    private let maxFreq: Double = 5000

    @State private var currentFrequency: Double = 540
    @State private var nextStepAt: Int = 0

    @State private var pillBounce: Bool = false

    var body: some View {
            ZStack {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        // Leaderboard is always the first card (id: -1)
                        LeaderboardCard(
                            lastSwiped: SessionStats.lastSwiped,
                            lastCollected: SessionStats.lastCollected
                        )
                        .containerRelativeFrame(.horizontal, count: 1, spacing: 0)
                        .containerRelativeFrame(.vertical, count: 1, spacing: 0)
                        .id(-1)

                        ForEach(Array(vm.blocks.enumerated()), id: \.element.id) { idx, item in
                            BlockView(item: item)
                                // ✅ exact paging units (fixes "less than full screen")
                                .containerRelativeFrame(.horizontal, count: 1, spacing: 0)
                                .containerRelativeFrame(.vertical, count: 1, spacing: 0)
                                .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollDisabled(vm.isUnlockPaused)
                .scrollPosition(id: $scrollPosition, anchor: .top)
                .onChange(of: scrollPosition) { _, newValue in
                    guard let idx = newValue, idx >= 0 else { return }  // nil or leaderboard — skip
                    vm.currentIndex = idx
                    vm.ensurePregenIfNeeded(around: idx)
                    vm.onBecameVisible(index: idx)

                    // Frequency advancement logic
                    let total = vm.totalBlocksViewed
                    if nextStepAt == 0 {
                        nextStepAt = Int.random(in: 10...15)
                    }
                    if total >= nextStepAt && currentFrequency < maxFreq {
                        currentFrequency += Double(Int.random(in: 30...90))
                        currentFrequency = min(currentFrequency, maxFreq)
                        if currentFrequency >= maxFreq {
                            nextStepAt = Int.max
                        } else {
                            nextStepAt = total + Int.random(in: 10...15)
                        }
                    }

                    // Update tone volume exponentially based on total blocks viewed
                    toneVolume = expVolume(for: total)

                    // If user is currently touching, update tone amplitude accordingly
                    if isTouching {
                        let freq = min(max(currentFrequency, minFreq), maxFreq)
                        let amp = min(1.0, max(0.05, toneVolume))
                        TonePlayer.shared.start(frequencyHz: freq, amplitude: amp)
                    }

                    // How many pages did we move? (handles fast flick jumps)
                    let delta = idx - lastFeedbackIndex
                    let steps = abs(delta)

                    guard steps > 0 else { return }

                    // Increase tone volume based on number of pages moved
                    let gainPerStep = 0.04
                    toneVolume = min(1.0, toneVolume + gainPerStep * Double(steps))
                    // Still provide a single haptic feedback for the change
                    Haptics.swipe()

                    lastFeedbackIndex = idx
                }

                .onScrollPhaseChange { _, phase in
                    vm.isScrolling = phase.isScrolling
                }
                .onReceive(tick) { _ in
                    vm.tickActiveScrolling(dt: 0.1)
                    vm.ensurePregenIfNeeded(around: vm.currentIndex)
                }
                .onReceive(NotificationCenter.default.publisher(for: .didInjectGeneratedSet)) { _ in
                    pillBounce = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pillBounce = false }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    SessionStats.save(swiped: vm.totalBlocksViewed, collected: vm.unlockedSkins.count)
                    BehaviorLogger.shared.logSessionEnd(
                        totalBlocksViewed: vm.totalBlocksViewed,
                        totalUnlocks: vm.unlockedSkins.count,
                        sessionLengthSeconds: Date().timeIntervalSince(vm.sessionStart)
                    )
                }
                .ignoresSafeArea()
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isTouching {
                                isTouching = true
                                Haptics.touch(intensity: 0.6)
                                let freq = min(max(currentFrequency, minFreq), maxFreq)
                                let amp = min(1.0, max(0.05, toneVolume))
                                TonePlayer.shared.start(frequencyHz: freq, amplitude: amp)
                            }
                        }
                        .onEnded { _ in
                            isTouching = false
                            Haptics.touch(intensity: 0.6)
                            TonePlayer.shared.stop()
                        }
                )

                // --- Top overlays: counters (hidden on leaderboard) ---
                VStack {
                    HStack {
                        HStack(spacing: 8) {
                            Text("Swiped")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text("\(vm.totalBlocksViewed)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.leading, 14)
                        .padding(.top, 10)

                        Spacer()

                        Button { showInventory = true } label: {
                            InventoryPill(unlockedCount: vm.unlockedSkins.count)
                                .scaleEffect(pillBounce ? 1.18 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.45), value: pillBounce)
                        }
                        .padding(.trailing, 14)
                        .padding(.top, 10)
                    }
                    Spacer()
                }
                .opacity((scrollPosition ?? -1) >= 0 ? 1 : 0)
                .animation(.easeInOut(duration: 0.35), value: scrollPosition)
                .zIndex(30)

                // --- Toast ---
                if let toast = vm.currentUnlockToast {
                    UnlockToastView(rarity: toast.rarity, name: toast.name)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.currentUnlockToast)
                        .zIndex(40)
                }

                // --- Gaslight Toast (churn intervention) ---
                if let msg = dopamine.currentGaslightMessage {
                    GaslightToastView(message: msg)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: dopamine.currentGaslightMessage)
                        .zIndex(35)
                }

                // --- Debug ---
                if vm.debug.showDebugPanel {
                    DebugPanel(vm: vm)
                        .padding(.leading, 12)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .zIndex(50)
                }
            }
            .onAppear {
                if nextStepAt == 0 {
                    nextStepAt = Int.random(in: 10...15)
                }
                currentFrequency = min(max(currentFrequency, minFreq), maxFreq)
            }
            .sheet(isPresented: $showInventory) {
                InventoryView(unlocked: vm.unlockedSkins, seenCountBySkinID: vm.seenCountBySkinID)
            }
    }

    private func easeOut(_ p: Double) -> Double { 1.0 - pow(1.0 - p, 2.0) }

    private func expVolume(for total: Int) -> Double {
        let cap = 500.0
        let x = min(Double(total), cap) / cap // 0..1
        let k = 4.0 // curvature; higher = more exponential
        let y = (exp(k * x) - 1.0) / (exp(k) - 1.0)
        return min(max(y, 0.0), 1.0)
    }
}

// MARK: - Block View

struct BlockView: View {
    let item: FeedItem
    @State private var chevronBounce = false

    var body: some View {
        ZStack {
            background

            // --- Color name label (bottom-leading) ---
            VStack(alignment: .leading, spacing: 6) {
                if let skin = item.skin {
                    Text(skin.rarity.label)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .opacity(0.9)
                    Text(skin.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .lineLimit(1)
                } else {
                    Text("DISCOVERY")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .opacity(0.9)
                    Text("Monochrome \(item.grayscale ?? 50)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 44)
            .foregroundStyle(.white)
            .shadow(radius: 8)

            // --- "keep scrolling" prompt (top-center, out of the way) ---
            VStack(spacing: 4) {
                Text("keep scrolling")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 18, weight: .semibold))
                    .offset(y: chevronBounce ? 3 : 0)
            }
            .foregroundStyle(.white.opacity(0.22))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 10)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    chevronBounce = true
                }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let skin = item.skin {
            switch skin.style {
            case .grayscale(let shade):
                Color(white: Double(shade)/100.0)
            case .solid(let c):
                c
            case .gradient(let cs):
                LinearGradient(colors: cs, startPoint: .topLeading, endPoint: .bottomTrailing)
            case .stripes(let a, let b):
                StripesPattern(colorA: a, colorB: b)
            case .dots(let a, let b):
                DotsPattern(dotColor: b, baseColor: a)
            case .symbols(let name, let symbolColor, let bg):
                SymbolScatterPattern(symbolName: name, symbolColor: symbolColor, baseColor: bg)
            case .emoji(let char, let bg):
                EmojiTilePattern(emoji: char, baseColor: bg)
            }
        } else {
            let shade = item.grayscale ?? 50
            Color(white: Double(shade)/100.0)
        }
    }
}

// MARK: - UI Bits

struct InventoryPill: View {
    let unlockedCount: Int
    var body: some View {
        HStack(spacing: 8) {
            Text("Unlocked")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("\(unlockedCount)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct UnlockToastView: View {
    let rarity: BlockRarity
    let name: String

    var body: some View {
        VStack(spacing: 10) {
            Text("NEW \(rarity.label)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .opacity(0.9)
            Text(name)
                .font(.system(size: 22, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(radius: 24)
    }
}

// MARK: - Gaslight Toast View

struct GaslightToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .strokeBorder(.green.opacity(0.4), lineWidth: 1)
                    )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 80)
    }
}

// MARK: - Patterns

struct StripesPattern: View {
    let colorA: Color
    let colorB: Color

    var body: some View {
        GeometryReader { geo in
            let stripeW: CGFloat = 18
            let count = Int(geo.size.width / stripeW) + 4

            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(i.isMultiple(of: 2) ? colorA : colorB)
                        .frame(width: stripeW)
                }
            }
            .rotationEffect(.degrees(-18))
            .frame(width: geo.size.width * 1.4, height: geo.size.height * 1.4)
            .position(x: geo.size.width/2, y: geo.size.height/2)
        }
    }
}

struct DotsPattern: View {
    let dotColor: Color
    let baseColor: Color

    var body: some View {
        ZStack {
            baseColor
            GeometryReader { geo in
                let spacing: CGFloat = 34
                let rows = Int(geo.size.height / spacing) + 3
                let cols = Int(geo.size.width / spacing) + 3

                Canvas { ctx, _ in
                    for r in 0..<rows {
                        for c in 0..<cols {
                            let x = CGFloat(c) * spacing + (r.isMultiple(of: 2) ? spacing/2 : 0)
                            let y = CGFloat(r) * spacing
                            let rect = CGRect(x: x, y: y, width: 10, height: 10)
                            ctx.fill(Path(ellipseIn: rect), with: .color(dotColor.opacity(0.85)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Symbol & Emoji Patterns

struct SymbolScatterPattern: View {
    let symbolName: String
    let symbolColor: Color
    let baseColor: Color

    var body: some View {
        ZStack {
            baseColor
            GeometryReader { geo in
                let spacing: CGFloat = 48
                let rows = Int(geo.size.height / spacing) + 3
                let cols = Int(geo.size.width / spacing) + 3

                Canvas { ctx, size in
                    guard let resolved = ctx.resolveSymbol(id: 0) else { return }
                    for r in 0..<rows {
                        for c in 0..<cols {
                            let x = CGFloat(c) * spacing + (r.isMultiple(of: 2) ? spacing / 2 : 0)
                            let y = CGFloat(r) * spacing
                            ctx.draw(resolved, at: CGPoint(x: x + 12, y: y + 12))
                        }
                    }
                } symbols: {
                    Image(systemName: symbolName)
                        .foregroundStyle(symbolColor.opacity(0.7))
                        .font(.system(size: 20))
                        .tag(0)
                }
            }
        }
    }
}

struct EmojiTilePattern: View {
    let emoji: String
    let baseColor: Color

    var body: some View {
        ZStack {
            baseColor
            GeometryReader { geo in
                let spacing: CGFloat = 52
                let rows = Int(geo.size.height / spacing) + 3
                let cols = Int(geo.size.width / spacing) + 3

                Canvas { ctx, size in
                    let resolved = ctx.resolve(Text(emoji).font(.system(size: 22)))
                    for r in 0..<rows {
                        for c in 0..<cols {
                            let x = CGFloat(c) * spacing + (r.isMultiple(of: 2) ? spacing / 2 : 0)
                            let y = CGFloat(r) * spacing
                            ctx.draw(resolved, at: CGPoint(x: x + 14, y: y + 14))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Inventory

struct InventoryView: View {
    let unlocked: [Skin]
    let seenCountBySkinID: [UUID: Int]
    @Environment(\.dismiss) private var dismiss

    private func sorted(_ skins: [Skin]) -> [Skin] {
        skins.sorted {
            let h0 = $0.representativeUIColor.hueValue
            let h1 = $1.representativeUIColor.hueValue
            if h0 != h1 { return h0 < h1 }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        let specials = sorted(unlocked.filter { $0.rarity == .special })
        let rares    = sorted(unlocked.filter { $0.rarity == .rare })
        let commons  = sorted(unlocked.filter { $0.rarity == .common })

        NavigationStack {
            List {
                if !specials.isEmpty {
                    Section("Special (\(specials.count))") {
                        ForEach(specials, id: \.id) { s in
                            InventoryRow(skin: s, seen: seenCountBySkinID[s.id, default: 0])
                        }
                    }
                }
                if !rares.isEmpty {
                    Section("Rare (\(rares.count))") {
                        ForEach(rares, id: \.id) { s in
                            InventoryRow(skin: s, seen: seenCountBySkinID[s.id, default: 0])
                        }
                    }
                }
                if !commons.isEmpty {
                    Section("Common (\(commons.count))") {
                        ForEach(commons, id: \.id) { s in
                            InventoryRow(skin: s, seen: seenCountBySkinID[s.id, default: 0])
                        }
                    }
                }
                if unlocked.isEmpty {
                    Section("Unlocked Skins (0)") {
                        Text("No skins yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Inventory")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct InventoryRow: View {
    let skin: Skin
    let seen: Int

    var body: some View {
        HStack(spacing: 12) {
            MiniSwatch(style: skin.style)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(skin.name).font(.headline)
                    Text("×\(seen)")
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }

                Text(skin.rarity.label)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .opacity(0.7)

                Text(skin.representativeUIColor.rgbString)
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct MiniSwatch: View {
    let style: BlockStyle
    var body: some View {
        switch style {
        case .grayscale(let s):
            Color(white: Double(s)/100.0)
        case .solid(let c):
            c
        case .gradient(let cs):
            LinearGradient(colors: cs, startPoint: .topLeading, endPoint: .bottomTrailing)
        case .stripes(let a, let b):
            StripesPattern(colorA: a, colorB: b)
        case .dots(let a, let b):
            DotsPattern(dotColor: b, baseColor: a)
        case .symbols(let name, let symbolColor, let bg):
            SymbolScatterPattern(symbolName: name, symbolColor: symbolColor, baseColor: bg)
        case .emoji(let char, let bg):
            EmojiTilePattern(emoji: char, baseColor: bg)
        }
    }
}

// MARK: - UIColor helpers (sorting + RGB subtitle)

private extension Skin {
    var representativeUIColor: UIColor {
        switch style {
        case .grayscale(let shade):
            return UIColor(white: CGFloat(shade) / 100.0, alpha: 1.0)
        case .solid(let c):
            return UIColor(c)
        case .gradient(let cs):
            if let first = cs.first { return UIColor(first) }
            return UIColor.systemGray
        case .stripes(let a, _):
            return UIColor(a)
        case .dots(let base, _):
            return UIColor(base)
        case .symbols(_, _, let bg):
            return UIColor(bg)
        case .emoji(_, let bg):
            return UIColor(bg)
        }
    }
}

private extension UIColor {
    var hueValue: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }

    var rgbString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let R = Int((r * 255.0).rounded())
        let G = Int((g * 255.0).rounded())
        let B = Int((b * 255.0).rounded())
        return "RGB \(R), \(G), \(B)"
    }
}

// MARK: - Debug UI

struct DebugPanel: View {
    @ObservedObject var vm: ScrollerViewModel
    @State private var showTelemetryDashboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DEBUG")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .opacity(0.85)
                Spacer()
                Button("Hide") { vm.debug.showDebugPanel = false }
                    .font(.system(size: 12, weight: .semibold))
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blocks seen (unique)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .opacity(0.7)
                    Text("\(vm.blocksSeen)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Swiped (total)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .opacity(0.7)
                    Text("\(vm.totalBlocksViewed)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
            }

            Toggle("Force unlock all", isOn: $vm.debug.forceUnlockAll)
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Toast cooldown")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .opacity(0.7)
                Slider(value: $vm.debug.toastCooldownSeconds, in: 0.0...6.0, step: 0.25)
                Text(String(format: "%.2fs", vm.debug.toastCooldownSeconds))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("New unlock chance (early / mid / late)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .opacity(0.7)
                Slider(value: $vm.debug.newUnlockChanceEarly, in: 0.00...0.40, step: 0.01)
                Slider(value: $vm.debug.newUnlockChanceMid, in: 0.00...0.30, step: 0.01)
                Slider(value: $vm.debug.newUnlockChanceLate, in: 0.00...0.20, step: 0.01)
                Text(String(format: "%.0f%% / %.0f%% / %.0f%%",
                            vm.debug.newUnlockChanceEarly * 100,
                            vm.debug.newUnlockChanceMid * 100,
                            vm.debug.newUnlockChanceLate * 100))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }

            HStack(spacing: 8) {
                Button("Export Telemetry") {
                    let urls = BehaviorLogger.shared.exportFileURLs()
                    guard !urls.isEmpty,
                          let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                          let root = scene.windows.first?.rootViewController else { return }
                    let ac = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                    root.present(ac, animated: true)
                }
                .font(.system(size: 12, weight: .semibold))

                Button("CloudKit Dashboard") {
                    showTelemetryDashboard = true
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.cyan)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .frame(width: 320)
        .sheet(isPresented: $showTelemetryDashboard) {
            TelemetryDashboardView()
        }
    }
}

