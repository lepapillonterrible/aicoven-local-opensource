import SwiftUI
internal import Combine

// MARK: - Theme Variant

/// Identifier for each available theme. Stored as a string in `UserDefaults`
/// under `aicoven_theme_id` so it survives app restarts without needing any
/// backend change.
enum ThemeVariant: String, CaseIterable, Identifiable, Codable {
    case nebula
    case apothecary
    case grimoire
    case observatory
    case orchard

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .nebula: "Nebula"
        case .apothecary: "Apothecary"
        case .grimoire: "Grimoire"
        case .observatory: "Observatory"
        case .orchard: "Orchard"
        }
    }

    /// One-line description surfaced in the theme picker.
    ///
    /// The taglines describe *when you would choose this theme*, not what
    /// the palette is. That's a lower-cognitive-load framing for a user who
    /// is scanning the previews; they don't need to know the colors, they
    /// need to know which one belongs on their screen right now.
    var tagline: String {
        switch self {
        case .nebula:
            "The original cosmic look"
        case .apothecary:
            "For daylight rooms and printerly focus"
        case .grimoire:
            "For late‑night deep work"
        case .observatory:
            "For cold, quiet concentration"
        case .orchard:
            "For sunlit, casual sessions"
        }
    }
}

// MARK: - Theme Model

/// All design tokens consumed by the app, grouped per theme.
///
/// The rest of the app continues to reference `Color.aicovenTeal`,
/// `Color.aicovenDark`, etc. — those are kept as computed aliases in
/// `DesignSystem.swift` that forward to the currently active theme.
struct AicovenTheme {
    let variant: ThemeVariant

    // Surfaces
    let surface: Color // Primary background (aicovenDark)
    let surfaceElevated: Color // Raised card background
    let glass: Color // aicovenGlass
    let border: Color // aicovenBorder
    let overlay: Color // aicovenOverlay

    // Text
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    // Accents
    let accentPrimary: Color // aicovenTeal alias
    let accentSecondary: Color // aicovenPurple alias
    let accentTertiary: Color // aicovenPink alias

    // Semantic
    let success: Color
    let warning: Color
    let error: Color

    // Behavior
    let preferredColorScheme: ColorScheme
    let usesGradientPrimaryButton: Bool
    let backgroundStyle: BackgroundStyle
    /// Font.Design used for display-size type (Display Large / Medium /
    /// Small). Body type stays `.default` across themes. Apothecary and
    /// Grimoire use `.serif` (New York) to evoke book / page; Nebula,
    /// Observatory, and Orchard stay on `.rounded` (SF Pro Rounded) for
    /// the cosmic / cold / casual moods respectively.
    let displayFontDesign: Font.Design

    /// Backdrop treatment used by `NebulaBackground`.
    enum BackgroundStyle: Equatable {
        /// Original animated radial blobs (respects the user's
        /// `aicoven_animated_backgrounds` preference).
        case nebula
        /// A single static radial wash in the given tint over the surface.
        case staticWash(tint: Color, opacity: Double)
        /// Solid surface color only — no decoration.
        case flat
        /// A paper / watercolor treatment: the surface color plus a
        /// diagonal pigment wash in the given tint and a subtle dark
        /// vignette at the edges, suggesting an aged page rather than a
        /// flat fill. Used by Apothecary to escape the "flat SaaS cream"
        /// feel that pure `.flat` produces on a light theme.
        case paper(wash: Color, washOpacity: Double, vignetteOpacity: Double)
    }

    var id: String {
        variant.id
    }

    var displayName: String {
        variant.displayName
    }

    var tagline: String {
        variant.tagline
    }
}

// MARK: - Theme Palettes

extension AicovenTheme {
    /// Legacy AICoven palette (teal / purple / pink on near‑black).
    ///
    /// Preserved for users who had already chosen it before the four-theme
    /// system shipped. *No longer the default for new installs* and its
    /// AI-slop tells have been removed: the primary button is a flat fill
    /// (no teal→purple gradient), the backdrop is a single static teal wash
    /// (no animated orbs), and the text neutrals are tinted warm off-white
    /// instead of pure white so the theme doesn't read as generic OS chrome.
    static let nebula = AicovenTheme(
        variant: .nebula,
        surface: Color(hex: "#0D0C0E"),
        surfaceElevated: Color(hex: "#1E1E1E"),
        glass: Color(hex: "#F5F2ED").opacity(0.08),
        border: Color(hex: "#F5F2ED").opacity(0.14),
        overlay: Color.black.opacity(0.4),
        textPrimary: Color(hex: "#F5F2ED"), // Warm off-white, not #FFFFFF
        textSecondary: Color(hex: "#F5F2ED").opacity(0.72),
        textTertiary: Color(hex: "#F5F2ED").opacity(0.55),
        accentPrimary: Color(hex: "#30FFC4"),
        accentSecondary: Color(hex: "#9C5FFF"),
        accentTertiary: Color(hex: "#BE5AF8"),
        success: Color(hex: "#30FFC4"),
        warning: Color(hex: "#FFB930"),
        error: Color(hex: "#FF3030"),
        preferredColorScheme: .dark,
        usesGradientPrimaryButton: false,
        backgroundStyle: .staticWash(tint: Color(hex: "#30FFC4"), opacity: 0.10),
        displayFontDesign: .rounded
    )

    /// Light, printerly. User-locked palette of five exact hex values
    /// referenced from the Daydream Apothecary world: Cara Cara terracotta,
    /// Smoked Out steel blue, Gotham near-pure ink, white, and Sunflower
    /// gold. The white surface plus near-pure ink reads more "fresh print"
    /// than "aged parchment"; the `paper` backdrop adds a warm Cara Cara
    /// pigment wash and edge vignette so the white page still feels worn
    /// and hand-coloured rather than clinical.
    ///
    /// Note on `#FFFFFF`: the shared design laws normally forbid pure
    /// white as a surface. This theme honours an explicit user request
    /// for that exact value; the warm wash and vignette overlaid on top
    /// keep it from reading as OS-default chrome.
    ///
    /// Color-blind note: Cara Cara (`#A44A1C`) and Sunflower (`#FCB020`)
    /// are both warm oranges / golds that can converge for deuteranopia.
    /// Whenever primary and tertiary / warning accents appear in the same
    /// visual group, pair color with a glyph, weight shift, or text label;
    /// do not rely on color alone.
    static let apothecary = AicovenTheme(
        variant: .apothecary,
        surface: Color(hex: "#FFFFFF"),
        // A warm cream insert (Sunflower-tinted) so cards, bubbles, and
        // panels read as a separate "vellum insert" laid on the white page
        // rather than the same fill at a slightly different lightness.
        surfaceElevated: Color(hex: "#F4EFE2"),
        glass: Color(hex: "#090703").opacity(0.05),
        border: Color(hex: "#D9D2C4"),
        overlay: Color(hex: "#090703").opacity(0.3),
        textPrimary: Color(hex: "#090703"), // Gotham
        textSecondary: Color(hex: "#090703").opacity(0.72),
        textTertiary: Color(hex: "#090703").opacity(0.60),
        accentPrimary: Color(hex: "#A44A1C"), // Cara Cara
        accentSecondary: Color(hex: "#3E707F"), // Smoked Out
        accentTertiary: Color(hex: "#FCB020"), // Sunflower
        // Sage Moss is retained only as the success semantic; green-equals
        // -OK is universal and the user's reference palette has no green
        // of its own. Muted enough to live beside Cara Cara and Smoked
        // Out without shouting.
        success: Color(hex: "#6B8058"),
        warning: Color(hex: "#FCB020"), // Sunflower doubles as warning
        error: Color(hex: "#A44A1C"), // Cara Cara for alarm
        preferredColorScheme: .light,
        usesGradientPrimaryButton: false,
        // Paper treatment: diagonal Cara Cara pigment wash + soft dark
        // vignette at the edges. The wash is what saves the white surface
        // from reading as a clinical app screen and carries the
        // watercolor-apothecary feel.
        backgroundStyle: .paper(
            wash: Color(hex: "#A44A1C"),
            washOpacity: 0.08,
            vignetteOpacity: 0.08
        ),
        displayFontDesign: .serif
    )

    /// Dark, warm. Illuminated-manuscript grimoire: deep printer's black
    /// (Ink Well) with warm vellum text, lit by the user's chosen palette
    /// of gilded gold, frost slate, mulberry, codex teal, and aged sienna.
    /// Reads less "oil-lamp SaaS" and less "wax seal forum"; closer to a
    /// Bodleian exhibition catalogue: jewel-tone inks on aged paper, with
    /// sienna stitching between elements rather than gray hairlines.
    ///
    /// User-locked palette (five exact hex values supplied as references):
    /// - `#CC8405` Manuscript Gold (primary accent + warning)
    /// - `#6697AB` Frost Slate (secondary accent)
    /// - `#7F4571` Mulberry (tertiary accent + error)
    /// - `#027976` Codex Teal (success)
    /// - `#61300D` Aged Sienna (border / seam)
    ///
    /// Color-blind note: Manuscript Gold (`#CC8405`) is a warm orange-
    /// yellow that can converge with sienna-tinted browns for protanopia,
    /// and Frost Slate vs Codex Teal can read similar for users with
    /// blue / green confusion. The primary vs warning slots share the
    /// same hex on purpose; whenever primary, success, and error chips
    /// appear together, pair color with a glyph or weight shift so users
    /// who can't separate gold from teal still parse the meaning.
    static let grimoire = AicovenTheme(
        variant: .grimoire,
        surface: Color(hex: "#11100E"), // Ink Well
        surfaceElevated: Color(hex: "#1C1A16"), // Inked Tallow
        glass: Color(hex: "#F3E9D1").opacity(0.06),
        // Aged Sienna replaces the near-black hairline. Warmer seam between
        // elements; reads as inked stitching on paper instead of a thin
        // dark gray rule.
        border: Color(hex: "#61300D"), // Aged Sienna
        overlay: Color.black.opacity(0.4),
        textPrimary: Color(hex: "#F3E9D1"), // Warm Vellum
        textSecondary: Color(hex: "#F3E9D1").opacity(0.72),
        textTertiary: Color(hex: "#F3E9D1").opacity(0.55),
        accentPrimary: Color(hex: "#CC8405"), // Manuscript Gold
        accentSecondary: Color(hex: "#6697AB"), // Frost Slate
        accentTertiary: Color(hex: "#7F4571"), // Mulberry
        success: Color(hex: "#027976"), // Codex Teal
        warning: Color(hex: "#CC8405"), // Manuscript Gold doubles as warning
        error: Color(hex: "#7F4571"), // Mulberry doubles as error
        preferredColorScheme: .dark,
        usesGradientPrimaryButton: false,
        // Static wash retuned to the new gold accent. 8% over Ink Well
        // gives a faint top-of-page glow that reads as candlelight on
        // gilded ink without saturating the surface.
        backgroundStyle: .staticWash(tint: Color(hex: "#CC8405"), opacity: 0.08),
        // Grimoire is bookish like Apothecary; both use the serif display
        // face to evoke a page instead of an app screen.
        displayFontDesign: .serif
    )

    /// Deep night. Cold, quiet concentration on the Midnight Tide navy
    /// surface, lit by the user's chosen palette of Cassini Teal,
    /// Mars Coral, and Pulsar Yellow. Trades the previous brass / slate
    /// / muted-cinnabar trio for three saturated celestial signals: the
    /// turquoise of telescope-mirror coatings, the coral of a dust-storm
    /// planet, and the pulsing yellow of a star catalogue.
    ///
    /// User-locked palette (three exact hex values supplied as references):
    /// - `#10888D` Cassini Teal (primary accent + success)
    /// - `#F1433F` Mars Coral (secondary accent + error)
    /// - `#F7E966` Pulsar Yellow (tertiary accent + warning)
    ///
    /// Slot assignment is contrast-driven, not aesthetic preference:
    /// `accentSecondary` becomes the user chat bubble background, which
    /// hosts white text. Pulsar Yellow at ~88% luminance would render
    /// white text invisible there, so yellow is parked in `accentTertiary`
    /// and used only as a signal color (focus rings, plan badges,
    /// selected-state markers) where nothing sits on top of it. Mars
    /// Coral and Cassini Teal both clear AA-Large with white text and
    /// approach normal AA, matching the contrast profile of the previous
    /// brass / cinnabar pair.
    ///
    /// Color-blind note: Mars Coral (`#F1433F`) and Pulsar Yellow
    /// (`#F7E966`) sit far apart in luminance but both lean warm; under
    /// strong protanopia they can blur into a single "warm signal." Pair
    /// alarm + warning chips that appear together with a glyph or weight
    /// shift, never color alone.
    static let observatory = AicovenTheme(
        variant: .observatory,
        surface: Color(hex: "#0E1622"), // Midnight Tide
        surfaceElevated: Color(hex: "#131E2E"), // Nautical Navy
        glass: Color(hex: "#EDE6D8").opacity(0.05),
        border: Color(hex: "#1B2736"),
        overlay: Color.black.opacity(0.4),
        textPrimary: Color(hex: "#EDE6D8"), // Bone
        textSecondary: Color(hex: "#EDE6D8").opacity(0.72),
        textTertiary: Color(hex: "#EDE6D8").opacity(0.5),
        accentPrimary: Color(hex: "#10888D"), // Cassini Teal
        accentSecondary: Color(hex: "#F1433F"), // Mars Coral
        accentTertiary: Color(hex: "#F7E966"), // Pulsar Yellow
        success: Color(hex: "#10888D"), // Cassini Teal doubles as success
        warning: Color(hex: "#F7E966"), // Pulsar Yellow doubles as warning
        error: Color(hex: "#F1433F"), // Mars Coral doubles as error
        preferredColorScheme: .dark,
        usesGradientPrimaryButton: false,
        // Static wash retuned to Cassini Teal at 8%. The teal halo at the
        // top of the page reads as horizon glow over an ocean of navy,
        // matching the new primary accent.
        backgroundStyle: .staticWash(tint: Color(hex: "#10888D"), opacity: 0.08),
        displayFontDesign: .rounded
    )

    /// Light, citrus. Mediterranean breakfast palette: a cool Sea Glass
    /// surface, warm Tangerine and Marigold highlights, and Butterscotch
    /// for the soft tertiary moments. Lit by the user-supplied reference
    /// of orange-on-teal-on-white-on-orange. Reads as a sunlit kitchen
    /// counter: bright, casual, unhurried; the daytime sibling to
    /// Apothecary's printerly focus.
    ///
    /// User-locked palette (five exact hex values supplied as references):
    /// - `#C0DEDF` Sea Glass (surface)
    /// - `#3C9A9E` Glazed Teal (primary accent + success)
    /// - `#F4790D` Tangerine (secondary accent + error)
    /// - `#FE8E17` Marigold (warning)
    /// - `#F4BE6B` Butterscotch (tertiary accent)
    ///
    /// Slot assignment is contrast-driven, like Observatory:
    /// `accentPrimary` is the calm Glazed Teal because the primary button
    /// hosts white text and only teal in this palette is dark enough to
    /// clear AA there. Tangerine takes the secondary slot; white on
    /// Tangerine sits at ~3:1, marginal but consistent with how Frost
    /// Slate is already used as Grimoire's user-bubble background.
    /// Butterscotch never hosts text on top of it; it is reserved for
    /// plan badges, soft callouts, and selected-state markers.
    ///
    /// Two derived neutrals are needed because the user palette has no
    /// near-black ink and no muted elevated surface: Deep Lagoon
    /// (`#1A2A2C`) is a teal-tinted ink that ties the text family back
    /// to the Glazed Teal accent rather than importing Apothecary's
    /// Gotham, and Butter Cream (`#E8DCC2`) is a desaturated Butterscotch
    /// vellum laid on the Sea Glass page so cards and bubbles read as a
    /// warm insert on a cool surface (echoing the white plate inside the
    /// teal dish on the orange ground in the source image).
    ///
    /// Color-blind note: Tangerine (`#F4790D`), Marigold (`#FE8E17`), and
    /// Butterscotch (`#F4BE6B`) all sit in the warm orange / amber band.
    /// They are separated mostly by luminance rather than hue, which is
    /// fragile under protanopia and deuteranopia. Whenever primary,
    /// warning, and tertiary accents appear in the same visual group,
    /// pair color with a glyph or weight shift so meaning still parses
    /// when the warm trio collapses into a single tone.
    static let orchard = AicovenTheme(
        variant: .orchard,
        surface: Color(hex: "#C0DEDF"), // Sea Glass
        // Butter Cream: a desaturated Butterscotch derived as a warm
        // "vellum insert" on the cool Sea Glass page. Mirrors the
        // surface-vs-elevated contrast strategy used in Apothecary.
        surfaceElevated: Color(hex: "#E8DCC2"),
        glass: Color(hex: "#1A2A2C").opacity(0.05),
        // Misty Hairline: a darker Sea Glass for the 1px border so the
        // seam between page and elevated surfaces sits in the same
        // family as the surface rather than introducing a fourth hue.
        border: Color(hex: "#A8C4C6"),
        overlay: Color(hex: "#1A2A2C").opacity(0.3),
        textPrimary: Color(hex: "#1A2A2C"), // Deep Lagoon
        textSecondary: Color(hex: "#1A2A2C").opacity(0.72),
        textTertiary: Color(hex: "#1A2A2C").opacity(0.60),
        accentPrimary: Color(hex: "#3C9A9E"), // Glazed Teal
        accentSecondary: Color(hex: "#F4790D"), // Tangerine
        accentTertiary: Color(hex: "#F4BE6B"), // Butterscotch
        success: Color(hex: "#3C9A9E"), // Glazed Teal doubles as success
        warning: Color(hex: "#FE8E17"), // Marigold
        error: Color(hex: "#F4790D"), // Tangerine doubles as error
        preferredColorScheme: .light,
        usesGradientPrimaryButton: false,
        // Paper backdrop in Tangerine at 6%. Lower opacity than
        // Apothecary's Cara Cara wash because Sea Glass is already a
        // tinted surface; layering a saturated wash too heavily would
        // turn the page muddy. The vignette is also dialled back to 6%.
        backgroundStyle: .paper(
            wash: Color(hex: "#F4790D"),
            washOpacity: 0.06,
            vignetteOpacity: 0.06
        ),
        // Casual / sunny mood reads better in rounded than serif; serif
        // would make a citrus-bright theme feel formal in a way the
        // reference image clearly is not.
        displayFontDesign: .rounded
    )

    /// All themes in display order for the picker. Orchard appended after
    /// Observatory so the existing four-theme order is unchanged for
    /// users who memorised it; new theme lands at the end.
    static let all: [AicovenTheme] = [.nebula, .apothecary, .grimoire, .observatory, .orchard]

    /// Lookup helper.
    static func theme(for variant: ThemeVariant) -> AicovenTheme {
        switch variant {
        case .nebula: .nebula
        case .apothecary: .apothecary
        case .grimoire: .grimoire
        case .observatory: .observatory
        case .orchard: .orchard
        }
    }
}

// MARK: - Theme Manager

/// Owns the currently-active theme and persists the user's selection.
///
/// Views that want to re-render when the theme changes should either observe
/// this manager (`@ObservedObject`) or rely on the app-level `.id(...)`
/// rebuild applied in `AICovenApp`. The per-color aliases on `Color`
/// (`aicovenTeal`, `aicovenDark`, …) read from `ThemeManager.shared.theme`
/// at render time, so any view that re-evaluates its body picks up the new
/// palette automatically.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private static let storageKey = "aicoven_theme_id"

    @Published private(set) var theme: AicovenTheme

    /// Convenience accessor for the active variant id.
    var variant: ThemeVariant {
        theme.variant
    }

    private init() {
        // New installs land on Apothecary: a committed daytime palette that
        // embodies the PRODUCT.md positioning (serious, deliberate, private)
        // instead of the legacy Nebula look, which is the exact "AI SaaS"
        // aesthetic this product explicitly rejects.
        // Existing users who previously picked Nebula keep Nebula; only
        // first-time installs with no stored selection get Apothecary.
        let storedId = UserDefaults.standard.string(forKey: Self.storageKey)
        let variant = storedId.flatMap { ThemeVariant(rawValue: $0) } ?? .apothecary
        theme = .theme(for: variant)
    }

    /// Switch to the given theme and persist the choice.
    func setVariant(_ variant: ThemeVariant) {
        guard variant != theme.variant else { return }
        UserDefaults.standard.set(variant.rawValue, forKey: Self.storageKey)
        theme = .theme(for: variant)
    }
}

extension EnvironmentValues {
    // Active theme, injected at the app root so deep views can read tokens
    // without reaching into `ThemeManager.shared` directly.
    @Entry var aicovenTheme: AicovenTheme = .nebula
}

// MARK: - View Helpers

/// Applies the active theme's preferred color scheme. Intended to replace
/// hard-coded `.preferredColorScheme(.dark)` calls throughout the app so
/// that switching to the light Apothecary theme actually takes effect.
struct ThemedColorScheme: ViewModifier {
    @ObservedObject private var themeManager = ThemeManager.shared

    func body(content: Content) -> some View {
        content.preferredColorScheme(themeManager.theme.preferredColorScheme)
    }
}

extension View {
    /// Honour the active theme's preferred color scheme (light vs dark).
    func themedColorScheme() -> some View {
        modifier(ThemedColorScheme())
    }
}
