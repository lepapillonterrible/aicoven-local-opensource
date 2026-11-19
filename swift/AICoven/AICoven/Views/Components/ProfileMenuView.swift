import SwiftUI

/// The account menu in the top-right corner of the workspace. Its rows open
/// Settings at the place they name; the last signs the person out.
struct ProfileMenuView: View {
    var onOpenTab: ((WorkspaceTabType) -> Void)?
    @EnvironmentObject private var authService: AuthService

    var body: some View {
        Menu {
            Button {
                onOpenTab?(.profile)
            } label: {
                Label("Profile", systemImage: "person")
            }

            Divider()

            Button {
                onOpenTab?(.settings)
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button {
                onOpenTab?(.terms)
            } label: {
                Label("Terms & Conditions", systemImage: "doc.text")
            }

            Button {
                onOpenTab?(.privacy)
            } label: {
                Label("Privacy Policy", systemImage: "hand.raised")
            }

            Divider()

            Button(role: .destructive) {
                do {
                    try authService.signOut()
                } catch {
                    AppErrorReporter.log(error: error, context: "ProfileMenuView.signOut")
                }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            UserAvatarButton()
        }
        .menuStyle(.borderlessButton)
    }
}

/// User avatar button for profile menu (local user only).
struct UserAvatarButton: View {
    private let initials: String = "LC" // Local Client

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.aicovenTeal, Color.aicovenPurple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 28, height: 28)
                .glowEffect(color: .aicovenTeal, radius: 4, intensity: 0.3)

            Text(initials)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

#Preview {
    ZStack {
        NebulaBackground()

        HStack {
            Spacer()
            VStack {
                ProfileMenuView()
                    .environmentObject(AuthService.shared)
                Spacer()
            }
            .padding()
        }
    }
}
