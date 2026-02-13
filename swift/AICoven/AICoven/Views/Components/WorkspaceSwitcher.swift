import SwiftUI

enum WorkspaceType {
    case home
    case covens
}

/// Workspace switcher to toggle between Home and Covens workspaces.
struct WorkspaceSwitcher: View {
    let currentWorkspace: WorkspaceType
    let onSwitch: () -> Void
    let isExpanded: Bool // Whether sidebar is expanded or collapsed

    private var icon: String {
        switch currentWorkspace {
        case .home: "house.fill"
        case .covens: "sparkles"
        }
    }

    private var label: String {
        switch currentWorkspace {
        case .home: "Home"
        case .covens: "Covens"
        }
    }

    var body: some View {
        Button(action: onSwitch) {
            HStack(spacing: Spacing.xs) {
                // Icon
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.aicovenTeal)

                if isExpanded {
                    // Label (only when expanded)
                    Text(label)
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTextPrimary)

                    Spacer()

                    // Switch indicator - arrows showing bidirectional switch
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10))
                        .foregroundColor(.aicovenTextTertiary)
                }
            }
            .padding(.horizontal, isExpanded ? Spacing.xs : 4)
            .padding(.vertical, Spacing.xs)
            .background(Color.aicovenGlass)
            .cornerRadius(BorderRadius.sm)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: isExpanded ? .infinity : nil) // Only expand when sidebar is expanded
    }
}

#Preview {
    VStack(spacing: Spacing.md) {
        WorkspaceSwitcher(currentWorkspace: .home, onSwitch: {}, isExpanded: true)
        WorkspaceSwitcher(currentWorkspace: .home, onSwitch: {}, isExpanded: false)
    }
    .padding()
    .background(Color.aicovenDark)
}
