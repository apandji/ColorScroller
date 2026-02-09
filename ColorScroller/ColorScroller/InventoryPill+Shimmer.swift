import SwiftUI

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1.0
    let duration: Double

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [Color.white.opacity(0.0), Color.white.opacity(0.35), Color.white.opacity(0.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.screen)
                .mask(content)
                .offset(x: phase * 200, y: phase * 120)
                .animation(.easeInOut(duration: duration), value: phase)
            )
            .onAppear {
                phase = 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    phase = -1.0 // hold initial; overlay is subtle
                }
            }
    }
}

extension View {
    func subtleShimmer(duration: Double = 1.0) -> some View {
        modifier(ShimmerModifier(duration: duration))
    }
}
