import SwiftUI
internal import Combine

/// Animated cauldron loading indicator using 8-frame sprite animation
struct CauldronLoadingView: View {
    @State private var currentFrame = 1
    @State private var pulseScale: CGFloat = 1.0

    let message: String?
    let size: CGFloat
    let frameDuration: Double = 0.09 // ~11 fps to match mobile

    /// Timer for frame animation
    let timer = Timer.publish(every: 0.09, on: .main, in: .common).autoconnect()

    init(message: String? = nil, size: CGFloat = 60) {
        self.message = message
        self.size = size
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            // Frame-based cauldron animation with pulse effect
            Image("cauldron_frame_\(currentFrame)")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .scaleEffect(pulseScale)
                .onReceive(timer) { _ in
                    // Cycle through frames 1-8
                    currentFrame = (currentFrame % 8) + 1
                }
                .onAppear {
                    // Start pulse animation
                    withAnimation(
                        .easeInOut(duration: 0.8)
                            .repeatForever(autoreverses: true)
                    ) {
                        pulseScale = 1.05
                    }
                }

            // Optional message
            if let message {
                Text(message)
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Compact inline cauldron loader for chat bubbles
struct InlineCauldronLoader: View {
    @State private var currentFrame = 1

    /// Timer for frame animation
    let timer = Timer.publish(every: 0.09, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: Spacing.xs) {
            // Inline cauldron animation (smaller size)
            Image("cauldron_frame_\(currentFrame)")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .onReceive(timer) { _ in
                    // Cycle through frames 1-8
                    currentFrame = (currentFrame % 8) + 1
                }

            // Thinking dots
            HStack(spacing: 4) {
                ForEach(0 ..< 3) { index in
                    Circle()
                        .fill(Color.aicovenTextSecondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + (Double((currentFrame + index * 2) % 8) / 8.0) * 0.7)
                }
            }
        }
    }
}

#Preview("Cauldron Loading") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 40) {
            CauldronLoadingView(message: "AI is thinking...")
            CauldronLoadingView(size: 40)
            InlineCauldronLoader()
        }
    }
}
