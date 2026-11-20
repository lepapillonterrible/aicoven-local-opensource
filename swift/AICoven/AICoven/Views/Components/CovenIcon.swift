import SwiftUI

/// A coven's identity mark, as the cloud app draws it: its symbol on its
/// tint (a missing one is a house on sand); sparkles for Strix, which is
/// no coven here, and before the covens have been read (`coven == nil`).
/// Every placement draws this one view.
struct CovenIcon: View {
    /// The symbols a coven's picker suggests before a search.
    nonisolated static let suggestedSymbols = [
        "house", "briefcase", "book.closed", "flask", "graduationcap", "hammer", "paintbrush", "leaf",
        "heart", "airplane", "cart", "banknote", "camera", "music.note", "dumbbell", "building.2",
    ]
    nonisolated static let defaultSymbol = "house"

    /// The icon a new coven starts with: the first suggested symbol, and
    /// the first tint, that no coven in `covens` shows. One without a
    /// stored symbol or tint shows the default ones. When every symbol or
    /// tint is shown, it takes the first.
    nonisolated static func startingIcon(among covens: [Coven]) -> (symbol: String, tint: IconTint) {
        let shownSymbols = Set(covens.map { $0.iconSymbol ?? defaultSymbol })
        return (
            suggestedSymbols.first { !shownSymbols.contains($0) } ?? suggestedSymbols[0],
            IconTint.nextUnused(worn: covens.map { ($0.iconTintValue ?? .warm).rawValue })
        )
    }

    let coven: Coven?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let coven {
                SymbolDisc(
                    symbol: coven.iconSymbol ?? Self.defaultSymbol,
                    tint: coven.iconTintValue ?? .warm,
                    size: size,
                    fallback: Self.defaultSymbol
                )
            } else {
                Circle()
                    .fill(Color.aicovenSurfaceElevated)
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundColor(.aicovenTextSecondary)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}
