import SwiftUI

/// A face with "Change" under it, which opens the picker of its symbol
/// and tint: a popover on the Mac and iPad, a sheet on the iPhone. The
/// caller draws the face from what is chosen.
struct IconChoice<Face: View>: View {
    @Binding var symbol: String
    @Binding var tint: IconTint
    /// The symbols the picker shows before a search.
    let suggestedSymbols: [String]
    @ViewBuilder var face: () -> Face

    @State private var isChoosing = false

    var body: some View {
        VStack(spacing: Spacing.xs) {
            face()
            Button("Change") { isChoosing = true }
                .font(.aicovenBodySmall)
                .accessibilityLabel("Change Icon")
                .accessibilityIdentifier("icon-change")
                .presenting($isChoosing, usesSheet: Self.usesSheet) {
                    SymbolTintPicker(symbol: $symbol, tint: $tint, inSheet: Self.usesSheet, suggestedSymbols: suggestedSymbols)
                }
        }
    }

    /// The iPhone has no room for a popover of the picker's size.
    private static var usesSheet: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

private extension View {
    /// Presents content as a sheet (medium and large), or as a popover.
    @ViewBuilder
    func presenting(_ isPresented: Binding<Bool>, usesSheet: Bool, @ViewBuilder content: @escaping () -> some View) -> some View {
        if usesSheet {
            sheet(isPresented: isPresented) {
                content().presentationDetents([.medium, .large])
            }
        } else {
            popover(isPresented: isPresented, content: content)
        }
    }
}
