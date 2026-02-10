# ColorScroller

An iOS app that turns mindless scrolling into a collectible color-discovery experience. Swipe through a never-ending vertical feed of colored blocks, unlock skins of increasing rarity, and build your inventory — all accompanied by haptic feedback and an evolving audio tone.

## Features

### Infinite Vertical Feed
A full-screen, vertically paging scroll view generates blocks on the fly. New blocks are pre-generated ahead of the current position so the feed always feels seamless.

### Skin Unlock System
Blocks can carry **skins** — named color treatments you collect just by scrolling past them. Skins come in three rarity tiers:

| Rarity | Count | Visual Style |
|---|---|---|
| **Common** | 10 | Solid colors (Crimson, Tangerine, Lemon, Jade, Azure, Violet, Magenta, Mint, Cyan, Indigo) |
| **Rare** | 6 | Gradients (Sunrise, Ocean Glass, Aurora, Grape Soda, Lava, Deep Space) |
| **Special** | 4 | Patterns — stripes and dots (Barcode Pop, Candy Stripe, Night Dots, Confetti Dots) |

### Progressive Discovery
The mix of what you encounter evolves as you scroll:

- **First ~10 blocks** — grayscale only (monochrome).
- **10–50** — common solid-color skins begin appearing.
- **55+** — once all commons are unlocked, rare gradient skins start showing up.
- **85+** — once all rares are unlocked, special pattern skins enter the pool.

New-skin encounter chances also decrease over time (early 20% → mid 12% → late 8%), keeping unlocks exciting but not overwhelming.

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

### Unlock Toasts
A translucent material pop-up appears briefly each time a new skin is unlocked, showing the rarity and name.

### Debug Panel
A built-in debug overlay (bottom-left) lets you tune parameters at runtime:

- Unique blocks seen / total swipes counters
- **Force unlock all** toggle
- **Toast cooldown** slider
- **New unlock chance** sliders (early / mid / late)

## Color Generation

When the player unlocks a **rare** skin, the app dynamically generates a batch of 10 new skins and injects them into the feed pool. This is handled by `attemptUnlock` in `ScrollerViewModel`, the `DynamicCatalogStore` singleton, and supporting types in `GeneratedSet.swift` and `BehaviorSeed.swift`.

### How It Works

1. **Trigger** — Unlocking any rare skin fires the generation.
2. **Batch composition** — Each batch creates 6 commons (solid colors), 3 rares (gradients), and 1 special (stripes).
3. **Hue-based colors** — Colors are built with `Color(hue:saturation:brightness:)` at evenly spaced hue intervals, with fixed saturation (0.7) and brightness (0.9).
4. **Injection** — The new skins are appended to `DynamicCatalogStore`'s dynamic pools (`dynamicCommons`, `dynamicRares`, `dynamicSpecials`), which are merged with the static catalogs when the feed generates new blocks.
5. **Boost window** — Generated skins get a 100-block boost window so they appear more frequently right after injection.
6. **Shimmer cue** — A shimmer animation plays over the Inventory pill to hint that new skins have been added (`InventoryPill+Shimmer.swift`).

### Supporting Infrastructure

| File | Purpose |
|---|---|
| `GeneratedSet.swift` | `GeneratedSet` model (Codable, stores seed + metadata; skins are transient). `GeneratedSkinMeta` for per-skin provenance. |
| `BehaviorSeed.swift` | `BehaviorSnapshot` captures scroll stats + time-of-day. `BehaviorSeed.makeSeed(from:)` hashes the snapshot into a `UInt64`. `SeededPRNG` (splitmix64-style) provides deterministic randomness. |
| `DynamicCatalogStore.swift` | Singleton that holds all generated sets, dynamic skin pools, and boost windows. Posts a `didInjectGeneratedSet` notification on injection. |
| `InventoryPill+Shimmer.swift` | `ShimmerModifier` — a one-shot gradient sweep overlay applied to the Inventory pill when a set is injected. |

### Known Issues

1. **Colors are too similar** — Every batch divides the hue wheel into equal slices (`Double(i)/6.0` for commons, `Double(i)/3.0` for rares) with the same saturation and brightness. The result is that every generated batch produces nearly identical colors. The `BehaviorSnapshot` / `SeededPRNG` infrastructure exists but is **not actually wired in** — the seed is currently just `Date().timeIntervalSince1970` and the PRNG is never used during skin creation.
2. **Visual artifacting** — There is a bug on the `unlockedOfRarity` filter line: `commonCatalog.contains(where: { $0.id == $0.id })` compares each element's ID to *itself* (always true), so every skin — including ones the player has never seen — is treated as "unlocked". This causes the locked/unlocked partition to break and can produce unexpected feed behavior and visual glitches.
3. **Generic names** — Generated skins are named "Generated Common 1", "Generated Rare 3", etc. There is no name-generation logic; they need real creative names (see `docs/NEXT-ACTIONS.md`).

## Requirements

- **iOS 26.0+**
- **Xcode 26.2+**
- **Swift 5.0**

## Getting Started

1. Clone the repository.
2. Open `ColorScroller.xcodeproj` in Xcode.
3. Select a simulator or device target.
4. Build and run (**⌘R**).

No external dependencies — the project uses only Apple frameworks (`SwiftUI`, `Combine`, `AVFoundation`, `UIKit`).

## Project Structure

```
ColorScroller/
├── ColorScrollerApp.swift        # App entry point
├── ContentView.swift             # Models, view model, views, audio, haptics
├── GeneratedSet.swift            # GeneratedSet + GeneratedSkinMeta models
├── BehaviorSeed.swift            # BehaviorSnapshot, seed hashing, SeededPRNG
├── DynamicCatalogStore.swift     # Singleton managing generated skin pools & boosts
├── InventoryPill+Shimmer.swift   # Shimmer animation modifier
└── Assets.xcassets/              # App icon & accent color
docs/
└── NEXT-ACTIONS.md               # Planned features & bug fixes
```

## License

This project does not currently include a license. Contact the author for usage terms.
