import SwiftUI
internal import Combine

// MARK: - Typography Size Scale

/// User-selectable text-size multiplier applied globally on top of the
/// active typography variant. Independent of voice and theme.
///
/// Implemented as a small enum rather than a free-form CGFloat slider so
/// the picker UI stays tappable and predictable, and so we can reason
/// about extreme values — OpenDyslexic at 1.5x is genuinely useful for
/// some readers, OpenDyslexic at 0.6x is illegible and we never want to
/// expose that as an option.
enum TypographySizeScale: String, CaseIterable, Identifiable, Codable {
    case small
    case `default`
    case large
    case extraLarge

    var id: String {
        rawValue
    }

    /// Multiplier applied to every base point size in `Font.aicoven*`.
    var multiplier: CGFloat {
        switch self {
        case .small: 0.9
        case .default: 1.0
        case .large: 1.15
        case .extraLarge: 1.30
        }
    }

    var displayName: String {
        switch self {
        case .small: "Small"
        case .default: "Default"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// Short symbol used in compact UI (segmented picker labels).
    var compactLabel: String {
        switch self {
        case .small: "A⁻"
        case .default: "A"
        case .large: "A⁺"
        case .extraLarge: "A⁺⁺"
        }
    }
}

// MARK: - Typography Variant

/// User-selectable typography "voice." Each variant pairs a display
/// treatment (used for `aicovenDisplay*`) with a body treatment (used for
/// `aicovenH1`, `aicovenBody`, etc.) so callers don't have to think about
/// font roles individually.
///
/// Most options use fonts that are pre-installed on iOS 13+ and
/// macOS 10.15+, honoring the principle that AICoven never ships
/// *decorative* typefaces in its bundle and never loads webfonts.
///
/// `.custom` lets users pick any font already installed on their device
/// through the OS (Settings › Fonts on iOS, Font Book on macOS) — the app
/// still ships zero font binaries on that path, it just resolves a family
/// by name.
///
/// `.dyslexic` is the single permitted exception to the no-shipped-fonts
/// rule. OpenDyslexic 3 (SIL OFL 1.1, Regular + Bold) is bundled in
/// `Resources/Fonts/` and registered with CoreText at app launch via
/// `FontRegistration.register()`. We ship version 3 rather than the
/// classic v0.91.x line because v3 has tighter letter spacing while
/// preserving the bottom-weighted, distinctive letterforms that drive
/// the accessibility benefit — classic OpenDyslexic reads as
/// "every-letter-in-its-own-column" at chat sizes. The exception itself
/// is justified on accessibility grounds: requiring a user with dyslexia
/// to install a third-party font installer before they can read the app
/// comfortably defeats the point. Same category as VoiceOver and Dynamic
/// Type, not the same category as a brand serif. License attribution
/// lives in `Resources/Fonts/OFL.txt` and is surfaced to users in
/// Settings › About.
///
/// `.system` is the default and falls through to the active theme's
/// `displayFontDesign` for display-size type. Picking any other variant
/// overrides the theme's display preference globally.
enum TypographyVariant: String, CaseIterable, Identifiable, Codable {
    /// Theme-driven default. Display follows `theme.displayFontDesign`,
    /// body uses SF Pro Text. The original four-theme behaviour.
    case system

    /// SF Pro Rounded for both display and body. Soft, approachable;
    /// pairs well with Nebula / Observatory / Orchard.
    case rounded

    /// New York for display and body. Editorial / book voice; the
    /// system serif Apple ships on iOS 13+ and macOS 10.15+. Pairs
    /// well with Apothecary and Grimoire.
    case bookish

    /// Avenir Next throughout. A geometric humanist sans that reads as
    /// "modern but not corporate," differentiated from SF without
    /// becoming nostalgic.
    case geometric

    /// Helvetica Neue throughout. A safe, classic sans that some users
    /// simply prefer for body text density. Pre-installed on every
    /// Apple platform.
    case classicSans

    /// Georgia throughout. A web-classic serif designed for screen
    /// reading. Heavier and warmer than New York; useful for
    /// long-form-heavy sessions.
    case readingSerif

    /// OpenDyslexic 3. The only typeface AICoven ships in its bundle.
    /// Resolves via PostScript name (`OpenDyslexicThree-Regular` /
    /// `OpenDyslexicThree-Bold`) after `FontRegistration.register()`
    /// has run — which it has, because `TypographyManager`'s singleton
    /// init triggers it before any view reads `Font.aicoven*`.
    case dyslexic

    /// User-picked font family. The actual family name lives on
    /// `TypographyManager.shared.customFontFamily` because it is a
    /// runtime string, not a compile-time enum value. Selecting this
    /// variant without a family stored falls back to `.system` so the
    /// UI never renders into the void.
    case custom

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .bookish: "Bookish"
        case .geometric: "Geometric"
        case .classicSans: "Classic Sans"
        case .readingSerif: "Reading Serif"
        case .dyslexic: "OpenDyslexic"
        case .custom: "Custom"
        }
    }

    /// Short caption shown under the variant name in the picker. Like
    /// the theme tagline, this describes *when you would choose this
    /// voice*, not which font names are inside it.
    var tagline: String {
        switch self {
        case .system: "Follow the active theme"
        case .rounded: "Soft, approachable"
        case .bookish: "Editorial, page‑like"
        case .geometric: "Modern humanist"
        case .classicSans: "Dense, classical"
        case .readingSerif: "Long‑form reading"
        case .dyslexic: "Designed for dyslexic readers"
        case .custom: "Any font installed on this device"
        }
    }

    // MARK: - Font construction

    /// Display-size font (used by `aicovenDisplayLarge` / Medium / Small).
    ///
    /// `themeDesign` is the active theme's `displayFontDesign`; it is only
    /// consulted when `self == .system` (or when `.custom` has no family
    /// stored), so themes still set a sensible default for users who never
    /// touch the typography picker.
    ///
    /// `customFontFamily` is only consulted when `self == .custom`. It is
    /// the name of an OS-installed font family (e.g. `"Iowan Old Style"`).
    /// If `nil` or empty, this variant is treated as `.system` so the UI
    /// never silently renders nothing.
    func displayFont(
        size: CGFloat,
        weight: Font.Weight,
        themeDesign: Font.Design,
        customFontFamily: String? = nil
    ) -> Font {
        switch self {
        case .system:
            return .system(size: size, weight: weight, design: themeDesign)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        case .bookish:
            return .system(size: size, weight: weight, design: .serif)
        case .geometric:
            return Self.avenirNextFont(size: size, weight: weight)
        case .classicSans:
            return Self.helveticaNeueFont(size: size, weight: weight)
        case .readingSerif:
            return Self.georgiaFont(size: size, weight: weight)
        case .dyslexic:
            // OpenDyslexic 3 ships only Regular and Bold. We resolve by
            // PostScript name explicitly so SwiftUI doesn't synthesize a
            // "fake" semibold / medium between the two faces; semibold+
            // resolves to Bold, anything below resolves to Regular.
            return Self.openDyslexicFont(size: size, weight: weight)
        case .custom:
            if let family = customFontFamily, !family.isEmpty {
                return .custom(family, size: size).weight(weight)
            }
            return .system(size: size, weight: weight, design: themeDesign)
        }
    }

    /// Body-size font (used by `aicovenH1` through `aicovenCaption`).
    ///
    /// `.system` always uses SF Pro Text at body sizes regardless of theme;
    /// body type stays neutral so chat / settings / chrome don't take on
    /// the theme's display character.
    ///
    /// `customFontFamily` is only consulted when `self == .custom`. If
    /// `nil` or empty, this variant is treated as `.system`.
    func bodyFont(
        size: CGFloat,
        weight: Font.Weight,
        customFontFamily: String? = nil
    ) -> Font {
        switch self {
        case .system:
            return .system(size: size, weight: weight, design: .default)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        case .bookish:
            return .system(size: size, weight: weight, design: .serif)
        case .geometric:
            return Self.avenirNextFont(size: size, weight: weight)
        case .classicSans:
            return Self.helveticaNeueFont(size: size, weight: weight)
        case .readingSerif:
            return Self.georgiaFont(size: size, weight: weight)
        case .dyslexic:
            return Self.openDyslexicFont(size: size, weight: weight)
        case .custom:
            if let family = customFontFamily, !family.isEmpty {
                return .custom(family, size: size).weight(weight)
            }
            return .system(size: size, weight: weight, design: .default)
        }
    }

    /// Resolves an OpenDyslexic 3 face by PostScript name based on the
    /// requested weight. The font ships only Regular (400) and Bold
    /// (700); we map any weight at or above semibold (600) to the Bold
    /// face and everything else to Regular. We deliberately avoid the
    /// `Font.custom(family).weight(...)` form because the two faces
    /// register under slightly different `family` strings ("OpenDyslexic
    /// 3" with a space for Regular, "OpenDyslexic3" without for Bold),
    /// and family-trait matching can fail or synthesize a fake weight.
    private static func openDyslexicFont(size: CGFloat, weight: Font.Weight) -> Font {
        let postScript = switch weight {
        case .semibold, .bold, .heavy, .black:
            "OpenDyslexicThree-Bold"
        default:
            "OpenDyslexicThree-Regular"
        }
        return .custom(postScript, size: size)
    }

    /// Resolves an Avenir Next face by PostScript name based on the
    /// requested weight.
    ///
    /// Avenir Next ships as a family of named PostScript faces, not a
    /// variable font, so `.custom("AvenirNext", size:).weight(...)`
    /// asks SwiftUI to look up the face by OS/2 weight axis at render
    /// time. That lookup is unreliable on macOS — some intermediate
    /// weights resolve to nothing and SwiftUI emits the noisy
    /// "Unable to update Font Descriptor's weight" warnings to the
    /// console. Picking the PostScript name explicitly avoids the
    /// lookup entirely and keeps the console clean.
    private static func avenirNextFont(size: CGFloat, weight: Font.Weight) -> Font {
        let postScript = switch weight {
        case .ultraLight, .thin, .light:
            "AvenirNext-UltraLight"
        case .medium:
            "AvenirNext-Medium"
        case .semibold:
            "AvenirNext-DemiBold"
        case .bold:
            "AvenirNext-Bold"
        case .heavy, .black:
            "AvenirNext-Heavy"
        default: // .regular and any future case
            "AvenirNext-Regular"
        }
        return .custom(postScript, size: size)
    }

    /// Resolves a Helvetica Neue face by PostScript name. Helvetica Neue
    /// has no `.semibold` face on Apple platforms, so we map semibold
    /// requests up to Bold to keep weight intent intact.
    private static func helveticaNeueFont(size: CGFloat, weight: Font.Weight) -> Font {
        let postScript = switch weight {
        case .ultraLight:
            "HelveticaNeue-UltraLight"
        case .thin:
            "HelveticaNeue-Thin"
        case .light:
            "HelveticaNeue-Light"
        case .medium:
            "HelveticaNeue-Medium"
        case .semibold, .bold:
            "HelveticaNeue-Bold"
        case .heavy, .black:
            // Helvetica Neue's heaviest installed face on Apple platforms
            // is the condensed black; for proportional layouts that
            // would shift glyph widths visibly, so we cap at Bold instead.
            "HelveticaNeue-Bold"
        default: // .regular and any future case
            "HelveticaNeue"
        }
        return .custom(postScript, size: size)
    }

    /// Resolves a Georgia face by PostScript name. Georgia ships only
    /// Regular and Bold (no medium or semibold), so any weight at or
    /// above semibold collapses onto Bold.
    private static func georgiaFont(size: CGFloat, weight: Font.Weight) -> Font {
        let postScript = switch weight {
        case .semibold, .bold, .heavy, .black:
            "Georgia-Bold"
        default:
            "Georgia"
        }
        return .custom(postScript, size: size)
    }
}

// MARK: - Typography Manager

/// Owns the user's typography choice and persists it to `UserDefaults`.
///
/// Lives alongside `ThemeManager` rather than inside it because typography
/// and palette are independent axes — a user might want Apothecary's
/// daytime palette but with their preferred Avenir Next body font.
///
/// `Font.aicoven*` extensions in `DesignSystem.swift` read from this
/// manager at render time, so any view body that re-evaluates picks up
/// the chosen voice automatically. Views that need to react to changes
/// without an enclosing rebuild should observe `TypographyManager.shared`
/// directly via `@ObservedObject`.
final class TypographyManager: ObservableObject {
    static let shared = TypographyManager()

    private static let storageKey = "aicoven_typography_id"
    private static let customFamilyStorageKey = "aicoven_typography_custom_family"
    private static let sizeScaleStorageKey = "aicoven_typography_size_scale"

    @Published private(set) var variant: TypographyVariant

    /// Family name of the user's `.custom` font choice, e.g.
    /// `"Iowan Old Style"`. Persisted alongside `variant` so a user who
    /// switches to System and back to Custom gets their last pick.
    /// `nil` means "never picked one" — `.custom` then falls back to
    /// `.system`.
    @Published private(set) var customFontFamily: String?

    /// Global text-size multiplier. Applied on top of the active variant
    /// so the user can bump up OpenDyslexic (which tends to read smaller
    /// at the same point size as SF Pro) or shrink everything for dense
    /// information sessions — independent of which voice they're on.
    @Published private(set) var sizeScale: TypographySizeScale

    private init() {
        // Register bundled accessibility fonts (OpenDyslexic) before we
        // load the persisted variant, so that if the user's stored
        // choice is `.dyslexic` the very first `Font.aicoven*` read
        // already resolves to OpenDyslexic instead of falling back to
        // SF Pro for one frame. Idempotent and cheap; safe to call here
        // because the singleton itself is created lazily on first use.
        FontRegistration.register()

        let storedId = UserDefaults.standard.string(forKey: Self.storageKey)
        variant = storedId.flatMap { TypographyVariant(rawValue: $0) } ?? .system
        customFontFamily = UserDefaults.standard.string(forKey: Self.customFamilyStorageKey)
        let storedScale = UserDefaults.standard.string(forKey: Self.sizeScaleStorageKey)
        sizeScale = storedScale.flatMap { TypographySizeScale(rawValue: $0) } ?? .default
    }

    /// Switch to the given typography voice and persist the choice.
    func setVariant(_ variant: TypographyVariant) {
        guard variant != self.variant else { return }
        UserDefaults.standard.set(variant.rawValue, forKey: Self.storageKey)
        self.variant = variant
    }

    /// Store the user-picked font family. Passing `nil` clears it. This
    /// does not change `variant`; the typography picker is responsible
    /// for switching to `.custom` when the user confirms a pick from the
    /// OS font sheet.
    func setCustomFontFamily(_ family: String?) {
        let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard normalised != customFontFamily else { return }
        if let normalised {
            UserDefaults.standard.set(normalised, forKey: Self.customFamilyStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.customFamilyStorageKey)
        }
        customFontFamily = normalised
    }

    /// Switch to the given size scale and persist.
    func setSizeScale(_ scale: TypographySizeScale) {
        guard scale != sizeScale else { return }
        UserDefaults.standard.set(scale.rawValue, forKey: Self.sizeScaleStorageKey)
        sizeScale = scale
    }
}
