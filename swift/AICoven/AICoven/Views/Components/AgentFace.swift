import SwiftUI

/// An agent's face, as the cloud app draws it: its symbol on its tint,
/// with its provider's logo in a notch cut out of the disc's top-right.
/// The notch is a cut-out, so it reads on any background. A missing symbol
/// shows `cpu` and a missing tint shows Sand, each on its own.
struct AgentFace: View {
    let symbol: String?
    let tint: IconTint?
    let provider: String?
    var size: CGFloat = 36

    /// The sixteen symbols the picker suggests before a search.
    nonisolated static let suggestedSymbols = [
        "cpu", "brain", "lightbulb", "paintpalette", "pencil", "magnifyingglass", "gearshape", "chart.bar.xaxis",
        "paperplane", "bubble.left", "map", "flask", "books.vertical", "sparkles", "star", "theatermasks",
    ]

    /// How far each logo is scaled so its mark fills the badge like the
    /// others: one over the share of its asset box the mark covers, measured
    /// on the rendered assets. A logo not listed fills its box. Scaled here,
    /// not in the asset, because Settings draws the same assets.
    private static let logoFill: [String: CGFloat] = [
        "provider_openai": 1.524,
        "provider_openclaw": 1.05,
    ]

    /// The symbol an agent made before agents had symbols is shown with:
    /// the one its emoji was replaced by (the suggested symbols follow
    /// the emoji the app used to offer), or nil for an emoji with none.
    nonisolated static func symbol(forEmoji emoji: String?) -> String? {
        guard let emoji else { return nil }
        return symbolsForEmoji[emoji.replacingOccurrences(of: "\u{FE0F}", with: "")]
    }

    private nonisolated static let symbolsForEmoji: [String: String] = [
        "🤖": "cpu", "🧠": "brain", "💡": "lightbulb", "🎨": "paintpalette", "📝": "pencil", "🔍": "magnifyingglass",
        "⚙": "gearshape", "📊": "chart.bar.xaxis", "🚀": "paperplane", "💬": "bubble.left", "🎯": "scope",
        "🔬": "flask", "📚": "books.vertical", "✨": "sparkles", "⭐": "star", "🌟": "star", "🎭": "theatermasks",
        "💻": "laptopcomputer", "✍": "pencil", "🎓": "graduationcap", "🧾": "doc.text", "👩‍💻": "laptopcomputer",
    ]

    private var logo: String {
        provider.map(providerLogoAssetName(slug:)) ?? ""
    }

    var body: some View {
        let badge = size * 0.42
        let gap = size * 0.07
        let outset = size * 0.08
        ZStack(alignment: .topTrailing) {
            SymbolDisc(symbol: symbol ?? SymbolDisc.fallbackSymbol, tint: tint ?? .warm, size: size)
                .mask {
                    if logo.isEmpty {
                        Rectangle()
                    } else {
                        ZStack(alignment: .topTrailing) {
                            Rectangle()
                            Circle()
                                .frame(width: badge + gap * 2, height: badge + gap * 2)
                                .offset(x: outset, y: -outset)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                }
            if !logo.isEmpty {
                ProviderLogoBadge(assetName: logo, size: badge)
                    .scaleEffect(Self.logoFill[logo] ?? 1)
                    .offset(x: outset - gap, y: -outset + gap)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Role {
    /// This agent's face.
    func face(size: CGFloat = 36) -> AgentFace {
        AgentFace(symbol: iconSymbol, tint: iconTintValue, provider: provider, size: size)
    }
}
