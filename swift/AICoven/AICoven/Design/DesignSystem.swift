import SwiftUI

// MARK: - Brand Colors

/// AICoven brand color palette.
///
/// These names are kept as computed aliases over the currently active
/// `AicovenTheme` so the 40+ existing sites that reference
/// `Color.aicovenTeal`, `Color.aicovenDark`, etc. continue to compile
/// while automatically picking up whichever theme the user has chosen
/// in Settings.
extension Color {
    /// Primary brand colors
    static var aicovenTeal: Color {
        ThemeManager.shared.theme.accentPrimary
    }

    static var aicovenPurple: Color {
        ThemeManager.shared.theme.accentSecondary
    }

    static var aicovenPink: Color {
        ThemeManager.shared.theme.accentTertiary
    }

    static var aicovenDark: Color {
        ThemeManager.shared.theme.surface
    }

    /// UI colors
    static var aicovenGlass: Color {
        ThemeManager.shared.theme.glass
    }

    static var aicovenBorder: Color {
        ThemeManager.shared.theme.border
    }

    static var aicovenOverlay: Color {
        ThemeManager.shared.theme.overlay
    }

    static var aicovenSurfaceElevated: Color {
        ThemeManager.shared.theme.surfaceElevated
    }

    /// Text colors
    static var aicovenTextPrimary: Color {
        ThemeManager.shared.theme.textPrimary
    }

    static var aicovenTextSecondary: Color {
        ThemeManager.shared.theme.textSecondary
    }

    static var aicovenTextTertiary: Color {
        ThemeManager.shared.theme.textTertiary
    }

    /// Semantic colors
    static var aicovenSuccess: Color {
        ThemeManager.shared.theme.success
    }

    static var aicovenWarning: Color {
        ThemeManager.shared.theme.warning
    }

    static var aicovenError: Color {
        ThemeManager.shared.theme.error
    }

    /// Initialize Color from hex string
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Typography

/// AICoven typography styles.
///
/// All `aicoven*` fonts route through `TypographyManager.shared.variant`
/// so a user-picked typography voice (Settings › Appearance › Typography)
/// applies everywhere at once. The default voice is `.system`, which keeps
/// the original behaviour: display-size type follows the active theme's
/// `displayFontDesign` (`.serif` on Apothecary / Grimoire, `.rounded` on
/// Nebula / Observatory / Orchard) and body / heading type stays on SF Pro
/// Text. Picking any other voice (Rounded / Bookish / Geometric / Classic
/// Sans / Reading Serif) overrides both display and body globally.
///
/// `aicovenMono` is intentionally not user-pickable: SF Mono is reserved
/// for model IDs, token counts, and code blocks, and substituting it would
/// break the No-Monospace-Cosplay Rule's intent (the monospace face is
/// identity, not preference).
extension Font {
    /// Every aicoven* font multiplies its base point size by
    /// `TypographyManager.shared.sizeScale.multiplier` so the user's
    /// Settings › Appearance › Typography › Size choice (Small / Default
    /// / Large / Extra Large) flows through the entire UI. Caption and
    /// mono are scaled too so chat metadata + code blocks stay in step
    /// with body copy at any size.
    private static var typographyScale: CGFloat {
        TypographyManager.shared.sizeScale.multiplier
    }

    /// Display styles — routed through the user's typography voice and
    /// (only when voice == .system) the active theme's display design.
    /// The `.custom` voice resolves through `TypographyManager.customFontFamily`.
    static var aicovenDisplayLarge: Font {
        TypographyManager.shared.variant.displayFont(
            size: 34 * typographyScale, weight: .bold,
            themeDesign: ThemeManager.shared.theme.displayFontDesign,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    static var aicovenDisplayMedium: Font {
        TypographyManager.shared.variant.displayFont(
            size: 28 * typographyScale, weight: .semibold,
            themeDesign: ThemeManager.shared.theme.displayFontDesign,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    static var aicovenDisplaySmall: Font {
        TypographyManager.shared.variant.displayFont(
            size: 24 * typographyScale, weight: .medium,
            themeDesign: ThemeManager.shared.theme.displayFontDesign,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    /// Heading styles — user-pickable; `.system` resolves to SF Pro Text.
    static var aicovenH1: Font {
        TypographyManager.shared.variant.bodyFont(
            size: 20 * typographyScale, weight: .semibold,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    static var aicovenH2: Font {
        TypographyManager.shared.variant.bodyFont(
            size: 17 * typographyScale, weight: .semibold,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    static var aicovenH3: Font {
        TypographyManager.shared.variant.bodyFont(
            size: 15 * typographyScale, weight: .medium,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    /// Body styles — user-pickable; `.system` resolves to SF Pro Text.
    static var aicovenBody: Font {
        TypographyManager.shared.variant.bodyFont(
            size: 15 * typographyScale, weight: .regular,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    static var aicovenBodyMedium: Font {
        TypographyManager.shared.variant.bodyFont(
            size: 15 * typographyScale, weight: .medium,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    static var aicovenBodySmall: Font {
        TypographyManager.shared.variant.bodyFont(
            size: 13 * typographyScale, weight: .regular,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    /// Caption — user-pickable.
    static var aicovenCaption: Font {
        TypographyManager.shared.variant.bodyFont(
            size: 12 * typographyScale, weight: .regular,
            customFontFamily: TypographyManager.shared.customFontFamily
        )
    }

    /// Mono — face is fixed (SF Mono is identity, not preference) but the
    /// size still tracks the user's overall scale so code blocks stay in
    /// step with body copy.
    static var aicovenMono: Font {
        .system(size: 13 * typographyScale, weight: .regular, design: .monospaced)
    }
}

// MARK: - Spacing

/// Consistent spacing values
enum Spacing {
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64
}

// MARK: - Border Radius

/// Consistent border radius values
enum BorderRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let circle: CGFloat = 999
}

// MARK: - Reusable Components

/// Glassmorphism card with subtle translucent backdrop.
///
/// Reserve `GlassCard` for moments where translucency is *meaningful* (over
/// the Nebula backdrop, over an image, over rich media). For settings rows,
/// sidebar sections, and onboarding info cards, prefer the flat `Panel`
/// below. Too many glass cards on a single screen reads as decorative
/// glassmorphism, which is a shared-design-laws anti-pattern.
struct GlassCard<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let content: Content
    let padding: CGFloat
    let cornerRadius: CGFloat

    init(
        padding: CGFloat = Spacing.md,
        cornerRadius: CGFloat = BorderRadius.lg,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.aicovenGlass)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                    )
            )
    }
}

/// Flat panel: the default container for settings rows, sidebar sections,
/// onboarding info cards, and any other grouping that does not need
/// translucency. Renders a solid `surfaceElevated` fill with a 1px hairline
/// `border` stroke. Theme-aware: Night Slab / Vellum Cream / Tallow /
/// Nautical Navy depending on the active theme.
struct Panel<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let content: Content
    let padding: CGFloat
    let cornerRadius: CGFloat

    init(
        padding: CGFloat = Spacing.md,
        cornerRadius: CGFloat = BorderRadius.lg,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.aicovenSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                    )
            )
    }
}

/// Primary action button that adapts to the active theme.
///
/// The original AICoven palette ("Nebula") keeps its teal→purple gradient so
/// existing screens look unchanged. Every other theme uses a flat accent —
/// gradients on buttons are one of the biggest "AI slop" tells, and the
/// other themes are intentionally designed to avoid them.
struct GradientButton: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let icon: String?
    let action: () -> Void
    let style: ButtonStyle

    enum ButtonStyle {
        case primary, secondary, ghost
    }

    init(
        _ title: String,
        icon: String? = nil,
        style: ButtonStyle = .primary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.action = action
        self.style = style
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.aicovenBodyMedium)
                }
                Text(title)
                    .font(.aicovenBodyMedium)
                    // Keep the label on a single line. Without this, in
                    // tight HStacks (e.g. the Memory Proposals card's
                    // Approve / Reject / Edit / Delete row on iPhone) the
                    // available width per button shrinks enough that
                    // SwiftUI wraps the label character-by-character —
                    // you end up with "A / p / p / r / o / v / e" stacked
                    // vertically. lineLimit(1) + fixedSize on the outer
                    // button forces the button to claim its intrinsic
                    // horizontal size and lets the parent layout scroll
                    // / overflow instead of squashing the text.
                    .lineLimit(1)
            }
            .foregroundColor(primaryForegroundColor)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(backgroundView)
            .cornerRadius(BorderRadius.md)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Text color for the label. White works on the dark Nebula gradient
    /// and the dark-theme flat accents, but on the light Apothecary theme
    /// we need a near-white readable on oxblood.
    private var primaryForegroundColor: Color {
        switch style {
        case .primary:
            // Oxblood / ember / brass are all dark enough that white reads well.
            .white
        case .secondary, .ghost:
            Color.aicovenTextPrimary
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .primary:
            if themeManager.theme.usesGradientPrimaryButton {
                LinearGradient(
                    colors: [Color.aicovenTeal, Color.aicovenPurple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                Color.aicovenTeal
            }
        case .secondary:
            Color.aicovenGlass
                .overlay(
                    RoundedRectangle(cornerRadius: BorderRadius.md)
                        .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                )
        case .ghost:
            Color.clear
        }
    }
}

/// Icon badge with an optional glow effect.
///
/// Glow is reserved for brand moments (splash, plan badges, upsell). For
/// settings rows, empty states, and anything on the main browsing surface,
/// pass `glowIntensity: 0` so the icon reads as chrome, not decoration.
struct IconBadge: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let size: CGFloat
    let color: Color
    let glowIntensity: CGFloat

    init(
        icon: String,
        size: CGFloat = 32,
        color: Color = .aicovenTeal,
        glowIntensity: CGFloat = 0.3
    ) {
        self.icon = icon
        self.size = size
        self.color = color
        self.glowIntensity = glowIntensity
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: size, height: size)
                .shadow(color: color.opacity(glowIntensity), radius: 8, x: 0, y: 0)

            Image(systemName: icon)
                .font(.system(size: size * 0.45))
                .foregroundColor(color)
        }
    }
}

/// Themed backdrop.
///
/// The name is retained so existing screens keep compiling. Rendering now
/// branches on the active theme's `backgroundStyle`:
///
/// - `.staticWash(...)`: a single soft radial wash over the surface (used by
///   Nebula, Grimoire, and Observatory so dark themes feel warm/cool/cosmic
///   without the trademark "AI" gradient‑orb glow).
/// - `.flat`: surface color only (used by the light Apothecary theme).
/// - `.nebula`: retained in the enum for backward compatibility but no
///   theme uses it after the distillation. Treated as `.flat` at render.
///
/// Respects the OS `AccessibilityReduceMotion` setting: when on, even the
/// low-effort radial wash is rendered at the same static position without
/// any transition animation on theme switches.
struct NebulaBackground: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Base surface color, provided by the active theme.
            Color.aicovenDark
                .ignoresSafeArea()

            themedBackdrop
        }
        .ignoresSafeArea()
        // A soft cross-fade when the user switches themes, skipped when the
        // OS Reduce Motion setting is on.
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.25),
            value: themeManager.theme.variant
        )
    }

    @ViewBuilder
    private var themedBackdrop: some View {
        switch themeManager.theme.backgroundStyle {
        case let .staticWash(tint, opacity):
            staticWashBackdrop(tint: tint, opacity: opacity)
        case let .paper(wash, washOpacity, vignetteOpacity):
            paperBackdrop(wash: wash, washOpacity: washOpacity, vignetteOpacity: vignetteOpacity)
        case .flat, .nebula:
            // `.nebula` is retained for backward compat but no theme uses it
            // after the Nebula distillation; render as flat so no orbits run.
            EmptyView()
        }
    }

    // MARK: Static wash (used by Nebula / Grimoire / Observatory)

    private func staticWashBackdrop(tint: Color, opacity: Double) -> some View {
        GeometryReader { proxy in
            #if os(iOS)
            let maxDimension = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
            #else
            let maxDimension = max(proxy.size.width, proxy.size.height)
            #endif

            RadialGradient(
                colors: [tint.opacity(opacity), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: maxDimension
            )
            .blur(radius: 40)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    // MARK: Paper / watercolor (used by Apothecary)

    /// A paper-and-pigment backdrop for the light Apothecary theme: a
    /// diagonal warm wash (top-left → bottom-right) in the given tint, plus
    /// a subtle dark vignette at the edges. The combination suggests an
    /// aged page with uneven pigment settle rather than a flat cream fill.
    /// All layers are decorative and non-interactive.
    private func paperBackdrop(
        wash: Color,
        washOpacity: Double,
        vignetteOpacity: Double
    ) -> some View {
        GeometryReader { proxy in
            #if os(iOS)
            let maxDimension = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
            #else
            let maxDimension = max(proxy.size.width, proxy.size.height)
            #endif

            ZStack {
                // Diagonal warm pigment wash — heavier at the top-left,
                // fading out through the centre, returning faintly at the
                // bottom-right. Mimics the uneven drying of a watercolor
                // wash across a page rather than a uniform fill.
                LinearGradient(
                    colors: [
                        wash.opacity(washOpacity),
                        Color.clear,
                        Color.clear,
                        wash.opacity(washOpacity * 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blur(radius: 60)
                .ignoresSafeArea()

                // Soft dark vignette: the corners fall off toward a
                // near-black warm tint (multiplied for gentle darkening),
                // suggesting an aged page with worn edges rather than a
                // uniformly-lit screen.
                RadialGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(vignetteOpacity)
                    ],
                    center: .center,
                    startRadius: maxDimension * 0.25,
                    endRadius: maxDimension * 0.85
                )
                .ignoresSafeArea()
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Role chip with brand styling.
struct RoleChip: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let name: String
    let icon: String?
    let color: Color

    init(name: String, icon: String? = nil, color: Color = .aicovenPurple) {
        self.name = name
        self.icon = icon
        self.color = color
    }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
            }
            Text(name)
                .font(.aicovenCaption)
                .fontWeight(.medium)
        }
        // The chip background is `color.opacity(0.3)` over the active
        // surface, which becomes a light tint on the parchment Apothecary
        // theme. White text vanishes there, so route the label through the
        // theme's primary text color instead — it stays white on the dark
        // themes and becomes warm ink on the light theme.
        .foregroundColor(.aicovenTextPrimary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
            Capsule()
                .fill(color.opacity(0.3))
                .overlay(
                    Capsule()
                        .strokeBorder(color.opacity(0.5), lineWidth: 1)
                )
        )
    }
}

/// Flat 1px divider. The name is retained so callers keep compiling, but
/// the implementation no longer uses a gradient: a hairline rule reads
/// cleaner in every theme and avoids the "decorative gradient" slop tell.
///
/// Default horizontal inset matches `Spacing.lg` so the rule breathes
/// away from the container edges; pass `inset: 0` for edge-to-edge rules.
struct GradientDivider: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let inset: CGFloat

    init(inset: CGFloat = Spacing.lg) {
        self.inset = inset
    }

    var body: some View {
        Rectangle()
            .fill(Color.aicovenBorder)
            .frame(height: 1)
            .padding(.horizontal, inset)
    }
}

// MARK: - View Extensions

extension View {
    /// Apply glass morphism effect (translucent + hairline border).
    /// Reserve for moments where translucency is actually doing work; for
    /// everything else, prefer `.panel(...)` below.
    func glassMorphism(cornerRadius: CGFloat = BorderRadius.lg, padding: CGFloat = Spacing.md) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.aicovenGlass)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                    )
            )
    }

    /// Flat panel treatment: solid `surfaceElevated` fill + 1px hairline
    /// border. Use this for settings rows, sidebar sections, onboarding
    /// info cards, and any grouping that does not need translucency. This
    /// is the default for non-chat surfaces.
    func panel(cornerRadius: CGFloat = BorderRadius.lg, padding: CGFloat = Spacing.md) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.aicovenSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                    )
            )
    }

    /// Apply glow effect
    func glowEffect(color: Color = .aicovenTeal, radius: CGFloat = 8, intensity: CGFloat = 0.5) -> some View {
        shadow(color: color.opacity(intensity), radius: radius, x: 0, y: 0)
    }
}

// MARK: - Preview

#Preview("Design System Components") {
    ZStack {
        NebulaBackground()

        VStack(spacing: Spacing.lg) {
            // Typography samples
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Display Large")
                    .font(.aicovenDisplayLarge)
                    .foregroundColor(.aicovenTextPrimary)

                Text("Heading 1")
                    .font(.aicovenH1)
                    .foregroundColor(.aicovenTextPrimary)

                Text("Body text with secondary color")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("Caption text")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }
            .glassMorphism()

            // Buttons
            HStack(spacing: Spacing.md) {
                GradientButton("Primary", icon: "plus", style: .primary) {}
                GradientButton("Secondary", style: .secondary) {}
                GradientButton("Ghost", style: .ghost) {}
            }

            // Icon badges
            HStack(spacing: Spacing.md) {
                IconBadge(icon: "sparkles", color: .aicovenTeal)
                IconBadge(icon: "message", color: .aicovenPurple)
                IconBadge(icon: "person", color: .aicovenPink)
            }

            // Role chips
            HStack(spacing: Spacing.xs) {
                RoleChip(name: "Coder", icon: "chevron.left.forwardslash.chevron.right")
                RoleChip(name: "Designer", icon: "paintbrush", color: .aicovenTeal)
                RoleChip(name: "Writer", icon: "doc.text", color: .aicovenPink)
            }
        }
        .padding(Spacing.xxl)
    }
}
