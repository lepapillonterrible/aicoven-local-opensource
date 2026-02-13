import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Lightweight markdown renderer with block formatting and code fences.
/// No external deps; supports:
/// - Paragraphs/headings via AttributedString(markdown:)
/// - Fenced code blocks ```lang ... ``` with copy button and monospaced styling
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(parseBlocks(from: text).indices, id: \.self) { i in
                switch parseBlocks(from: text)[i] {
                case let .paragraph(md):
                    VStack(alignment: .leading, spacing: 4) {
                        let lines = md.split(separator: "\n", omittingEmptySubsequences: false)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, rawLine in
                            let line = String(rawLine)
                            let trimmed = line.trimmingCharacters(in: .whitespaces)

                            if trimmed.isEmpty {
                                // Preserve blank lines as vertical spacing
                                Text(" ")
                                    .font(.system(size: 4))
                                    .opacity(0)
                            } else if trimmed.hasPrefix("### ") {
                                // Level-3 heading
                                Text(String(trimmed.dropFirst(4)))
                                    .font(.headline)
                                    .bold()
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if trimmed.hasPrefix("* ") {
                                // Bullet list item
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                    Text(attributedMarkdown(String(trimmed.dropFirst(2))))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                Text(attributedMarkdown(line))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        Button("Copy") { copyToClipboard(md) }
                    }
                case let .code(code, _):
                    CodeBlockView(code: code)
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Parsing

    private enum Block { case paragraph(String), code(String, lang: String?) }

    private func parseBlocks(from md: String) -> [Block] {
        var blocks: [Block] = []
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                // Code fence
                let lang = String(line.drop(while: { $0 == "`" })).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                // Skip closing fence
                if index < lines.count { index += 1 }
                blocks.append(.code(code.joined(separator: "\n"), lang: lang.isEmpty ? nil : lang))
            } else {
                // Collect until next blank line or fence
                var para: [String] = [line]
                index += 1
                while index < lines.count {
                    let link = lines[index]
                    if link.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    // Break on empty line (paragraph separator)
                    if link.trimmingCharacters(in: .whitespaces).isEmpty, !para.isEmpty {
                        index += 1
                        break
                    }
                    para.append(link)
                    index += 1
                }
                let joined = para.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.paragraph(joined))
                }
            }
        }
        return blocks
    }

    // MARK: - Helpers

    private func attributedMarkdown(_ md: String) -> AttributedString {
        (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    private func copyToClipboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = string
        #endif
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let code: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: { copy(code) }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
            .padding(6)
        }
    }

    private func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

#if DEBUG
struct MarkdownView_Previews: PreviewProvider {
    static var previews: some View {
        MarkdownView(text: """
        # Title\n\nParagraph with **bold**, *italic*, and a list:\n- One\n- Two\n\n```swift\nprint(\"Hello\")\n```\n\nAnother paragraph.
        """)
        .frame(width: 520)
        .padding()
    }
}
#endif
