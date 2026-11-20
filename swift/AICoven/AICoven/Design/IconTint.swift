import SwiftUI

/// The twelve tints of an icon face, an agent's or a coven's, as the cloud
/// app has them. They are identity colours, not interface colour: a tint
/// says whose face it is. The cases are in palette order, and each raw
/// value is the key that is stored.
nonisolated enum IconTint: String, CaseIterable, Identifiable {
    case warm, water, rust, ink, moss, sky, lilac, rose, mint, pine, slate, plum

    var id: String {
        rawValue
    }

    /// The name VoiceOver and the swatch use.
    var label: String {
        switch self {
        case .warm: "Sand"
        case .water: "Water"
        case .rust: "Clay"
        case .ink: "Ink"
        case .moss: "Moss"
        case .sky: "Sky"
        case .lilac: "Lilac"
        case .rose: "Rose"
        case .mint: "Mint"
        case .pine: "Pine"
        case .slate: "Slate"
        case .plum: "Plum"
        }
    }

    /// The disc's fill.
    @MainActor var background: Color {
        colors.background
    }

    /// The symbol drawn on the disc.
    @MainActor var foreground: Color {
        colors.foreground
    }

    /// The first tint no agent wears, or the first of all when every one is
    /// worn. `worn` is the stored keys; an unknown or missing key wears none.
    static func nextUnused(worn: [String?]) -> IconTint {
        let used = Set(worn.compactMap(\.self))
        return allCases.first { !used.contains($0.rawValue) } ?? .warm
    }

    @MainActor private var colors: (background: Color, foreground: Color) {
        switch self {
        case .warm: Self.pair(day: ("#E4C682", "#55390A"), dusk: ("#58472A", "#F0D598"))
        case .water: Self.pair(day: ("#A8CBC3", "#17403D"), dusk: ("#2F4C49", "#A9D3CC"))
        case .rust: Self.pair(day: ("#E5B79E", "#62280F"), dusk: ("#5D3626", "#F0B698"))
        case .ink: Self.pair(day: ("#3A352E", "#EFE9DD"), dusk: ("#D9D1C1", "#26231E"))
        case .moss: Self.pair(day: ("#C2CFA5", "#354314"), dusk: ("#4B5534", "#D9E6BC"))
        case .sky: Self.pair(day: ("#A0B8D4", "#142A43"), dusk: ("#344455", "#BCD0E6"))
        case .lilac: Self.pair(day: ("#B4A3D2", "#251443"), dusk: ("#403455", "#CCBCE6"))
        case .rose: Self.pair(day: ("#D69FA6", "#43141A"), dusk: ("#553439", "#E6BCC2"))
        case .mint: Self.pair(day: ("#A7CDB0", "#14431F"), dusk: ("#34553C", "#BCE6C6"))
        case .pine: Self.pair(day: ("#2F5041", "#E0F0E9"), dusk: ("#C2DBCF", "#1E382C"))
        case .slate: Self.pair(day: ("#333E4C", "#E0E7F0"), dusk: ("#C2CDDB", "#1E2A38"))
        case .plum: Self.pair(day: ("#4F3046", "#F0E0EB"), dusk: ("#DBC2D4", "#381E31"))
        }
    }

    @MainActor private static func pair(
        day: (tile: String, symbol: String), dusk: (tile: String, symbol: String)
    ) -> (background: Color, foreground: Color) {
        (
            Color.room(light: Color(hex: day.tile), dark: Color(hex: dusk.tile)),
            Color.room(light: Color(hex: day.symbol), dark: Color(hex: dusk.symbol))
        )
    }
}
