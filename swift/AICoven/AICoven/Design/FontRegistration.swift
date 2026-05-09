import Foundation
import CoreText

/// Registers the small set of accessibility fonts AICoven ships in its
/// bundle (currently only OpenDyslexic 3, SIL OFL 1.1 — see
/// `Resources/Fonts/OFL.txt`).
///
/// We ship OpenDyslexic 3 (Regular + Bold) rather than classic
/// OpenDyslexic v0.91.x for two reasons:
///   1. OpenDyslexic 3 is a ground-up redesign with tighter letter
///      spacing while preserving the bottom-weighted, distinctive
///      letterforms that drive the accessibility benefit. Classic
///      OpenDyslexic's intrinsic spacing reads as "every-letter-in-its-
///      own-column" at chat sizes; v3 is closer to a normal sans.
///   2. Two faces (Regular + Bold) instead of four (Reg/Bold/Italic/
///      BoldItalic). Halves the bundle weight from ~786 KB to ~478 KB
///      and matches the actual weight needs of `Font.aicoven*` (no
///      italics requested).
///
/// Why bundle at all? `Typography.swift` historically asserted "AICoven
/// never ships custom typefaces in its bundle." That rule still holds for
/// *decorative* type — palette / display fonts — and the curated voices
/// (Rounded, Bookish, Geometric, Classic Sans, Reading Serif) keep
/// resolving against pre-installed Apple system fonts. OpenDyslexic is the
/// single permitted exception because it is a functional accessibility
/// affordance, not branding: a user with dyslexia gets the benefit of the
/// font without first having to install a third-party font installer or
/// drop into Font Book. Same category as VoiceOver or Dynamic Type, not
/// the same category as a brand serif.
///
/// We use `CTFontManagerRegisterFontsForURL(_:scope:error:)` with
/// `.process` scope so the fonts become resolvable for the lifetime of
/// the process without touching `UIAppFonts` (iOS) or
/// `ATSApplicationFontsPath` (macOS) — keeping the registration path
/// identical on both platforms.
///
/// `register()` is idempotent: a second call short-circuits, and the
/// CoreText "already registered" error code (`kCTFontManagerErrorAlreadyRegistered`,
/// 105) is treated as success so SwiftUI previews that re-evaluate the
/// app graph don't log spurious warnings.
enum FontRegistration {
    /// Subdirectory inside the app bundle where the OTFs live. Lines up
    /// with `apps/swift/AICoven/AICoven/Resources/Fonts/` in source.
    private static let resourceSubdirectory = "Fonts"

    /// File basenames of every bundled font, without the `.ttf`
    /// extension. The names match the file names on disk under
    /// `Resources/Fonts/`. PostScript names (used at render time via
    /// `Font.custom(_:)`) are different — see `TypographyVariant.dyslexic`.
    private static let bundledFontResourceNames: [String] = [
        "OpenDyslexic3-Regular",
        "OpenDyslexic3-Bold"
    ]

    /// Set on the first successful (or already-registered) pass so we
    /// can short-circuit subsequent calls.
    private static var hasRegistered = false

    /// Registers every bundled font with CoreText, idempotently. Safe to
    /// call from any code path that needs a bundled face resolved (app
    /// init, manager singleton init, SwiftUI preview render).
    static func register() {
        guard !hasRegistered else { return }
        hasRegistered = true

        for name in bundledFontResourceNames {
            // `Bundle.main.url(forResource:withExtension:subdirectory:)`
            // walks the bundle Resources, including any preserved
            // subdirectory structure synthesized by Xcode for the
            // synchronized AICoven group. If the asset isn't in a
            // subdirectory, the second lookup catches it.
            let url = Bundle.main.url(
                forResource: name,
                withExtension: "ttf",
                subdirectory: resourceSubdirectory
            ) ?? Bundle.main.url(forResource: name, withExtension: "ttf")

            guard let url else {
                #if DEBUG
                print("⚠️ FontRegistration: missing bundled font \(name).ttf")
                #endif
                continue
            }

            var error: Unmanaged<CFError>?
            let success = CTFontManagerRegisterFontsForURL(
                url as CFURL, .process, &error
            )

            if !success, let cfError = error?.takeUnretainedValue() {
                let nsError = cfError as Error as NSError
                // 105 = kCTFontManagerErrorAlreadyRegistered. Happens
                // when `register()` is called twice in the same process
                // (e.g. preview re-renders) or when the OS has already
                // surfaced the font through some other path. Not a
                // failure for our purposes.
                if nsError.code != 105 {
                    #if DEBUG
                    print("⚠️ FontRegistration: failed to register \(name): \(nsError.localizedDescription)")
                    #endif
                }
            }
        }
    }
}
