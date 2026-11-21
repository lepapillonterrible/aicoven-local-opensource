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

/// The icon a new coven is made with: it starts as one no other coven
/// shows (`CovenIcon.startingIcon`), unless the person has chosen one by
/// then. Until that is known, or the person chooses, the coven is not
/// made (`isReady`).
struct NewCovenIcon: View {
    @Binding var symbol: String
    @Binding var tint: IconTint
    /// The icon shown is the one the coven will be made with.
    @Binding var isReady: Bool

    /// The person chose in the picker, whatever they chose (also the
    /// symbol or the tint that was already shown).
    @State private var didChoose = false
    /// The person's covens could not be read: the icon is theirs to choose.
    @State private var mustChoose = false

    var body: some View {
        IconChoice(
            symbol: Binding(get: { symbol }, set: { chosen in
                symbol = chosen
                didChoose = true
                isReady = true
            }),
            tint: Binding(get: { tint }, set: { chosen in
                tint = chosen
                didChoose = true
                isReady = true
            }),
            suggestedSymbols: CovenIcon.suggestedSymbols
        ) {
            SymbolDisc(symbol: symbol, tint: tint, size: 64, fallback: CovenIcon.defaultSymbol)
        }
        // From the icon's leading edge: the icon stands at the form's
        // edge, and the line is wider than it.
        .overlay(alignment: .bottomLeading) {
            // Why the coven cannot be made yet, where that is so.
            if mustChoose, !didChoose {
                Text("Choose an icon to continue.")
                    .font(.aicovenCaption)
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .fixedSize()
                    .offset(y: 20)
                    .accessibilityIdentifier("icon-must-choose")
            }
        }
        .padding(.bottom, mustChoose && !didChoose ? 20 : 0)
        .task {
            // If the other covens cannot be read, what none of them shows
            // is not known: the icon is then the person's to choose.
            guard let covens = try? await CovenService.shared.loadCovens() else {
                mustChoose = true
                return
            }
            if !didChoose {
                let start = CovenIcon.startingIcon(among: covens)
                symbol = start.symbol
                tint = start.tint
            }
            isReady = true
        }
    }
}
