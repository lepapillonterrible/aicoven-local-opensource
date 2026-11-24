import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Display contract for fenced-code Markdown blocks.
///
/// The parser owns fence/language extraction. This view model deliberately keeps
/// only the already-parsed code body so copy actions never include Markdown fence
/// markers or the language line.
struct CodeBlockViewModel: Equatable {
    let code: String
    let language: String?

    init(code: String, language: String?) {
        self.code = code
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = trimmedLanguage?.isEmpty == false ? trimmedLanguage : nil
    }

    var displayLanguage: String? {
        language
    }

    var copyText: String {
        code
    }

    var accessibilityLabel: String {
        if let language {
            return "Code block, \(language)"
        }
        return "Code block"
    }

    var copyAccessibilityLabel: String {
        if let language {
            return "Copy \(language) code"
        }
        return "Copy code"
    }

    var copyAccessibilityHint: String {
        "Copies the exact code body without Markdown fence markers."
    }

    var lineCount: Int {
        guard !code.isEmpty else { return 0 }
        return code.components(separatedBy: "\n").count
    }

    var longestLineCharacterCount: Int {
        code.components(separatedBy: "\n")
            .map(\.count)
            .max() ?? 0
    }
}

struct CodeBlockView: View {
    private let viewModel: CodeBlockViewModel

    init(code: String, language: String? = nil) {
        viewModel = CodeBlockViewModel(code: code, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            codeBody
        }
        .background(Color.aicovenSurfaceElevated.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: BorderRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .stroke(Color.aicovenBorder.opacity(0.75), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(viewModel.accessibilityLabel)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if let displayLanguage = viewModel.displayLanguage {
                Text(displayLanguage)
                    .font(.aicovenCaption.weight(.semibold))
                    .foregroundColor(.aicovenTextSecondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 8)

            Button(action: { copy(viewModel.copyText) }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(8)
                    .background(Color.aicovenSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: BorderRadius.xs))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(viewModel.copyAccessibilityLabel)
            .accessibilityHint(viewModel.copyAccessibilityHint)
            .help(viewModel.copyAccessibilityLabel)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color.aicovenSurfaceElevated)
    }

    private var codeBody: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(viewModel.code.isEmpty ? " " : viewModel.code)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.aicovenTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = string
        #endif
    }
}
