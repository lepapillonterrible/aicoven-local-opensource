import SwiftUI
internal import Combine

// MARK: - Appearance

/// Which light the stone is seen in: stone by day in a light appearance,
/// stone at dusk in a dark one. `system` follows the device's appearance;
/// `light` and `dark` pin one.
enum RoomAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The scheme to force, or `nil` to follow the device.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Stone

/// The cloud app's stone palette under this app's colour names. Each colour,
/// the overlay apart, has a day and a dusk value and follows the appearance.
/// Water marks what moves and what can be pressed, rust marks what failed
/// or destroys; stone has no third accent.
extension Color {
    /// Surfaces
    static let aicovenSurface = room(light: Color(hex: "#E8E2D6"), dark: Color(hex: "#2C2925"))
    /// The page surface, under its earlier name.
    static let aicovenDark = aicovenSurface
    static let aicovenSurfaceElevated = room(light: Color(hex: "#F0EBE2"), dark: Color(hex: "#37332D"))
    static let aicovenGlass = room(light: Color(hex: "#DCD4C5"), dark: Color(hex: "#3B3630"))
    static let aicovenBorder = room(light: Color(hex: "#C9BFAD"), dark: Color(hex: "#4B453C"))
    static let aicovenOverlay = Color(hex: "#29251F").opacity(0.3)

    // Ink
    static let aicovenTextPrimary = room(light: Color(hex: "#29251F"), dark: Color(hex: "#EDE6D9"))
    static let aicovenTextSecondary = room(light: Color(hex: "#5C544A"), dark: Color(hex: "#B4AA9A"))
    static let aicovenTextTertiary = room(light: Color(hex: "#605849"), dark: Color(hex: "#ADA397"))

    // Accents, under the names of the earlier palettes' teal, purple and
    // pink. The app fills buttons with the first under white labels, so
    // dusk uses the darker water the cloud app keeps for fills under white
    // (#517D79), not its text water (#8FBDB6).
    static let aicovenTeal = room(light: Color(hex: "#36625F"), dark: Color(hex: "#517D79"))
    static let aicovenPurple = room(light: Color(hex: "#5A5248"), dark: Color(hex: "#CFC6B6"))
    static let aicovenPink = room(light: Color(hex: "#8A4526"), dark: Color(hex: "#E0A183"))

    /// Stone as the cloud app names it: the chrome around the content
    /// (bars, sidebars), a hairline rule, and what is selected.
    static let aicovenChrome = room(light: Color(hex: "#DCD5C7"), dark: Color(hex: "#24211E"))
    static let aicovenRule = room(light: Color(hex: "#D2C9B9"), dark: Color(hex: "#3E3933"))
    static let aicovenSelected = room(light: Color(hex: "#F0EBE2"), dark: Color(hex: "#3A3530"))
    /// The fill of a swipe action that does no harm (Archive): its label is
    /// white in both appearances.
    static let aicovenSwipeNeutral = room(light: Color(hex: "#5A5248"), dark: Color(hex: "#5A5248"))

    /// Water as the cloud app names it, for a mark or text on a surface
    /// (what is moving: a recording under way): its lighter dusk value.
    static let aicovenWater = room(light: Color(hex: "#36625F"), dark: Color(hex: "#8FBDB6"))

    // Semantic
    static let aicovenSuccess = room(light: Color(hex: "#36625F"), dark: Color(hex: "#8FBDB6"))
    static let aicovenWarning = room(light: Color(hex: "#8A4526"), dark: Color(hex: "#E0A183"))
    static let aicovenError = room(light: Color(hex: "#8A4526"), dark: Color(hex: "#E0A183"))
}

// MARK: - Theme Manager

/// Owns the person's appearance choice and persists it.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private static let storageKey = "aicoven_room_appearance"

    @Published private(set) var appearance: RoomAppearance

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        appearance = stored.flatMap { RoomAppearance(rawValue: $0) } ?? .system
    }

    func setAppearance(_ appearance: RoomAppearance) {
        guard appearance != self.appearance else { return }
        UserDefaults.standard.set(appearance.rawValue, forKey: Self.storageKey)
        self.appearance = appearance
    }
}

// MARK: - View Helpers

/// Applies the person's appearance choice to a presentation (a sheet or
/// window that does not inherit the app root's preference).
struct ThemedColorScheme: ViewModifier {
    @ObservedObject private var themeManager = ThemeManager.shared

    func body(content: Content) -> some View {
        content.preferredColorScheme(themeManager.appearance.colorScheme)
    }
}

extension View {
    func themedColorScheme() -> some View {
        modifier(ThemedColorScheme())
    }
}
