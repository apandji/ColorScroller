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
├── ColorScrollerApp.swift   # App entry point
├── ContentView.swift        # All app code — models, view model, views, audio, haptics
└── Assets.xcassets/         # App icon & accent color
```

## License

This project does not currently include a license. Contact the author for usage terms.
