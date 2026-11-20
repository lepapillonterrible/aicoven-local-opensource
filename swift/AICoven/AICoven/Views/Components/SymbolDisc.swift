import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An SF Symbol on a tinted disc: the face of an agent, and of a coven. A
/// symbol this OS can't draw is replaced by `fallback`: `cpu` for an agent, and
/// `house` for a coven.
struct SymbolDisc: View {
    static let fallbackSymbol = "cpu"

    let symbol: String
    let tint: IconTint
    let size: CGFloat
    var fallback = SymbolDisc.fallbackSymbol

    /// The symbol itself when this OS can draw it, else `fallback`: a symbol
    /// picked on a newer OS can arrive on an older one.
    static func renderable(_ symbol: String, fallback: String) -> String {
        isRenderable(symbol) ? symbol : fallback
    }

    static func isRenderable(_ symbol: String) -> Bool {
        #if os(macOS)
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        #else
        UIImage(systemName: symbol) != nil
        #endif
    }

    var body: some View {
        Circle()
            .fill(tint.background)
            .frame(width: size, height: size)
            .overlay {
                // The symbol fills 58% of the disc: that is its visual box, so
                // the size is a frame, not a font size.
                Image(systemName: Self.renderable(symbol, fallback: fallback))
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint.foreground)
                    .frame(width: size * 0.58, height: size * 0.58)
            }
    }
}
