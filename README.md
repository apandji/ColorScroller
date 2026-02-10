# ColorScroller

> The average person spends two hours a day scrolling through social media, adding up to 34 full days per year consumed by the infinite feed.
>
> ColorScroller explores the way in which digital addiction is designed. The mechanics of digital addiction is laid bare as a system that rewards users into submission while punishing you for participation. The (used) user swipes through a series of cards. They discover colors, which gets them started. Pleasant auditory and haptic based carrots encourage them to keep going. But, the more they scroll the louder it gets. Decibels and pitch are used as levers of punishment.
>
> Here, ColorScroller exposes social media for what it is. A system where the user gets played as a captive entity controlled by an interface that punishes what it simultaneously encourages.

---

## Features

### Leaderboard Landing Page
The first card is a fake live leaderboard — a dark, monospaced ranking screen showing other "players" alongside your last session stats. A pulsing red LIVE dot, hourly-rotating fake entries, and internet-handle names (`void_echo`, `pixel_drift`, `dead_scroll`) create the illusion of a competitive community. It's a lie — manufactured social proof designed to pressure you into scrolling. Swipe past it to begin.

### Infinite Vertical Feed
A full-screen, vertically paging scroll view generates blocks on the fly. New blocks are pre-generated ahead of the current position so the feed always feels seamless. Every card carries a subtle "keep scrolling" prompt at the bottom — a bouncing chevron that never lets you forget there's more.

### Skin Unlock System
Blocks can carry **skins** — named color treatments you collect just by scrolling past them. Skins come in three rarity tiers:

| Rarity | Count | Visual Style |
|---|---|---|
| **Common** | 10 | Solid colors (Crimson, Tangerine, Lemon, Jade, Azure, Violet, Magenta, Mint, Cyan, Indigo) |
| **Rare** | 6 | Gradients (Sunrise, Ocean Glass, Aurora, Grape Soda, Lava, Deep Space) |
| **Special** | 12+ | Patterns — stripes, dots, SF Symbol scatters, emoji tiles (Starfield, Heartbeat, Cat Party, Fire Walk, etc.) |

### Progressive Discovery
The mix of what you encounter evolves as you scroll:

- **First ~10 blocks** — grayscale only (monochrome).
- **10–50** — common solid-color skins begin appearing.
- **55+** — once all commons are unlocked, rare gradient skins start showing up.
- **85+** — once all rares are unlocked, special pattern skins enter the pool.

New-skin encounter chances also decrease over time (early 20% → mid 12% → late 8%), keeping unlocks exciting but not overwhelming.

### Unlock Experience
When you discover a new skin:
- Scrolling pauses for 0.8s so you can appreciate it
- A two-note ascending chime (E5 → B5) plays
- A strong haptic punch fires
- A translucent toast shows the rarity and name

### Haptic Feedback
Every swipe triggers a double-tap rigid haptic for a punchy, aggressive feel. Touch-down and touch-up events produce lighter haptic feedback.

### Audio Tone
A real-time sine-wave tone plays while your finger is on the screen:

- **Frequency** starts low (~240 Hz) and randomly steps up as you view more blocks, capping at 5 kHz.
- **Volume** follows an exponential curve that ramps over ~500 block views from near-silent to full.

Built on `AVAudioEngine` with an `AVAudioSourceNode` for sample-accurate synthesis.

### Inventory
Tap the **Unlocked** pill to open a sheet showing every skin you've collected, organized by rarity. Each entry displays:

- A mini color swatch
- The skin name and rarity label
- How many times you've seen it
- Its RGB values

### Churn Prediction & Emergency Dopamine

The app monitors your scrolling behavior in real time and predicts when you're about to leave. When churn risk is high, it intervenes:

**How it works:**
1. A `ScrollSnapshot` feature vector is computed on every scroll — velocity, velocity trend (slowing down?), reward drought (cards since last unlock), session fatigue, engagement depth.
2. A `ChurnPredictor` evaluates the snapshot and returns `P(churn)` — the probability you're about to stop.
3. When `P(churn) ≥ 0.55`, the `DopamineEngine` fires interventions:

| Risk Level | Interventions |
|---|---|
| **Moderate** (0.55–0.70) | Inject a locked rare/special into the next few cards + surprise haptic |
| **High** (0.70+) | All of the above + ding chime + leaderboard gaslight ("You just passed pixel_drift!") |

A 12-card cooldown prevents intervention fatigue.

**Architecture — swappable brain:**
- **Wednesday (ships now):** `HeuristicChurnPredictor` — hand-tuned rules based on the 5 strongest behavioral signals (reward drought, velocity trend, session fatigue, engagement depth, absolute velocity).
- **Post-exhibition:** `MLChurnPredictor` — a Core ML tabular classifier trained on real user data from the TestFlight deployment. Drop in the `.mlmodel`, swap one line.

### Telemetry & Training Data

Every scroll event and session end is logged to local JSON files and synced to CloudKit:

- **13 fields per scroll event** — timestamp, card index, blocks viewed, unlock count, reward drought, session length, time-of-day, rarity shown, etc.
- **Local JSON** is the source of truth (works offline)
- **CloudKit** auto-aggregates from all TestFlight devices into a public database
- **Debug panel** has an "Export Telemetry" button for manual backup via AirDrop/email
- **Churn labeling** — post-process: scroll events within 5 cards of session end → `churn = true`

### Debug Panel
A built-in debug overlay (bottom-left) lets you tune parameters at runtime:

- Unique blocks seen / total swipes counters
- **Force unlock all** toggle
- **Toast cooldown** slider
- **New unlock chance** sliders (early / mid / late)
- **Export Telemetry** button — share raw JSON files

## Color Generation — Behavior-Seeded Palettes

When you unlock a **static rare** skin, the app captures a snapshot of your behavior and uses it to deterministically generate a batch of 10 new skins. No two players who scroll differently will get the same colors.

### What Gets Recorded

The following metrics are captured at the exact moment of the rare unlock into a `BehaviorSnapshot`:

| Metric | What it measures |
|---|---|
| `totalBlocksViewed` | Total cards swiped (including revisits) — measures overall engagement |
| `blocksSeen` | Unique cards seen — measures exploration breadth |
| `activeScrollSeconds` | Cumulative seconds spent actively scrolling — measures session intensity |
| `isScrolling` | Whether the user was mid-scroll at the moment of unlock |
| `currentIndex` | Position in the feed at the time of unlock |
| `timeOfDayBucket` | Time of day (morning / afternoon / evening / night) — groups of 6 hours |
| `sessionLengthSeconds` | Wall-clock time since the app launched — measures session duration |
| `rarityWeights` | The current feed distribution weights (mono / common / rare / special) at unlock time |
| `sourceRareID` | The UUID of the specific rare skin that triggered generation |

### How Behavior Becomes Color

1. **Hashing** — All snapshot fields are combined via `Hasher` into a single `UInt64` seed. Even tiny differences in behavior (one extra swipe, a few more seconds of scrolling) produce a completely different seed.

2. **Seeded PRNG** — The seed initializes a splitmix64 pseudo-random number generator (`SeededPRNG`). Every subsequent decision — hue, saturation, brightness, name, pattern type — is drawn deterministically from this generator.

3. **Palette anchoring** — The PRNG picks a random **anchor hue** (0–360°), a **saturation center** (50–90%), and a **brightness center** (55–95%). A **hue spread** (±18°–43°) defines the neighborhood. All skins in the batch live within this color neighborhood, giving the set a coherent "mood."

4. **Per-skin jitter** — Each individual skin gets small random offsets to hue (within the spread), saturation (±12%), and brightness (±10%), so they're related but distinct.

5. **Batch composition** — Each batch creates:
   - **6 commons** — solid colors with deterministic adjective-noun names ("Frozen Ember", "Neon Sage")
   - **3 rares** — 2- or 3-stop gradients
   - **1 special** — randomly chosen from stripes, dots, SF Symbol scatters, or emoji tiles, using palette-derived colors

6. **Injection** — New skins are added to `DynamicCatalogStore` and get a 100-block boost window so they appear more frequently right after generation.

### The Result

A player who scrolls slowly in the evening gets warm, muted palettes. Someone who power-scrolls through 500 cards at noon gets something completely different. The specific rare skin that triggers generation, combined with the exact scroll position and session metrics, ensures every batch is unique — your colors are a fingerprint of how you used the app.

### Supporting Infrastructure

| File | Purpose |
|---|---|
| `BehaviorSeed.swift` | `BehaviorSnapshot` captures all metrics. `BehaviorSeed.makeSeed(from:)` hashes the snapshot into a `UInt64`. `SeededPRNG` (splitmix64) provides deterministic randomness. `SkinNameGenerator` creates adjective-noun names. `PaletteGenerator` builds the full 10-skin batch. |
| `GeneratedSet.swift` | `GeneratedSet` model (Codable, stores seed + metadata; skins are transient). `GeneratedSkinMeta` for per-skin provenance. |
| `DynamicCatalogStore.swift` | Singleton that holds all generated sets, dynamic skin pools, and boost windows. Posts a `didInjectGeneratedSet` notification on injection. |

## Requirements

- **iOS 26.0+**
- **Xcode 26.2+**
- **Swift 5.0**

## Getting Started

1. Clone the repository.
2. Open `ColorScroller.xcodeproj` in Xcode.
3. Select a simulator or device target.
4. Build and run (**⌘R**).

No external dependencies — the project uses only Apple frameworks (`SwiftUI`, `Combine`, `AVFoundation`, `UIKit`, `CloudKit`).

## Project Structure

```
ColorScroller/
├── ColorScrollerApp.swift        # App entry point
├── ContentView.swift             # Models, view model, views, audio, haptics
├── BehaviorSeed.swift            # BehaviorSnapshot, seed hashing, SeededPRNG, name & palette generators
├── BehaviorLogger.swift          # Telemetry: local JSON logging + CloudKit sync
├── ChurnEngine.swift             # ScrollSnapshot, ChurnPredictor, DopamineEngine
├── GeneratedSet.swift            # GeneratedSet + GeneratedSkinMeta models
├── DynamicCatalogStore.swift     # Singleton managing generated skin pools & boosts
├── InventoryPill+Shimmer.swift   # (Dead code — shimmer replaced with bounce animation)
├── ColorScroller.entitlements    # iCloud/CloudKit entitlements
└── Assets.xcassets/              # App icon & accent color
docs/
└── NEXT-ACTIONS.md               # Completed & remaining tasks
```

## License

This project does not currently include a license. Contact the author for usage terms.
