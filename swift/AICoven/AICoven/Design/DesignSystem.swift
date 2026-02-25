import SwiftUI

// MARK: - Brand Colors

/// AICoven brand color palette
extension Color {
    // Primary brand colors
    static let aicovenTeal = Color(hex: "#30FFC4") // Primary accent - cyan/teal
    static let aicovenPurple = Color(hex: "#9C5FFF") // Secondary accent - purple
    static let aicovenPink = Color(hex: "#BE5AF8") // Tertiary accent - pink
    static let aicovenDark = Color(hex: "#0D0C0E") // Dark background

    // UI colors
    static let aicovenGlass = Color.white.opacity(0.08) // Glassmorphism
    static let aicovenBorder = Color.white.opacity(0.12) // Borders
    static let aicovenOverlay = Color.black.opacity(0.4) // Overlays

    // Text colors
    static let aicovenTextPrimary = Color.white
    static let aicovenTextSecondary = Color.white.opacity(0.7)
    static let aicovenTextTertiary = Color.white.opacity(0.5)

    // Semantic colors
    static let aicovenSuccess = Color(hex: "#30FFC4")
    static let aicovenWarning = Color(hex: "#FFB930")
    static let aicovenError = Color(hex: "#FF3030")

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

/// AICoven typography styles
extension Font {
    // Display styles
    static let aicovenDisplayLarge = Font.system(size: 34, weight: .bold, design: .rounded)
    static let aicovenDisplayMedium = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let aicovenDisplaySmall = Font.system(size: 24, weight: .medium, design: .rounded)

    // Heading styles
    static let aicovenH1 = Font.system(size: 20, weight: .semibold, design: .default)
    static let aicovenH2 = Font.system(size: 17, weight: .semibold, design: .default)
    static let aicovenH3 = Font.system(size: 15, weight: .medium, design: .default)

    // Body styles
    static let aicovenBody = Font.system(size: 15, weight: .regular, design: .default)
    static let aicovenBodyMedium = Font.system(size: 15, weight: .medium, design: .default)
    static let aicovenBodySmall = Font.system(size: 13, weight: .regular, design: .default)

    // Utility styles
    static let aicovenCaption = Font.system(size: 12, weight: .regular, design: .default)
    static let aicovenMono = Font.system(size: 13, weight: .regular, design: .monospaced)
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

/// Glassmorphism card with subtle backdrop blur
struct GlassCard<Content: View>: View {
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

/// Gradient button with brand colors
struct GradientButton: View {
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
            }
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(backgroundView)
            .cornerRadius(BorderRadius.md)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .primary:
            LinearGradient(
                colors: [Color.aicovenTeal, Color.aicovenPurple],
                startPoint: .leading,
                endPoint: .trailing
            )
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

/// Icon badge with glow effect
struct IconBadge: View {
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

/// Nebula background gradient
///
/// Uses the view's geometry to scale radial gradients so they fully cover
/// any screen size (iPhone, iPad, macOS window) without hard‑coded radii.
struct NebulaBackground: View {
    @AppStorage("aicoven_animated_backgrounds") private var animatedBackgrounds = false
    @State private var animateGradient = false

    var body: some View {
        GeometryReader { proxy in
            let maxDimension = max(proxy.size.width, proxy.size.height)
            let primaryRadius = maxDimension * 1.2
            let secondaryRadius = maxDimension * 1.0
            let accentRadius = maxDimension * 0.8

            ZStack {
                // Base dark background
                Color.aicovenDark
                    .ignoresSafeArea()

                if animatedBackgrounds {
                    animatedLayers(
                        primaryRadius: primaryRadius,
                        secondaryRadius: secondaryRadius,
                        accentRadius: accentRadius
                    )
                } else {
                    staticLayers(
                        primaryRadius: primaryRadius,
                        secondaryRadius: secondaryRadius,
                        accentRadius: accentRadius
                    )
                }
            }
            .onAppear {
                // Start or stop the gradient animation based on the current
                // preference. This ensures that when the view first appears it
                // respects the stored value.
                animateGradient = animatedBackgrounds
            }
            .onChange(of: animatedBackgrounds) { _, newValue in
                // If the user toggles the nebula animation setting while this
                // background is already on screen, react immediately by
                // starting/stopping the animation so there are no stale states
                // on specific screens like Covens.
                animateGradient = newValue
            }
        }
        .ignoresSafeArea()
    }

    /// Animated gradient layers for the nebula background
    @ViewBuilder
    private func animatedLayers(
        primaryRadius: CGFloat,
        secondaryRadius: CGFloat,
        accentRadius: CGFloat
    ) -> some View {
        // Animated nebula gradients
        RadialGradient(
            colors: [
                Color.aicovenTeal.opacity(0.3),
                Color.clear
            ],
            center: animateGradient ? .topLeading : .bottomTrailing,
            startRadius: 0,
            endRadius: primaryRadius
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: animateGradient)

        RadialGradient(
            colors: [
                Color.aicovenPurple.opacity(0.3),
                Color.clear
            ],
            center: animateGradient ? .topTrailing : .bottomLeading,
            startRadius: 0,
            endRadius: secondaryRadius
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 10).repeatForever(autoreverses: true), value: animateGradient)

        RadialGradient(
            colors: [
                Color.aicovenPink.opacity(0.2),
                Color.clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: accentRadius
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 12).repeatForever(autoreverses: true), value: animateGradient)
    }

    /// Static (non-animating) gradient layers for the nebula background
    @ViewBuilder
    private func staticLayers(
        primaryRadius: CGFloat,
        secondaryRadius: CGFloat,
        accentRadius: CGFloat
    ) -> some View {
        RadialGradient(
            colors: [
                Color.aicovenTeal.opacity(0.3),
                Color.clear
            ],
            center: .topLeading,
            startRadius: 0,
            endRadius: primaryRadius
        )
        .ignoresSafeArea()

        RadialGradient(
            colors: [
                Color.aicovenPurple.opacity(0.3),
                Color.clear
            ],
            center: .topTrailing,
            startRadius: 0,
            endRadius: secondaryRadius
        )
        .ignoresSafeArea()

        RadialGradient(
            colors: [
                Color.aicovenPink.opacity(0.2),
                Color.clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: accentRadius
        )
        .ignoresSafeArea()
    }
}

/// Role chip with brand styling
struct RoleChip: View {
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
        .foregroundColor(.white)
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

/// Divider with gradient
struct GradientDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.aicovenBorder,
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

// MARK: - View Extensions

extension View {
    /// Apply glass morphism effect
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
