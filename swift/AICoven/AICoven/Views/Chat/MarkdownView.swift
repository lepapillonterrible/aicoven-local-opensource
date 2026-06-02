import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Lightweight markdown renderer with block formatting, code fences, and tappable links.
/// No external deps; supports:
/// - Paragraphs/headings via AttributedString(markdown:)
/// - Fenced code blocks ```lang ... ``` with copy button and monospaced styling
/// - Tappable [text](url) links on both iOS and macOS
struct MarkdownView: View {
    let text: String

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    // MARK: - macOS: single Text per paragraph group for continuous selection

    #if os(macOS)
    /// On macOS, consecutive paragraph blocks are merged into a single
    /// `Text` view so the user can drag-select across the entire bubble
    /// instead of being limited to one paragraph at a time. Code blocks
    /// remain separate with their own copy-button affordance.
    private var macOSBody: some View {
        let groups = macOSSelectionGroups(from: parseBlocks(from: text))
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group {
                case let .selectableText(attrStr):
                    Text(attrStr)
                        // Set the default body font for runs that don't carry
                        // their own font attribute. Without this, SwiftUI
                        // renders `Text(AttributedString)` in the system
                        // default body face and bypasses the user's chosen
                        // typography voice (notably OpenDyslexic).
                        .font(.aicovenBody)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .codeBlock(code):
                    CodeBlockView(code: code)
                }
            }
        }
        .contextMenu {
            Button("Copy") { copyToClipboard(text) }
        }
    }

    /// Groups used for the macOS body: consecutive paragraphs are merged
    /// into one selectable `AttributedString`; code blocks stay separate.
    private enum MacOSGroup {
        case selectableText(AttributedString)
        case codeBlock(String)
    }

    /// Merge consecutive `.paragraph` blocks into a single `AttributedString`.
    private func macOSSelectionGroups(from blocks: [Block]) -> [MacOSGroup] {
        var groups: [MacOSGroup] = []
        var pending: [String] = []

        func flush() {
            guard !pending.isEmpty else { return }
            let combined = pending.joined(separator: "\n\n")
            groups.append(.selectableText(buildCombinedAttributedString(combined)))
            pending.removeAll()
        }

        for block in blocks {
            switch block {
            case let .paragraph(md):
                pending.append(md)
            case let .code(code, _):
                flush()
                groups.append(.codeBlock(code))
            }
        }
        flush()
        return groups
    }

    /// Build a single `AttributedString` from a multi-line markdown string,
    /// handling headings, bullet lists, inline formatting, and links.
    private func buildCombinedAttributedString(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Blank line preserved as a newline
                result.append(AttributedString("\n"))
            } else if trimmed.hasPrefix("### ") {
                // Level-3 heading. Use the typography-aware H3 in bold so the
                // heading inherits the user's chosen voice (OpenDyslexic /
                // Bookish / etc.) instead of defaulting to SF Pro headline.
                var heading = attributedMarkdown(String(trimmed.dropFirst(4)))
                heading.font = .aicovenH3.weight(.bold)
                result.append(heading)
            } else if trimmed.hasPrefix("* ") {
                // Bullet list item
                let bullet = AttributedString("• ")
                let content = attributedInlineLine(String(trimmed.dropFirst(2)))
                result.append(bullet)
                result.append(content)
            } else {
                result.append(attributedInlineLine(line))
            }

            // Newline between lines (not after the last)
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    /// Build an `AttributedString` for a single line, handling inline links.
    private func attributedInlineLine(_ line: String) -> AttributedString {
        let segments = parseInlineLinks(line)
        if segments.contains(where: { if case .link = $0 { true } else { false } }) {
            return buildLinkedAttributedString(segments)
        }
        return attributedMarkdown(line)
    }
    #endif

    // MARK: - iOS: per-paragraph / per-line rendering (supports long-press selection)

    #if !os(macOS)
    /// On iOS, render each line separately so the system long-press text
    /// selection works naturally on individual paragraphs.
    private var iOSBody: some View {
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
                                // Level-3 heading. Use the typography-aware
                                // H3 in bold so the heading follows the
                                // user's chosen voice instead of SF Pro
                                // headline.
                                Text(String(trimmed.dropFirst(4)))
                                    .font(.aicovenH3)
                                    .bold()
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if trimmed.hasPrefix("* ") {
                                // Bullet list item
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .font(.aicovenBody)
                                    richTextLine(String(trimmed.dropFirst(2)))
                                }
                            } else {
                                richTextLine(line)
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
    #endif

    // MARK: - Rich text line with tappable links

    /// Renders a single line of markdown. If it contains `[text](url)` links,
    /// they are rendered as tappable elements. Otherwise falls back to
    /// `AttributedString(markdown:)` for basic inline formatting.
    @ViewBuilder
    private func richTextLine(_ line: String) -> some View {
        let segments = parseInlineLinks(line)
        if segments.contains(where: { if case .link = $0 { true } else { false } }) {
            // Line has links — build an AttributedString with .link attributes
            // which SwiftUI Text renders as tappable on iOS 15+ / macOS 12+.
            // `.font(.aicovenBody)` ensures the underlying voice (OpenDyslexic
            // / Bookish / Custom) wins over SwiftUI's default body face.
            Text(buildLinkedAttributedString(segments))
                .font(.aicovenBody)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // No links — use the standard attributed markdown path
            Text(attributedMarkdown(line))
                .font(.aicovenBody)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Build an AttributedString where link segments have `.link` set,
    /// making them tappable inside SwiftUI `Text`.
    private func buildLinkedAttributedString(_ segments: [InlineSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case let .text(str):
                let attributed = (try? AttributedString(markdown: str)) ?? AttributedString(str)
                result.append(attributed)
            case let .link(label, url):
                var linkStr = AttributedString(label)
                linkStr.link = url
                linkStr.underlineStyle = .single
                result.append(linkStr)
            }
        }
        return result
    }

    // MARK: - Inline link parsing

    private enum InlineSegment {
        case text(String)
        case link(label: String, url: URL)
    }

    /// Parse `[label](url)` patterns from a line of text.
    /// Returns an array of text and link segments in order.
    private func parseInlineLinks(_ line: String) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        // Regex: [text](url)
        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(line)]
        }

        let nsLine = line as NSString
        var lastEnd = 0
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

        for match in matches {
            let matchRange = match.range
            // Text before this link
            if matchRange.location > lastEnd {
                let prefix = nsLine.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
                if !prefix.isEmpty {
                    segments.append(.text(prefix))
                }
            }
            // Extract label and URL
            let label = nsLine.substring(with: match.range(at: 1))
            let urlString = nsLine.substring(with: match.range(at: 2))
            if let url = URL(string: urlString) {
                segments.append(.link(label: label, url: url))
            } else {
                // Invalid URL — render as plain text
                segments.append(.text(nsLine.substring(with: matchRange)))
            }
            lastEnd = matchRange.location + matchRange.length
        }

        // Remaining text after last link
        if lastEnd < nsLine.length {
            let suffix = nsLine.substring(from: lastEnd)
            if !suffix.isEmpty {
                segments.append(.text(suffix))
            }
        }

        return segments
    }

    // MARK: - Parsing

    private enum Block { case paragraph(String), code(String, lang: String?) }

    private func parseBlocks(from md: String) -> [Block] {
        var blocks: [Block] = []
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                // Code fence
                let lang = String(line.drop(while: { $0 == "`" })).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                // Skip closing fence
                if i < lines.count { i += 1 }
                blocks.append(.code(code.joined(separator: "\n"), lang: lang.isEmpty ? nil : lang))
            } else {
                // Collect until next blank line or fence
                var para: [String] = [line]
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    // Break on empty line (paragraph separator)
                    if l.trimmingCharacters(in: .whitespaces).isEmpty, !para.isEmpty {
                        i += 1
                        break
                    }
                    para.append(l)
                    i += 1
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

    private func copyToClipboard(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = s
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

    private func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = s
        #endif
    }
}

#if DEBUG
struct MarkdownView_Previews: PreviewProvider {
    static var previews: some View {
        MarkdownView(text: """
        # Title\n\nParagraph with **bold**, *italic*, and a [link](https://example.com):\n- One\n- Two\n\n```swift\nprint(\"Hello\")\n```\n\nDownload the [report](https://example.com/report.pdf) here.
        """)
        .frame(width: 520)
        .padding()
    }
}
#endif
