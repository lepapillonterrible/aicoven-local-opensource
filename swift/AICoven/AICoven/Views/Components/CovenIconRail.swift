import SwiftUI

/// Discord-style vertical icon rail for switching between Strix (personal) and coven workspaces.
///
/// Layout (top → bottom):
/// - Strix personal workspace icon (sparkles, teal, always first)
/// - One circular icon per coven (initial of coven name, glass background)
/// - "+" create-coven button at the bottom
/// - A settings gear when `onOpenSettings` is provided
///
/// The active item is highlighted with a teal border ring.
///
/// Local-first note: unlike the cloud client, covens have no server-hosted
/// avatar endpoint, so this rail renders coven initials only.
struct CovenIconRail: View {
    /// All covens the user belongs to
    let covens: [Coven]
    /// Currently selected coven ID; nil means Strix/personal is active
    let selectedCovenId: String?
    /// Called when the user taps the Strix icon
    let onSelectStrix: () -> Void
    /// Called when the user taps a coven icon
    let onSelectCoven: (Coven) -> Void
    /// Called when the user taps the "+" button to create a new coven
    let onCreateCoven: () -> Void
    /// Called when the user taps the gear icon to open global settings
    var onOpenSettings: (() -> Void)?
    /// Whether the settings workspace is currently active
    var isSettingsSelected: Bool = false

    var body: some View {
        VStack(spacing: Spacing.sm) {

            // MARK: Strix (personal workspace) icon — always first

            CovenIconRailItem(
                label: nil,
                systemImage: "sparkles",
                backgroundColor: Color.aicovenTeal.opacity(0.25),
                isSelected: selectedCovenId == nil && !isSettingsSelected,
                action: onSelectStrix
            )
            .accessibilityLabel("Strix personal workspace")

            // Thin separator between Strix and covens
            Rectangle()
                .fill(Color.aicovenBorder)
                .frame(width: 28, height: 1)
                .padding(.vertical, Spacing.xxs)

            // MARK: Coven icons — circular avatars with initials

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Spacing.sm) {
                    ForEach(covens) { coven in
                        CovenIconRailItem(
                            label: String(coven.name.prefix(1)).uppercased(),
                            systemImage: nil,
                            backgroundColor: Color.aicovenGlass,
                            isSelected: selectedCovenId == coven.id,
                            action: { onSelectCoven(coven) }
                        )
                        .accessibilityLabel("Coven: \(coven.name)")
                    }
                }
            }

            Spacer(minLength: 0)

            // MARK: Create coven button

            Button(action: onCreateCoven) {
                ZStack {
                    Circle()
                        .fill(Color.aicovenGlass)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                        )

                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.aicovenTextSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create new coven")

            // MARK: Global settings gear — always visible

            if let onOpenSettings {
                Rectangle()
                    .fill(Color.aicovenBorder)
                    .frame(width: 28, height: 1)
                    .padding(.vertical, Spacing.xxs)

                CovenIconRailItem(
                    label: nil,
                    systemImage: "gearshape",
                    backgroundColor: Color.aicovenGlass,
                    isSelected: isSettingsSelected,
                    action: onOpenSettings
                )
                .accessibilityLabel("Global settings")
            }
        }
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.xs)
        .frame(width: 56)
        .background(Color.aicovenSurfaceElevated.opacity(0.62))
        .overlay(alignment: .trailing) {
            // Separator line on the right edge
            Rectangle()
                .fill(Color.aicovenBorder)
                .frame(width: 1)
        }
    }
}

/// A single circular icon in the CovenIconRail.
///
/// Renders either a text initial (`label`) or an SF Symbol (`systemImage`).
/// When `isSelected` is true, a teal border ring is drawn around the circle.
private struct CovenIconRailItem: View {
    /// Single-character label (coven initial); nil when using a system image
    let label: String?
    /// SF Symbol name; nil when using a text label
    let systemImage: String?
    /// Background color for the circle
    let backgroundColor: Color
    /// Whether this item is the currently active workspace
    let isSelected: Bool
    /// Called when the user taps this item
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(backgroundColor)
                .frame(width: 40, height: 40)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.aicovenTeal : Color.clear,
                            lineWidth: 2
                        )
                )
                .overlay {
                    if let systemImage {
                        // SF Symbol icon (Strix sparkles, gear, etc.)
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.aicovenTeal)
                    } else if let label {
                        // Text initial
                        Text(label)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.aicovenTextPrimary)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview("CovenIconRail") {
    let sampleCovens = [
        Coven(id: "1", name: "Growth", createdAt: .now, updatedAt: .now),
        Coven(id: "2", name: "Engineering", createdAt: .now, updatedAt: .now),
        Coven(id: "3", name: "Marketing", createdAt: .now, updatedAt: .now),
    ]

    HStack(spacing: 0) {
        CovenIconRail(
            covens: sampleCovens,
            selectedCovenId: nil,
            onSelectStrix: {},
            onSelectCoven: { _ in },
            onCreateCoven: {},
            onOpenSettings: {},
            isSettingsSelected: false
        )

        Spacer()
    }
    .frame(height: 500)
    .background(NebulaBackground())
}
