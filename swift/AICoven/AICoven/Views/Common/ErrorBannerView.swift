import SwiftUI

/// Reusable top-of-screen error banner for app-level errors.
///
/// This is intended for global or high-level failures (e.g. unlock, startup,
/// provider configuration) rather than per-message chat errors. For
/// conversation-scoped issues, prefer inline assistant messages.
struct ErrorBannerView: View {
    let message: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
                .padding(.top, 2)

            Text(message)
                .font(.aicovenBodySmall)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white.opacity(0.9))
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(
            LinearGradient(
                colors: [Color.red.opacity(0.9), Color.red.opacity(0.7)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(BorderRadius.md)
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

#Preview {
    VStack(spacing: 16) {
        ErrorBannerView(message: "Something went wrong while unlocking local data. Please try again.")
        ErrorBannerView(message: "Device authentication failed. You can try again or unlock with your passphrase.") {}
    }
    .padding()
    .background(Color.black.edgesIgnoringSafeArea(.all))
}
