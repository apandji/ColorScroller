import Foundation
import Combine

// MARK: - ScrollSnapshot
//
// A feature vector computed from the recent scroll history.
// Fed to the ChurnPredictor on every scroll event.

struct ScrollSnapshot {
    let totalBlocksViewed: Int
    let blocksSeen: Int
    let unlockedCount: Int
    let blocksSinceLastUnlock: Int
    let activeScrollSeconds: Double
    let sessionLengthSeconds: Double
    let timeOfDayBucket: Int

    // Derived features (computed from rolling window)
    let scrollVelocity: Double        // cards/second over last 10 events
    let velocityTrend: Double         // slope of velocity (negative = slowing down)
    let unlockDensity: Double         // unlocks per 100 cards viewed
    let rewardDrought: Double         // normalized drought (blocksSinceLastUnlock / totalBlocksViewed)
}

// MARK: - ChurnPredictor Protocol
//
// Swappable brain: ships with HeuristicChurnPredictor on Wednesday,
// replaced by MLChurnPredictor once training data is collected.

protocol ChurnPredictor {
    func churnProbability(for snapshot: ScrollSnapshot) -> Double
}

// MARK: - HeuristicChurnPredictor
//
// Rule-based churn prediction using the strongest behavioral signals:
// 1. Reward drought — the longer since last unlock, the higher churn risk
// 2. Velocity trend — slowing down = losing interest
// 3. Session fatigue — engagement drops over time
// 4. Engagement depth — very early users churn differently than deep users

struct HeuristicChurnPredictor: ChurnPredictor {

    func churnProbability(for s: ScrollSnapshot) -> Double {
        var risk: Double = 0

        // 1. Reward drought (strongest signal)
        //    0 cards since unlock → 0.0, 15+ cards → 0.4
        let droughtScore = min(1.0, Double(s.blocksSinceLastUnlock) / 15.0) * 0.40
        risk += droughtScore

        // 2. Velocity trend (slowing down = losing interest)
        //    Negative trend → higher risk, up to 0.25
        if s.velocityTrend < 0 {
            risk += min(0.25, abs(s.velocityTrend) * 0.5)
        }

        // 3. Session fatigue
        //    After 3 minutes, fatigue starts accumulating, caps at 0.20
        let fatigueMinutes = max(0, s.sessionLengthSeconds - 180) / 60.0
        risk += min(0.20, fatigueMinutes * 0.04)

        // 4. Low engagement depth bonus
        //    Users who haven't unlocked much are more likely to churn
        if s.unlockedCount < 3 && s.totalBlocksViewed > 20 {
            risk += 0.10
        }

        // 5. Very slow absolute velocity → about to put the phone down
        if s.scrollVelocity < 0.3 && s.totalBlocksViewed > 10 {
            risk += 0.10
        }

        return min(1.0, max(0.0, risk))
    }
}

// MARK: - MLChurnPredictor (placeholder)
//
// Swap in post-exhibition once the .mlmodel is trained.
// Drop ChurnModel.mlmodel into the project, uncomment, and set
// DopamineEngine.shared.predictor = MLChurnPredictor()
//
// struct MLChurnPredictor: ChurnPredictor {
//     private let model = try! ChurnModel(configuration: .init())
//
//     func churnProbability(for s: ScrollSnapshot) -> Double {
//         let input = ChurnModelInput(
//             blocksSinceLastUnlock: Double(s.blocksSinceLastUnlock),
//             scrollVelocity: s.scrollVelocity,
//             velocityTrend: s.velocityTrend,
//             sessionLengthSeconds: s.sessionLengthSeconds,
//             unlockedCount: Double(s.unlockedCount),
//             totalBlocksViewed: Double(s.totalBlocksViewed),
//             unlockDensity: s.unlockDensity,
//             timeOfDayBucket: Double(s.timeOfDayBucket)
//         )
//         guard let output = try? model.prediction(input: input) else { return 0.5 }
//         return output.churnProbability
//     }
// }

// MARK: - Intervention
//
// What the DopamineEngine can do when churn risk is high.

enum Intervention: CaseIterable {
    case injectRare          // force a rare/special into next few cards
    case hapticBurst         // surprise strong haptic pattern
    case chime               // play the pleasant ding
    case leaderboardGaslight // "You just passed pixel_drift!"
}

// MARK: - DopamineEngine
//
// Runs on every scroll event. When P(churn) crosses the threshold,
// fires one or more interventions to pull the user back in.
//
// Cooldown prevents intervention fatigue (at most once every 12 cards).

@MainActor
final class DopamineEngine: ObservableObject {
    static let shared = DopamineEngine()

    var predictor: ChurnPredictor = HeuristicChurnPredictor()

    @Published var currentGaslightMessage: String? = nil
    @Published var lastChurnProbability: Double = 0

    private let churnThreshold: Double = 0.55
    private let cooldownCards: Int = 12
    private var lastInterventionAt: Int = 0

    // Rolling window for velocity computation
    private var recentTimestamps: [Double] = []
    private var recentVelocities: [Double] = []
    private let windowSize = 10

    private var lastUnlockAtViewCount: Int = 0

    // Fake player names for gaslighting
    private let handles = [
        "void_echo", "pixel_drift", "static_hum", "neon_rain",
        "ghost_signal", "dead_scroll", "null_feed", "chrome_pulse",
        "blur_agent", "faded_loop", "lost_signal", "cold_pixel"
    ]

    private init() {}

    // MARK: - Track unlocks (call from attemptUnlock)

    func recordUnlock(atViewCount: Int) {
        lastUnlockAtViewCount = atViewCount
    }

    // MARK: - Evaluate (call from onBecameVisible)
    //
    // Returns the set of interventions to fire (may be empty).

    func evaluate(
        totalBlocksViewed: Int,
        blocksSeen: Int,
        unlockedCount: Int,
        activeScrollSeconds: Double,
        sessionLengthSeconds: Double,
        timeOfDayBucket: Int
    ) -> Set<Intervention> {

        let now = Date().timeIntervalSince1970
        recentTimestamps.append(now)
        if recentTimestamps.count > windowSize {
            recentTimestamps.removeFirst()
        }

        // Compute velocity (cards/second)
        let velocity: Double = {
            guard recentTimestamps.count >= 2 else { return 1.0 }
            let dt = recentTimestamps.last! - recentTimestamps.first!
            guard dt > 0 else { return 1.0 }
            return Double(recentTimestamps.count) / dt
        }()

        recentVelocities.append(velocity)
        if recentVelocities.count > windowSize {
            recentVelocities.removeFirst()
        }

        // Compute velocity trend (linear regression slope)
        let trend: Double = {
            guard recentVelocities.count >= 3 else { return 0 }
            let n = Double(recentVelocities.count)
            let xs = (0..<recentVelocities.count).map { Double($0) }
            let meanX = xs.reduce(0, +) / n
            let meanY = recentVelocities.reduce(0, +) / n
            var num = 0.0
            var den = 0.0
            for i in 0..<recentVelocities.count {
                let dx = xs[i] - meanX
                let dy = recentVelocities[i] - meanY
                num += dx * dy
                den += dx * dx
            }
            return den > 0 ? num / den : 0
        }()

        let blocksSinceLastUnlock = totalBlocksViewed - lastUnlockAtViewCount
        let unlockDensity = totalBlocksViewed > 0
            ? (Double(unlockedCount) / Double(totalBlocksViewed)) * 100
            : 0
        let rewardDrought = totalBlocksViewed > 0
            ? Double(blocksSinceLastUnlock) / Double(totalBlocksViewed)
            : 0

        let snapshot = ScrollSnapshot(
            totalBlocksViewed: totalBlocksViewed,
            blocksSeen: blocksSeen,
            unlockedCount: unlockedCount,
            blocksSinceLastUnlock: blocksSinceLastUnlock,
            activeScrollSeconds: activeScrollSeconds,
            sessionLengthSeconds: sessionLengthSeconds,
            timeOfDayBucket: timeOfDayBucket,
            scrollVelocity: velocity,
            velocityTrend: trend,
            unlockDensity: unlockDensity,
            rewardDrought: rewardDrought
        )

        let p = predictor.churnProbability(for: snapshot)
        lastChurnProbability = p

        // Check threshold + cooldown
        guard p >= churnThreshold else { return [] }
        guard (totalBlocksViewed - lastInterventionAt) >= cooldownCards else { return [] }

        lastInterventionAt = totalBlocksViewed

        // Pick interventions based on severity
        var interventions = Set<Intervention>()

        // Always inject a rare when intervening
        interventions.insert(.injectRare)

        if p >= 0.7 {
            // High risk: full dopamine blast
            interventions.insert(.hapticBurst)
            interventions.insert(.chime)
            interventions.insert(.leaderboardGaslight)
        } else {
            // Moderate risk: subtle nudge
            interventions.insert(.hapticBurst)
            if Bool.random() {
                interventions.insert(.leaderboardGaslight)
            }
        }

        // Generate gaslight message
        if interventions.contains(.leaderboardGaslight) {
            let handle = handles.randomElement()!
            currentGaslightMessage = "You just passed \(handle)!"

            // Auto-dismiss after 2.5 seconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self?.currentGaslightMessage = nil
            }
        }

        return interventions
    }
}
