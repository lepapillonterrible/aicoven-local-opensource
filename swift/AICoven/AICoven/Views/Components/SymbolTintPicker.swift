import SwiftUI

/// Chooses an icon face, as the cloud app's picker does: a symbol (the
/// suggested ones, or a search of the bundled catalog) and one of the
/// twelve tints. The caller presents it, as a popover on the Mac and iPad
/// and a sheet on the iPhone, and says which in `inSheet`.
struct SymbolTintPicker: View {
    @Binding var symbol: String
    @Binding var tint: IconTint
    /// Whether the caller presents this as a sheet: it adds a Done button
    /// and fills the sheet. Otherwise it is a popover of its own size.
    let inSheet: Bool
    /// The sixteen symbols shown before a search.
    let suggestedSymbols: [String]
    @State private var query = ""
    @State private var results: [String] = []
    /// The search `results` are of: nil while none has finished. What is
    /// shown is for the text in the field, or nothing yet.
    @State private var searched: String?
    @Environment(\.dismiss) private var dismiss

    // 44 pt hit areas on iPhone and iPad; the Mac's controls are smaller.
    #if os(iOS)
    private let cell: CGFloat = 44
    private let swatchHitArea: CGFloat = 44
    #else
    private let cell: CGFloat = 40
    private let swatchHitArea: CGFloat = 32
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            TextField("Search symbols", text: $query)
                .textFieldStyle(.roundedBorder)
                // A popover from a form row would otherwise inherit the
                // form's trailing alignment.
                .multilineTextAlignment(.leading)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(isSearching ? "Results" : "Suggested")
                        .font(.aicovenCaption)
                        .foregroundStyle(Color.aicovenTextTertiary)
                    if isSearching, searched != trimmedQuery {
                        // Still looking: neither the last search's symbols
                        // nor "no symbols" is said of this one.
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Searching symbols")
                    } else if isSearching, results.isEmpty {
                        Text("No symbols match “\(trimmedQuery)”.")
                            .font(.aicovenBodySmall)
                            .foregroundStyle(Color.aicovenTextSecondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cell), spacing: Spacing.xs)], spacing: Spacing.xs) {
                            ForEach(isSearching ? results : suggestedSymbols, id: \.self) { name in
                                symbolButton(name)
                            }
                        }
                    }
                    Text("Colour")
                        .font(.aicovenCaption)
                        .foregroundStyle(Color.aicovenTextTertiary)
                        .padding(.top, Spacing.xs)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: swatchHitArea), spacing: Spacing.xs)], spacing: Spacing.xs) {
                        ForEach(IconTint.allCases) { option in
                            swatch(option)
                        }
                    }
                }
            }
        }
        .padding(Spacing.md)
        .safeAreaInset(edge: .top, spacing: 0) {
            if inSheet {
                // A sheet on the iPhone has no outside to click.
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, Spacing.md)
                    .frame(height: 44)
                    .background(Color.aicovenChrome)
                    Rectangle()
                        .fill(Color.aicovenRule)
                        .frame(height: 1)
                }
            }
        }
        .frame(width: fixedWidth, height: fixedHeight)
        .task(id: trimmedQuery) {
            // The catalog loads here, the first time the picker is searched.
            let text = trimmedQuery
            guard !text.isEmpty else {
                results = []
                searched = nil
                return
            }
            let found = await Task.detached { SymbolCatalog.shared.search(text) }.value
            guard !Task.isCancelled else { return }
            results = found.filter(SymbolDisc.isRenderable)
            searched = text
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedQuery.isEmpty
    }

    /// A popover has no size of its own; a sheet fills the screen's width.
    private var fixedWidth: CGFloat? {
        inSheet ? nil : 340
    }

    private var fixedHeight: CGFloat? {
        inSheet ? nil : 460
    }

    private func symbolButton(_ name: String) -> some View {
        let selected = name == symbol
        return Button {
            symbol = name
        } label: {
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(Color.aicovenTextPrimary)
                .frame(width: cell, height: cell)
                .background(
                    RoundedRectangle(cornerRadius: BorderRadius.sm)
                        .fill(selected ? Color.aicovenSelected : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BorderRadius.sm)
                        .strokeBorder(selected ? Color.aicovenTextPrimary : Color.aicovenRule, lineWidth: selected ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatch(_ option: IconTint) -> some View {
        let selected = option == tint
        return Button {
            tint = option
        } label: {
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .fill(option.background)
                .frame(width: 32, height: 32)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(option.foreground)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: BorderRadius.sm)
                        .strokeBorder(Color.aicovenRule, lineWidth: 1)
                )
                .frame(width: swatchHitArea, height: swatchHitArea)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
