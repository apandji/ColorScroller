import SwiftUI

/// A standalone shimmer overlay — renders a sweeping white highlight.
/// Does NOT duplicate the parent content; just place it in an `.overlay`.
struct ShimmerOverlay: View {
    let duration: Double
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // A narrow diagonal band that sweeps across
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0.0),
                    .init(color: .white.opacity(0.30), location: 0.45),
                    .init(color: .white.opacity(0.30), location: 0.55),
                    .init(color: .white.opacity(0), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: w * 0.6, height: h * 2)
            .rotationEffect(.degrees(20))
            .offset(x: -w * 0.6 + phase * (w * 1.8), y: 0)
            .blendMode(.screen)
        }
        .clipped()
        .onAppear {
            // Small delay so the view is mounted before animating — avoids flash
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeInOut(duration: duration)) {
                    phase = 1.0
                }
            }
        }
    }
}

// Keep the old modifier available but redirect to the new overlay
struct ShimmerModifier: ViewModifier {
    let duration: Double

    func body(content: Content) -> some View {
        content
            .overlay {
                ShimmerOverlay(duration: duration)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func subtleShimmer(duration: Double = 1.0) -> some View {
        modifier(ShimmerModifier(duration: duration))
    }
}
