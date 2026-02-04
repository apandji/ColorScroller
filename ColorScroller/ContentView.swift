// Your complete updated code here
import SwiftUI
import Combine
import UIKit
import AVFoundation
import os.lock


// MARK: - Models

enum BlockRarity: String, CaseIterable {
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
    var showDebugPanel: Bool = true
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

    private var isReady = false

    private init() {}

    func prepareIfNeeded() {
        guard !isReady else { return }
        isReady = true
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
        do { try engine.start() } catch {}
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

    @Published var currentUnlockToast: UnlockToast? = nil
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
        Skin(id: UUID(uuidString: "13131313-1313-1313-1313-131313131313")!, name: "Barcode Pop",   rarity: .special, style: .stripes(.black, .white)),
        Skin(id: UUID(uuidString: "14141414-1414-1414-1414-141414141414")!, name: "Candy Stripe",  rarity: .special, style: .stripes(.pink, .white)),
        Skin(id: UUID(uuidString: "15151515-1515-1515-1515-151515151515")!, name: "Night Dots",    rarity: .special, style: .dots(.black, .white)),
        Skin(id: UUID(uuidString: "16161616-1616-1616-1616-161616161616")!, name: "Confetti Dots", rarity: .special, style: .dots(.purple, .yellow))
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

        guard blocks.indices.contains(index) else { return }
        if let skin = blocks[index].skin {
            seenCountBySkinID[skin.id, default: 0] += 1
            attemptUnlock(skin: skin)
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

        if s < 70 {
            let t = Double(s - 55) / 15.0
            let rare = 0.20 + (0.30 - 0.20) * t
            return (0, 1.0 - rare, rare, 0)
        }

        if s < 85 {
            return (0, 0.70, 0.30, 0)
        }

        if !raresFullyUnlocked() {
            return (0, 0.70, 0.30, 0)
        }

        let t = min(1.0, max(0.0, Double(s - 85) / 10.0))
        let special = 0.10 * t
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

        let unlockedOfRarity = unlockedSkins.filter { $0.rarity == rarity }
        let lockedOfRarity = catalog.filter { !unlockedSkinIDs.contains($0.id) }

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

        if let pick = catalog.randomElement(using: &rng) {
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

        let now = Date()
        let cooldown = max(0, debug.toastCooldownSeconds)
        if cooldown == 0 || now.timeIntervalSince(lastToastTime) >= cooldown {
            lastToastTime = now
            currentUnlockToast = UnlockToast(rarity: skin.rarity, name: skin.name)

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_150_000_000)
                guard let self else { return }
                if self.currentUnlockToast?.name == skin.name {
                    self.currentUnlockToast = nil
                }
            }
        }
    }
}

// MARK: - Content View (Vertical paging only + Haptics)

struct ContentView: View {
    @StateObject private var vm = ScrollerViewModel()
    @State private var lastFeedbackIndex: Int = 0
    @State private var scrollPosition: Int? = 0
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    @State private var showInventory = false

    @State private var isTouching: Bool = false
    @State private var toneVolume: Double = 0.3

    private let minFreq: Double = 240
    private let maxFreq: Double = 5000

    @State private var currentFrequency: Double = 540
    @State private var nextStepAt: Int = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.blocks.enumerated()), id: \.element.id) { idx, item in
                            BlockView(item: item)
                                // ✅ exact paging units (fixes “less than full screen”)
                                .containerRelativeFrame(.horizontal, count: 1, spacing: 0)
                                .containerRelativeFrame(.vertical, count: 1, spacing: 0)
                                .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollPosition, anchor: .top)
                .onChange(of: scrollPosition) { _, newValue in
                    let idx = newValue ?? 0
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

                // --- Top overlays: counters ---
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
                        }
                        .padding(.trailing, 14)
                        .padding(.top, 10)
                    }
                    Spacer()
                }
                .zIndex(30)

                // --- Toast ---
                if let toast = vm.currentUnlockToast {
                    UnlockToastView(rarity: toast.rarity, name: toast.name)
                        .transition(.scale.combined(with: .opacity))
                        .zIndex(40)
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
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.currentUnlockToast)
            .sheet(isPresented: $showInventory) {
                InventoryView(unlocked: vm.unlockedSkins, seenCountBySkinID: vm.seenCountBySkinID)
            }
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

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background

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
            .padding(18)
            .foregroundStyle(.white)
            .shadow(radius: 8)
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
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .frame(width: 320)
    }
}

