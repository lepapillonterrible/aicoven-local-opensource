import SwiftUI

/// Animated splash screen displayed on app launch
struct SplashScreenView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            // Brand background
            NebulaBackground()

            VStack(spacing: Spacing.lg) {
                // App Icon
                Image("icon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .cornerRadius(28) // iOS-style rounded corners
                    .shadow(color: .aicovenTeal.opacity(0.3), radius: 20, x: 0, y: 0)
                    .scaleEffect(isAnimating ? 1.0 : 0.8)
                    .opacity(isAnimating ? 1.0 : 0.0)

                // App Title
                Text("AICoven")
                    .font(.aicovenDisplayLarge)
                    .foregroundColor(.aicovenTextPrimary)
                    .opacity(isAnimating ? 1.0 : 0.0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                isAnimating = true
            }
        }
    }
}

#Preview {
    SplashScreenView()
}
