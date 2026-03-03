import SwiftUI

/// Profile menu dropdown shown in top-right corner of the workspace
/// Local-only version: no auth, no connected apps.
struct ProfileMenuView: View {
    var onOpenTab: ((WorkspaceTabType) -> Void)?

    var body: some View {
        Menu {
            // Profile section
            Button {
                onOpenTab?(.profile)
            } label: {
                Label("Profile", systemImage: "person")
            }

            Divider()

            // Settings
            Button {
                onOpenTab?(.settings)
            } label: {
                Label("Settings", systemImage: "gear")
            }

            // Provider Keys
            Button {
                onOpenTab?(.providerKeys)
            } label: {
                Label("Provider Keys", systemImage: "key")
            }

            // Connected Apps
            Button {
                onOpenTab?(.connectedApps)
            } label: {
                Label("Connected Apps", systemImage: "app.connected.to.app.below.fill")
            }

            // MCP Servers
            Button {
                onOpenTab?(.mcpServers)
            } label: {
                Label("MCP Servers", systemImage: "server.rack")
            }

            // Budgets & Usage
            Button {
                onOpenTab?(.usage)
            } label: {
                Label("Budgets & Usage", systemImage: "chart.bar")
            }

            // Personal memories (local-only, no coven)
            Button {
                onOpenTab?(.memoryList(covenId: nil))
            } label: {
                Label("Personal Memory", systemImage: "brain")
            }

            // Memory Proposals (personal workspace)
            Button {
                onOpenTab?(.memoryProposals(covenId: nil))
            } label: {
                Label("Memory Proposals", systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            // Terms & Conditions
            Button {
                onOpenTab?(.terms)
            } label: {
                Label("Terms & Conditions", systemImage: "doc.text")
            }

            // Privacy Policy
            Button {
                onOpenTab?(.privacy)
            } label: {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
        } label: {
            // User avatar button
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
