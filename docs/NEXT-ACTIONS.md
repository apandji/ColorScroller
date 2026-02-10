# Next Actions

## ✅ Completed

### Behavior-Driven Color Generation

1. **Fix the filter bug** — Changed `$0.id == $0.id` (always true) to `unlockedSkinIDs.contains($0.id)`. Was the root cause of early artifacting.
2. **Wire BehaviorSnapshot into generation** — `attemptUnlock` now builds a full `BehaviorSnapshot` (blocks seen, scroll time, time-of-day, session length, rarity weights) and feeds it through `BehaviorSeed.makeSeed`.
3. **Use SeededPRNG for all color decisions** — `PaletteGenerator.generateBatch` picks a random anchor hue, jittered offsets, varied saturation/brightness bands per batch via `SeededPRNG`.
4. **Generate creative names** — `SkinNameGenerator` combines 50 adjectives × 50 nouns seeded by the same PRNG ("Frozen Ember", "Neon Sage", etc.).
5. **Diversify generated specials** — PRNG picks stripes, dots, SF Symbol patterns, or emoji patterns with palette-derived colors.
6. **Make batches thematically coherent** — Each batch anchors around a narrow hue neighborhood (±30°) with consistent saturation/brightness.

### New Special Pattern Types

- Added `BlockStyle.symbols(String, Color, Color)` and `BlockStyle.emoji(Character, Color)`.
- Created `SymbolsPattern` and `EmojiPattern` views (Canvas-based tiled rendering).
- 8 new static specials: Starfield, Heartbeat, Moonrise, Bolt Field, Cat Party, Fire Walk, Bloom Garden, Sparkle Night.
- `PaletteGenerator` randomly generates these new types for dynamic specials.

### Specials Not Appearing — Fixed

- Dynamic specials now get a minimum 5% appearance chance as soon as they exist, bypassing the `blocksSeen ≥ 85` gate.
- Only *static catalog* rare unlocks trigger new batch generation (prevents infinite generation chain).

### Unlock Experience Polish

- **Scroll pause** — Scrolling is disabled for 0.8s on unlock so the player can appreciate the new skin.
- **Ding sound** — Two-note ascending chime (E5 → B5) via a dedicated `AVAudioPlayerNode`, doesn't interfere with the continuous scroll tone.
- **Haptic punch** — Strong haptic tap (0.9 intensity) fires alongside the ding.
- **Shimmer artifacting fixed** — Removed the `ShimmerOverlay` (white-flash root cause) and replaced with a spring-bounce scale animation on the inventory pill.

### Label Padding — Fixed

- Changed `BlockView` label from `.padding(18)` to `.padding([.horizontal, .top], 18).padding(.bottom, 44)` to clear the home indicator.

### Leaderboard Landing Page

- **`LeaderboardCard`** — First card in the feed (id: -1), shown before the color blocks.
- **Fake live leaderboard** — 7 randomly generated players with internet-handle-style names (`void_echo`, `pixel_drift`, etc.) plus the real player's last session stats highlighted as "You".
- **Hourly rotation** — Fake entries re-seed every hour (via `SeededPRNG` seeded from the current hour) so the leaderboard feels "live" and dynamic.
- **Stats shown** — SWIPED (totalBlocksViewed) and FOUND (unlockedSkins.count) columns.
- **Session persistence** — `SessionStats` saves swiped/collected to `UserDefaults` when the app backgrounds; loaded on next launch.
- **Pulsing LIVE indicator** — Red dot + "LIVE" label with a repeating pulse animation.
- **HUD fade-in** — Swiped/Unlocked pills are hidden while on the leaderboard and fade in when the player scrolls to the first block.
- **"swipe to begin" prompt** — Bouncing chevron at the bottom of the leaderboard.

### Code Health Audit — Clean ✅

- **Nested duplicate removed** — `ColorScroller/ColorScroller/` was a stale copy of the entire source folder (older code from Jenica's branch). Deleted along with its nested `.xcodeproj`. Root cause of the "Multiple commands produce" build error.
- **Project file clean** — Single `PBXFileSystemSynchronizedRootGroup` pointing to `ColorScroller/`, single target. No duplicate file references.
- **Dev team note** — Project-level `DEVELOPMENT_TEAM` (885R49NXMT / Jenica) differs from target-level (4L26YVZYX3 / apandji). Target overrides project, so builds work. Will flip again on cross-push — not worth fighting.
- **Dead code** — `InventoryPill+Shimmer.swift` still defines `ShimmerOverlay`, `ShimmerModifier`, and `.subtleShimmer()` but none are used. Harmless; can be deleted for cleanliness.

### Performance Lag on Launch — Fixed ✅

- **Removed unused `GeometryReader`** — The outer `GeometryReader { geo in ... }` wrapping the entire `ContentView` body was never referenced. It forced an extra layout pass on every frame, delaying the first render.
- **Changed `scrollPosition` from `-1` to `nil`** — Starting with `-1` forced SwiftUI to resolve and programmatically scroll to the id-matching item. Starting with `nil` lets the scroll view render at its natural top position (the leaderboard) immediately with no position resolution overhead.

### "keep scrolling" Prompt ✅

- Bouncing chevron + "keep scrolling" text added to every `BlockView` card, positioned at **bottom center** with very low opacity (0.22).
- Does not conflict with the color name label (label is at bottom-leading with 44pt bottom padding; chevron hugs the 10pt bottom edge).

### Unlock Pause Reduced ✅

- Lowered scroll-disable duration from 1.3s → 0.8s. Toast remains visible 0.4s longer for a smooth exit.

### Telemetry / Training Data Collection ✅

- **`BehaviorLogger`** — New singleton that passively logs every scroll event and session-end event.
- **Local JSON (source of truth)** — Events buffer in memory (20 at a time) then flush to per-session JSON files in the app's Documents directory. Works offline, zero dependencies.
- **CloudKit sync** — On session end, both JSON files are uploaded as `CKAsset`s on a single `Session` record to the public CloudKit database. All 15 TestFlight devices auto-aggregate; viewable in [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard/).
- **Debug export fallback** — "Export Telemetry" button in the debug panel opens a share sheet with the raw JSON files (AirDrop, email, etc.).
- **Per-event fields captured** — `sessionID`, `deviceID`, `timestamp`, `cardIndex`, `totalBlocksViewed`, `blocksSeen`, `unlockedCount`, `blocksSinceLastUnlock`, `activeScrollSeconds`, `sessionLengthSeconds`, `timeOfDayBucket`, `wasUnlock`, `skinRarity`.
- **Churn labeling** — Post-process: every scroll event within 5 cards of a `SessionEnd` timestamp gets `churn = true`. This is the training target for a future Create ML tabular classifier.

### Churn Prediction & Emergency Dopamine ✅

- **`ChurnEngine.swift`** — Complete churn prediction → intervention pipeline.
- **`ScrollSnapshot`** — Feature vector computed per scroll: velocity, velocity trend (linear regression slope over last 10 events), reward drought, session fatigue, engagement depth, unlock density.
- **`ChurnPredictor` protocol** — Swappable brain with two implementations:
  - `HeuristicChurnPredictor` (ships Wednesday) — hand-tuned rules on 5 signals: reward drought (40%), velocity trend (25%), session fatigue (20%), engagement depth (10%), absolute velocity (10%).
  - `MLChurnPredictor` (placeholder, uncomment when `.mlmodel` is ready) — Core ML tabular classifier.
- **`DopamineEngine`** — Singleton that evaluates every scroll event:
  - Moderate risk (P ≥ 0.55): inject locked rare into next 1–3 cards + haptic burst.
  - High risk (P ≥ 0.70): + ding chime + leaderboard gaslight ("You just passed pixel_drift!").
  - 12-card cooldown prevents intervention fatigue.
- **`GaslightToastView`** — Translucent capsule toast with green border, slides in from top, auto-dismisses after 2.5s.
- **Feed manipulation** — `injectEmergencyReward()` replaces upcoming mono/common cards with locked rares/specials.

---

## Remaining

### Pre-TestFlight Checklist

- [x] Create CloudKit `Session` record type in Dashboard
- [x] Add `recordName` queryable index to `Session`
- [x] Deploy schema from Development → Production
- [x] Verify telemetry sync: `[BehaviorLogger] ✅ CloudKit sync OK`
- [x] Add App Icon
- [x] Archive & upload to TestFlight
- [ ] Confirm its ready for Wednesday!

### Future (Post-Exhibition)

- [ ] Export CloudKit data → CSV, label churn events, train Create ML tabular classifier
- [ ] Drop trained `.mlmodel` into project, swap `HeuristicChurnPredictor` → `MLChurnPredictor`
- [ ] Personalize leaderboard gaslighting based on per-user engagement depth
- [ ] Tune churn threshold + cooldown based on real-world data
