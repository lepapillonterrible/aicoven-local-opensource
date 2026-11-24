import SwiftUI

/// Lightweight markdown renderer for chat history.
///
/// The renderer intentionally keeps the message model as plain markdown while
/// supporting the formatting users expect from Slack/Bear-style messages:
/// headings, lists, task lists, blockquotes, tables, horizontal rules, fenced
/// code, image placeholders, inline emphasis/code/links, and common inline
/// HTML markers such as underline, keyboard, subscript, and superscript.
///
/// Safety policy: image syntax is represented as a local placeholder using the
/// author-provided alt text and source string only; the renderer never fetches
/// or embeds remote images. Raw HTML is inert except for the intentionally
/// supported inline markers above. A link stays tappable only for an `https`
/// or `mailto` destination (`ReplyLinks.opens`); any other scheme renders as
/// plain text.
struct MarkdownView: View {
    let text: String
    /// The reply is still arriving. On the Mac its prose is then laid out one
    /// block at a time, so a block that has settled is not measured again each
    /// time a later one grows; a finished reply is one selectable `Text`. iOS
    /// lays out every block on its own either way.
    var isStreaming = false
    /// Sized for a card: headings read at the semibold footnote size and
    /// everything else at the footnote size, instead of a reply's sizes.
    var compact = false

    private var bodyFont: Font {
        Self.bodyFont(compact: compact)
    }

    private static func bodyFont(compact: Bool) -> Font {
        compact ? .aicovenBodySmall : .aicovenReply
    }

    private static func headingFont(level: Int, compact: Bool) -> Font {
        compact ? .aicovenBodySmall.weight(.semibold) : .aicovenReplyHeading(level: level)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(text)
    }

    var body: some View {
        #if os(macOS)
        macOSSelectableBody
        #else
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        #endif
    }

    #if os(macOS)
    /// SwiftUI only allows drag-selection within a single `Text` view. Keep most
    /// markdown blocks selectable as text, but render fenced code, tables, and
    /// image placeholders as dedicated views so their affordances remain visible.
    private var macOSSelectableBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.macOSRenderPlan(from: blocks).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .interactive(block):
                    blockView(block)
                case let .selectableProse(blocks):
                    if isStreaming {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                                StreamingProseBlock(block: block, followsBlock: index > 0, compact: compact).equatable()
                            }
                        }
                    } else {
                        Text(Self.attributedMessage(blocks, compact: compact))
                            .font(bodyFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .tint(Color.aicovenWater)
                    }
                }
            }
        }
    }

    /// One prose block of a reply that is still arriving. A block after the
    /// first starts with a line break, so the empty line between blocks is the
    /// one `attributedMessage` puts there with "\n\n". SwiftUI skips the body
    /// of a block that has not changed.
    private struct StreamingProseBlock: View, Equatable {
        let block: MarkdownBlock
        let followsBlock: Bool
        let compact: Bool

        var body: some View {
            Text((followsBlock ? AttributedString("\n") : AttributedString()) + MarkdownView.attributedBlock(block, compact: compact))
                .font(MarkdownView.bodyFont(compact: compact))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .tint(Color.aicovenWater)
        }
    }

    /// A reply's prose as the Mac draws it: its blocks, an empty line
    /// between each.
    static func attributedMessage(_ blocks: [MarkdownBlock], compact: Bool) -> AttributedString {
        var result = AttributedString()

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(AttributedString("\n\n"))
            }
            result.append(attributedBlock(block, compact: compact))
        }

        return result
    }

    private static func attributedBlock(_ block: MarkdownBlock, compact: Bool) -> AttributedString {
        switch block {
        case let .heading(level, content):
            var heading = MarkdownInlineText.attributedInline(content)
            heading.font = headingFont(level: level, compact: compact)
            return heading

        case let .paragraph(content):
            return MarkdownInlineText.attributedInline(content)

        case let .code(code, _):
            var attributed = AttributedString(code)
            attributed.font = .system(.body, design: .monospaced)
            attributed.foregroundColor = .aicovenTextPrimary
            return attributed

        case let .blockquote(content):
            let quoted = content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "│ \($0)" }
                .joined(separator: "\n")
            var attributed = MarkdownInlineText.attributedInline(quoted)
            attributed.foregroundColor = .aicovenTextSecondary
            return attributed

        case let .unorderedList(items):
            return attributedList(items: items) { item, _ in
                if let ordinal = item.ordinal { return "\(ordinal)." }
                return item.indent >= 2 ? "–" : (item.indent == 1 ? "◦" : "•")
            }

        case let .orderedList(items):
            return attributedList(items: items) { item, index in
                if let ordinal = item.ordinal { return "\(ordinal)." }
                if item.indent > 0 { return item.indent >= 2 ? "–" : "◦" }
                return "\(index + 1)."
            }

        case let .taskList(items):
            return attributedList(items: items) { item, _ in
                item.isChecked == true ? "☑" : "☐"
            }

        case let .table(header, rows):
            var lines: [String] = []
            lines.append("| " + header.joined(separator: " | ") + " |")
            lines.append("| " + header.map { String(repeating: "-", count: max(3, $0.count)) }.joined(separator: " | ") + " |")
            for row in rows {
                lines.append("| " + row.joined(separator: " | ") + " |")
            }
            var attributed = AttributedString(lines.joined(separator: "\n"))
            attributed.font = .system(.body, design: .monospaced)
            return attributed

        case let .image(image):
            var attributed = AttributedString(image.placeholderText)
            attributed.foregroundColor = .aicovenTextSecondary
            return attributed

        case .horizontalRule:
            var attributed = AttributedString("────────────")
            attributed.foregroundColor = .aicovenTextSecondary
            return attributed

        case let .definitionList(entries):
            var attributed = AttributedString()
            for (entryIndex, entry) in entries.enumerated() {
                if entryIndex > 0 { attributed.append(AttributedString("\n")) }
                var term = MarkdownInlineText.attributedInline(entry.term)
                term.font = bodyFont(compact: compact).weight(.semibold)
                attributed.append(term)
                for definition in entry.definitions {
                    attributed.append(AttributedString("\n  : "))
                    var def = MarkdownInlineText.attributedInline(definition)
                    def.foregroundColor = .aicovenTextSecondary
                    attributed.append(def)
                }
            }
            return attributed

        case let .footnote(id, content):
            var attributed = AttributedString("\(id): ")
            attributed.foregroundColor = .aicovenTextSecondary
            attributed.append(MarkdownInlineText.attributedInline(content))
            // A footnote stays at body size.
            for run in attributed.runs where run.font == nil {
                attributed[run.range].font = .aicovenBody
            }
            return attributed
        }
    }

    private static func attributedList(
        items: [MarkdownListItem],
        marker: (MarkdownListItem, Int) -> String
    ) -> AttributedString {
        var attributed = AttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { attributed.append(AttributedString("\n")) }
            attributed.append(AttributedString(String(repeating: "  ", count: item.indent)))
            var mark = AttributedString(marker(item, index) + " ")
            mark.foregroundColor = .aicovenTextSecondary
            attributed.append(mark)
            attributed.append(MarkdownInlineText.attributedInline(item.text))
        }
        return attributed
    }

    #endif

    static func macOSRenderPlan(for markdown: String) -> [MarkdownRenderSegment] {
        macOSRenderPlan(from: MarkdownBlockParser.parse(markdown))
    }

    static func plainCopyText(_ markdown: String) -> String {
        plainCopyText(from: MarkdownBlockParser.parse(markdown))
    }

    static func plainCopyText(from blocks: [MarkdownBlock]) -> String {
        blocks.map(plainCopyText(for:)).joined(separator: "\n\n")
    }

    private static func macOSRenderPlan(from blocks: [MarkdownBlock]) -> [MarkdownRenderSegment] {
        var plan: [MarkdownRenderSegment] = []
        var proseGroup: [MarkdownBlock] = []

        func flushProseGroup() {
            guard !proseGroup.isEmpty else { return }
            plan.append(.selectableProse(proseGroup))
            proseGroup.removeAll()
        }

        for block in blocks {
            if block.isInteractiveMarkdownBlock {
                flushProseGroup()
                plan.append(.interactive(block))
            } else {
                proseGroup.append(block)
            }
        }

        flushProseGroup()
        return plan
    }

    private static func plainCopyText(for block: MarkdownBlock) -> String {
        switch block {
        case let .heading(level, content):
            return "\(String(repeating: "#", count: max(1, level))) \(content)"

        case let .paragraph(content):
            return content

        case let .code(code, language):
            let languageFence = language ?? ""
            return "```\(languageFence)\n\(code)\n```"

        case let .blockquote(content):
            return content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")

        case let .unorderedList(items):
            return items.map { item in
                let marker = item.ordinal.map { "\($0)." } ?? "-"
                return "\(String(repeating: "  ", count: item.indent))\(marker) \(item.text)"
            }
            .joined(separator: "\n")

        case let .orderedList(items):
            return items.map { item in
                let marker = item.ordinal.map { "\($0)." } ?? "-"
                return "\(String(repeating: "  ", count: item.indent))\(marker) \(item.text)"
            }
            .joined(separator: "\n")

        case let .taskList(items):
            return items.map { item in
                let marker = item.isChecked == true ? "- [x]" : "- [ ]"
                return "\(String(repeating: "  ", count: item.indent))\(marker) \(item.text)"
            }
            .joined(separator: "\n")

        case let .table(header, rows):
            var lines: [String] = []
            lines.append("| " + header.joined(separator: " | ") + " |")
            lines.append("| " + header.map { String(repeating: "-", count: max(3, $0.count)) }.joined(separator: " | ") + " |")
            for row in rows {
                lines.append("| " + row.joined(separator: " | ") + " |")
            }
            return lines.joined(separator: "\n")

        case let .image(image):
            let source = image.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { return image.placeholderText }
            return "\(image.placeholderText) — \(source)"

        case .horizontalRule:
            return "---"

        case let .definitionList(entries):
            return entries.map { entry in
                ([entry.term] + entry.definitions.map { ": \($0)" }).joined(separator: "\n")
            }
            .joined(separator: "\n\n")

        case let .footnote(id, content):
            return "[^\(id)]: \(content)"
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, content):
            MarkdownInlineText(content)
                .font(Self.headingFont(level: level, compact: compact))

        case let .paragraph(content):
            MarkdownInlineText(content)
                .font(bodyFont)

        case let .code(code, language):
            CodeBlockView(code: code, language: language)

        case let .blockquote(content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.aicovenBorder.opacity(0.95))
                    .frame(width: 3)
                MarkdownView(text: content, compact: compact)
                    .foregroundColor(.aicovenTextSecondary)
            }
            .padding(.vertical, 2)

        case let .unorderedList(items):
            listView(items: items) { item, _ in
                if let ordinal = item.ordinal {
                    Text("\(ordinal).")
                } else if item.indent >= 2 {
                    Text("–")
                } else if item.indent == 1 {
                    Text("◦")
                } else {
                    Text("•")
                }
            }

        case let .orderedList(items):
            listView(items: items) { item, index in
                if let ordinal = item.ordinal {
                    Text("\(ordinal).")
                } else if item.indent > 0 {
                    Text(item.indent >= 2 ? "–" : "◦")
                } else {
                    Text("\(index + 1).")
                }
            }

        case let .taskList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: item.isChecked == true ? "checkmark.square.fill" : "square")
                            .foregroundColor(.aicovenTextSecondary)
                            .frame(width: 16, alignment: .center)
                            .padding(.leading, CGFloat(item.indent) * 16)
                            // Its state, for VoiceOver, which would read the symbol's name.
                            .accessibilityLabel(item.isChecked == true ? "Done" : "Not done")
                        MarkdownInlineText(item.text)
                            .font(bodyFont)
                    }
                }
            }

        case let .table(header, rows):
            MarkdownTableView(header: header, rows: rows)

        case let .image(image):
            MarkdownImagePlaceholderView(image: image)

        case .horizontalRule:
            Rectangle()
                .fill(Color.aicovenBorder.opacity(0.82))
                .frame(height: 1)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .definitionList(entries):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    MarkdownInlineText(entry.term)
                        .font(bodyFont.weight(.semibold))
                    ForEach(Array(entry.definitions.enumerated()), id: \.offset) { _, definition in
                        MarkdownInlineText(": \(definition)")
                            .font(bodyFont)
                            .foregroundColor(.aicovenTextSecondary)
                            .padding(.leading, 16)
                    }
                }
            }

        case let .footnote(id, content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(id):")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
                MarkdownInlineText(content)
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
            }
        }
    }

    private func listView(
        items: [MarkdownListItem],
        marker: @escaping (MarkdownListItem, Int) -> Text
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 6) {
                    marker(item, index)
                        .font(bodyFont)
                        .foregroundColor(.aicovenTextSecondary)
                        .frame(width: 20, alignment: .trailing)
                        .padding(.leading, CGFloat(item.indent) * 16)
                    MarkdownInlineText(item.text)
                        .font(bodyFont)
                }
            }
        }
    }

}

struct MarkdownInlineText: View {
    let source: String
    private let expandsVertically: Bool

    init(_ source: String, expandsVertically: Bool = true) {
        self.source = source
        self.expandsVertically = expandsVertically
    }

    var body: some View {
        let content = Text(Self.attributedInline(source))
            .tint(Color.aicovenWater)
        if expandsVertically {
            content.fixedSize(horizontal: false, vertical: true)
        } else {
            content
        }
    }

    /// The schemes a link in message text may open: `ReplyLinks`' rule,
    /// `https` and `mailto`. The markdown parser attaches `.link` for any
    /// destination, and a tap on one goes straight to the system's open
    /// action, so without a filter a reply could open `aicoven://`,
    /// `shortcuts://`, `file://` or `tel:` in one tap. Every other
    /// destination keeps its text and loses the link.
    static var openableLinkSchemes: Set<String> {
        ReplyLinks.schemes
    }

    static func attributedInline(_ source: String) -> AttributedString {
        let prepared = prepareInlineMarkdown(source)
        var attributed = (try? AttributedString(
            markdown: prepared.markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prepared.plainText)
        dropLinksThatDoNotOpen(in: &attributed)

        // The Markdown is parsed without the marks, as it is written; where
        // each mark falls in what was parsed is found by lining the parsed
        // text up with the source, which has the marks' markers in it.
        for (mark, range) in marks(in: attributed, from: prepared.marked) {
            switch mark {
            case .underline:
                attributed[range].underlineStyle = .single
            case .strikethrough:
                attributed[range].strikethroughStyle = .single
            case .superscript:
                attributed[range].baselineOffset = 5
                attributed[range].font = .aicovenCaption
            case .subscript:
                attributed[range].baselineOffset = -3
                attributed[range].font = .aicovenCaption
            case .keyboard:
                attributed[range].font = .system(.body, design: .monospaced)
                attributed[range].foregroundColor = .aicovenTextPrimary
            }
        }
        let shown = String(attributed.characters)
        for range in specialTokenRanges(in: shown) {
            if let attributedRange = Range(range, in: attributed) {
                attributed[attributedRange].foregroundColor = .aicovenTextSecondary
            }
        }
        return attributed
    }

    /// An inline mark of the few HTML tags (and `~~`) the renderer draws.
    /// Each has a pair of markers, private-use code points that no reply
    /// keeps (they are taken out of its text first), put in place of its
    /// tags in the source that the parsed text is lined up with. They are
    /// never parsed: a marker next to `_` or `**` would stop the emphasis
    /// from closing.
    enum InlineMark: Int, CaseIterable {
        case underline, strikethrough, superscript, `subscript`, keyboard

        static let firstMarker: UInt32 = 0xE000

        var open: Unicode.Scalar {
            Unicode.Scalar(Self.firstMarker + UInt32(rawValue * 2))!
        }

        var close: Unicode.Scalar {
            Unicode.Scalar(Self.firstMarker + UInt32(rawValue * 2 + 1))!
        }

        /// The mark a marker stands for, and whether it opens it.
        static func of(_ scalar: Unicode.Scalar) -> (mark: InlineMark, opens: Bool)? {
            guard scalar.value >= firstMarker, let mark = InlineMark(rawValue: Int(scalar.value - firstMarker) / 2) else { return nil }
            return (mark, (scalar.value - firstMarker) % 2 == 0)
        }

        static func isMarker(_ scalar: Unicode.Scalar) -> Bool {
            of(scalar) != nil
        }
    }

    /// The ranges of `parsed` that the marks in `marked` stand around.
    /// `parsed` is `marked`, without its markers, as Markdown drew it: the
    /// syntax taken out (delimiters, backticks, escapes, a link's address)
    /// and an entity made its character. So the two are walked together:
    /// a character of the source that is not the next one parsed is
    /// syntax, a link's address is passed over whole, an entity counts as
    /// the one character it became, and a marker is where it is in the
    /// parsed text so far. A marker without its pair marks nothing.
    private static func marks(
        in parsed: AttributedString,
        from marked: String
    ) -> [(InlineMark, Range<AttributedString.Index>)] {
        let shown = Array(parsed.unicodeScalars)
        let source = Array(marked.unicodeScalars)
        var opened: [InlineMark: [Int]] = [:]
        var found: [(InlineMark, Range<Int>)] = []
        var at = 0
        var index = 0
        while index < source.count {
            let scalar = source[index]
            if let (mark, opens) = InlineMark.of(scalar) {
                if opens {
                    opened[mark, default: []].append(at)
                } else if let start = opened[mark]?.popLast(), start < at {
                    found.append((mark, start ..< at))
                }
                index += 1
            } else if scalar == "&", let length = entityLength(in: source, at: index) {
                // As written where it was not decoded (in code), else the
                // one character it became.
                let written = source[index ..< index + length]
                if at + length <= shown.count, shown[at ..< at + length].elementsEqual(written) {
                    at += length
                } else if at < shown.count {
                    at += 1
                }
                index += length
            } else if at < shown.count, shown[at] == scalar {
                at += 1
                index += 1
            } else if scalar == "]", index + 1 < source.count, source[index + 1] == "(",
                      let end = closingParenthesis(in: source, from: index + 1) {
                index = end + 1
            } else {
                index += 1
            }
        }
        let scalars = parsed.unicodeScalars
        return found.compactMap { mark, range in
            guard let lower = scalars.index(scalars.startIndex, offsetBy: range.lowerBound, limitedBy: scalars.endIndex),
                  let upper = scalars.index(scalars.startIndex, offsetBy: range.upperBound, limitedBy: scalars.endIndex) else { return nil }
            return (mark, lower ..< upper)
        }
    }

    /// Where the parenthesis opened at `open` closes, counting the ones
    /// inside it.
    private static func closingParenthesis(in scalars: [Unicode.Scalar], from open: Int) -> Int? {
        var depth = 0
        for index in open ..< scalars.count {
            if scalars[index] == "(" { depth += 1 }
            if scalars[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// The length of the HTML entity (`&amp;`, `&#39;`, `&#x41;`) at
    /// `index`, if one starts there.
    private static func entityLength(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
        guard let end = scalars[index...].prefix(34).firstIndex(of: ";") else { return nil }
        var body = String.UnicodeScalarView()
        body.append(contentsOf: scalars[(index + 1) ..< end])
        return isHTMLEntity(Substring(String(body))) ? end - index + 1 : nil
    }

    private static func dropLinksThatDoNotOpen(in attributed: inout AttributedString) {
        let dropped = attributed.runs[\.link].compactMap { link, range -> Range<AttributedString.Index>? in
            guard let link else { return nil }
            return ReplyLinks.opens(link) ? nil : range
        }
        for range in dropped {
            attributed[range].link = nil
        }
    }

    private struct PreparedInline {
        /// What is parsed: the source without its marks' tags.
        let markdown: String
        /// The same as plain text, drawn if the Markdown cannot be parsed.
        let plainText: String
        /// The plain text with the marks' markers where their tags were.
        let marked: String
    }

    private static func prepareInlineMarkdown(_ source: String) -> PreparedInline {
        // A reply's own private-use markers would mark its words.
        var cleaned = source
        cleaned.unicodeScalars.removeAll(where: InlineMark.isMarker)
        // Images first, over the whole text: an image's alt text can hold
        // code, which would otherwise split it across segments.
        let withPlaceholders = replaceInlineImageMarkdown(in: cleaned)
        var markdown = ""
        var plainText = ""
        var marked = ""

        for segment in inlineCodeSegments(in: withPlaceholders) {
            if segment.isCode {
                markdown.append(segment.text)
                plainText.append(segment.text)
                marked.append(segment.text)
                continue
            }

            var output = replaceAngleBracketAutolinks(in: segment.text)
            markTag("u", as: .underline, in: &output)
            markTag("sup", as: .superscript, in: &output)
            markTag("sub", as: .subscript, in: &output)
            markTag("kbd", as: .keyboard, in: &output)
            markPairedMarkers("~~", as: .strikethrough, in: &output)
            var plain = output
            plain.unicodeScalars.removeAll(where: InlineMark.isMarker)

            marked.append(output)
            plainText.append(plain)
            markdown.append(autolinkRawURLs(in: escapeRawHTML(in: plain)))
        }

        return PreparedInline(markdown: markdown, plainText: plainText, marked: marked)
    }

    private struct InlineSegment {
        let text: String
        let isCode: Bool
    }

    private static func inlineCodeSegments(in text: String) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var segmentStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }

            let delimiterStart = index
            var delimiterEnd = text.index(after: delimiterStart)
            while delimiterEnd < text.endIndex, text[delimiterEnd] == "`" {
                delimiterEnd = text.index(after: delimiterEnd)
            }
            let delimiter = String(text[delimiterStart ..< delimiterEnd])
            guard let closingRange = text.range(of: delimiter, range: delimiterEnd ..< text.endIndex) else {
                index = delimiterEnd
                continue
            }

            if segmentStart < delimiterStart {
                segments.append(InlineSegment(text: String(text[segmentStart ..< delimiterStart]), isCode: false))
            }
            segments.append(InlineSegment(text: String(text[delimiterStart ..< closingRange.upperBound]), isCode: true))
            index = closingRange.upperBound
            segmentStart = index
        }

        if segmentStart < text.endIndex {
            segments.append(InlineSegment(text: String(text[segmentStart ..< text.endIndex]), isCode: false))
        }
        if segments.isEmpty {
            segments.append(InlineSegment(text: text, isCode: false))
        }
        return segments
    }

    /// Swift/Foundation Markdown can attach `NSImageURL` attributes for inline
    /// image syntax. Convert inline images to inert placeholder text before
    /// parsing markdown so only block-level `.image` entries own image policy.
    /// An image inside a code span is code, and stays as it is.
    private static func replaceInlineImageMarkdown(in text: String) -> String {
        var codeSpans: [Range<String.Index>] = []
        var spanStart = text.startIndex
        for segment in inlineCodeSegments(in: text) {
            let end = text.index(spanStart, offsetBy: segment.text.count)
            if segment.isCode { codeSpans.append(spanStart ..< end) }
            spanStart = end
        }
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            if let span = codeSpans.first(where: { $0.contains(index) }) {
                output.append(contentsOf: text[span])
                index = span.upperBound
                continue
            }
            if text[index] == "!" {
                let bracketIndex = text.index(after: index)
                if bracketIndex < text.endIndex,
                   text[bracketIndex] == "[",
                   let closeAlt = text[bracketIndex...].firstIndex(of: "]") {
                    let sourceOpen = text.index(after: closeAlt)
                    if sourceOpen < text.endIndex,
                       text[sourceOpen] == "(",
                       let sourceClose = text[sourceOpen...].firstIndex(of: ")") {
                        let altStart = text.index(after: bracketIndex)
                        let sourceStart = text.index(after: sourceOpen)
                        let altText = String(text[altStart ..< closeAlt])
                        let source = String(text[sourceStart ..< sourceClose])
                        if let replacement = inlineImagePlaceholder(altText: altText, source: source) {
                            output.append(replacement)
                            index = text.index(after: sourceClose)
                            continue
                        }
                    } else if sourceOpen < text.endIndex,
                              text[sourceOpen] == "[",
                              let referenceClose = text[sourceOpen...].firstIndex(of: "]") {
                        let altStart = text.index(after: bracketIndex)
                        let referenceStart = text.index(after: sourceOpen)
                        let altText = String(text[altStart ..< closeAlt])
                        let reference = String(text[referenceStart ..< referenceClose])
                        if let replacement = inlineReferenceImagePlaceholder(altText: altText, reference: reference) {
                            output.append(replacement)
                            index = text.index(after: referenceClose)
                            continue
                        }
                    } else {
                        let altStart = text.index(after: bracketIndex)
                        let altText = String(text[altStart ..< closeAlt])
                        if let replacement = inlineReferenceImagePlaceholder(altText: altText, reference: "") {
                            output.append(replacement)
                            index = text.index(after: closeAlt)
                            continue
                        }
                    }
                }
            }

            output.append(text[index])
            index = text.index(after: index)
        }

        return output
    }

    private static func inlineImagePlaceholder(altText: String, source: String) -> String? {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { return nil }
        let destination = imageDestinationWithoutTitle(trimmedSource)
        let alt = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        if alt.isEmpty {
            return "Image attachment — \(destination)"
        }
        return "Image: \(alt) — \(destination)"
    }

    private static func inlineReferenceImagePlaceholder(altText: String, reference: String) -> String? {
        let alt = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = explicitReference.isEmpty ? alt : explicitReference
        guard !label.isEmpty else { return nil }
        let destination = "reference \(label)"
        if alt.isEmpty {
            return "Image attachment — \(destination)"
        }
        return "Image: \(alt) — \(destination)"
    }

    private static func imageDestinationWithoutTitle(_ source: String) -> String {
        guard let quoteStart = source.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
            return source
        }
        let destination = source[..<quoteStart].trimmingCharacters(in: .whitespaces)
        return destination.isEmpty ? source : destination
    }

    /// Puts the mark's markers where a tag's opening and closing are.
    /// The text marked is only lined up with the parsed text, never parsed.
    private static func markTag(_ tag: String, as mark: InlineMark, in text: inout String) {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        while let openRange = text.range(of: open), let closeRange = text.range(of: close, range: openRange.upperBound ..< text.endIndex) {
            text.replaceSubrange(closeRange, with: String(mark.close))
            text.replaceSubrange(openRange, with: String(mark.open))
        }
    }

    private static func markPairedMarkers(_ marker: String, as mark: InlineMark, in text: inout String) {
        while let openRange = text.range(of: marker), let closeRange = text.range(of: marker, range: openRange.upperBound ..< text.endIndex) {
            text.replaceSubrange(closeRange, with: String(mark.close))
            text.replaceSubrange(openRange, with: String(mark.open))
        }
    }

    private static func replaceAngleBracketAutolinks(in text: String) -> String {
        let pattern = #"<((?:https?://)[^\s<>]+)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        var output = text
        for match in matches {
            guard match.numberOfRanges == 2,
                  let fullRange = Range(match.range(at: 0), in: output),
                  let urlRange = Range(match.range(at: 1), in: output) else { continue }
            let url = String(output[urlRange])
            output.replaceSubrange(fullRange, with: url)
        }
        return output
    }

    private static func escapeRawHTML(in text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "&", let entityEnd = text[index...].firstIndex(of: ";") {
                let entityStart = text.index(after: index)
                let entityBody = text[entityStart ..< entityEnd]
                if isHTMLEntity(entityBody) {
                    output.append("&")
                    output.append(contentsOf: entityBody)
                    output.append(";")
                    index = text.index(after: entityEnd)
                    continue
                }
            }

            switch character {
            case "&": output.append("&amp;")
            case "<": output.append("&lt;")
            case ">": output.append("&gt;")
            default: output.append(character)
            }
            index = text.index(after: index)
        }

        return output
    }

    private static func isHTMLEntity(_ entityBody: Substring) -> Bool {
        let entity = String(entityBody)
        guard !entity.isEmpty else { return false }
        if entity.range(of: #"^#\d+$"#, options: .regularExpression) != nil { return true }
        if entity.range(of: #"^#x[0-9A-Fa-f]+$"#, options: .regularExpression) != nil { return true }
        return entity.range(of: #"^[A-Za-z][A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    private static func autolinkRawURLs(in text: String) -> String {
        let pattern = #"(?<!\]\()\bhttps?://[^\s<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        var output = text
        for match in matches {
            let url = nsText.substring(with: match.range)
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: "[\(url)](\(url))")
            }
        }
        return output
    }

    private static func specialTokenRanges(in text: String) -> [Range<String.Index>] {
        let pattern = #"(?<![\w/])[@#][$A-Za-z0-9_][-A-Za-z0-9_]*|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { Range($0.range, in: text) }
    }
}

struct MarkdownListItem: Equatable {
    let indent: Int
    let text: String
    let ordinal: Int?
    let isChecked: Bool?
}

struct MarkdownDefinitionEntry: Equatable {
    let term: String
    let definitions: [String]
}

struct MarkdownImage: Equatable {
    let altText: String
    let source: String
    let title: String?

    var placeholderText: String {
        let alt = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        return alt.isEmpty ? "Image attachment" : "Image: \(alt)"
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(String, lang: String?)
    case blockquote(String)
    case unorderedList([MarkdownListItem])
    case orderedList([MarkdownListItem])
    case taskList([MarkdownListItem])
    case table(header: [String], rows: [[String]])
    case image(MarkdownImage)
    case horizontalRule
    case definitionList([MarkdownDefinitionEntry])
    case footnote(id: String, text: String)
}

enum MarkdownRenderSegment: Equatable {
    case selectableProse([MarkdownBlock])
    case interactive(MarkdownBlock)
}

private extension MarkdownBlock {
    var isInteractiveMarkdownBlock: Bool {
        switch self {
        case .code, .table, .image:
            true
        default:
            false
        }
    }
}

enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                if let singleLineCode = singleLineFencedCode(from: trimmed) {
                    blocks.append(.code(singleLineCode, lang: nil))
                    i += 1
                    continue
                }

                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                blocks.append(.code(code.joined(separator: "\n"), lang: lang.isEmpty ? nil : lang))
                continue
            }

            if let footnote = footnote(from: trimmed) {
                blocks.append(.footnote(id: footnote.id, text: footnote.text))
                i += 1
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            if isTableStart(lines, at: i) {
                let table = parseTable(lines, start: i)
                blocks.append(.table(header: table.header, rows: table.rows))
                i = table.nextIndex
                continue
            }

            if let image = image(from: trimmed) {
                blocks.append(.image(image))
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let quoteTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard quoteTrimmed.hasPrefix(">") else { break }
                    var stripped = String(quoteTrimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    if stripped.hasPrefix(">") {
                        stripped = String(stripped.dropFirst()).trimmingCharacters(in: .whitespaces)
                    }
                    quoteLines.append(stripped)
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let listKind = listKind(from: trimmed) {
                let list = parseListBlock(lines, start: i, rootKind: listKind)
                if list.hasTasks {
                    blocks.append(.taskList(list.items))
                } else if listKind == .ordered {
                    blocks.append(.orderedList(list.items))
                } else {
                    blocks.append(.unorderedList(list.items))
                }
                i = list.nextIndex
                continue
            }

            if isDefinitionListStart(lines, at: i) {
                let definition = parseDefinitionList(lines, start: i)
                blocks.append(.definitionList(definition.entries))
                i = definition.nextIndex
                continue
            }

            var paragraph: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix(">") || heading(from: nextTrimmed) != nil || isHorizontalRule(nextTrimmed) || listKind(from: nextTrimmed) != nil || footnote(from: nextTrimmed) != nil || isTableStart(lines, at: i) || image(from: nextTrimmed) != nil {
                    break
                }
                paragraph.append(next)
                i += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return blocks
    }

    private enum ListKind { case unordered, ordered }

    private static func parseListBlock(
        _ lines: [String],
        start: Int,
        rootKind: ListKind
    ) -> (items: [MarkdownListItem], hasTasks: Bool, nextIndex: Int) {
        var items: [MarkdownListItem] = []
        var index = start
        let rootIndent = listItem(from: lines[start])?.item.indent ?? 0
        var hasTasks = false

        while index < lines.count, let parsed = listItem(from: lines[index]) {
            let isTask = parsed.item.isChecked != nil

            if items.isEmpty {
                hasTasks = isTask
            } else if hasTasks {
                guard isTask else { break }
            } else if isTask {
                break
            } else if parsed.kind != rootKind, parsed.item.indent <= rootIndent {
                break
            }

            items.append(parsed.item)
            index += 1
        }

        return (items, hasTasks, index)
    }

    private static func singleLineFencedCode(from line: String) -> String? {
        guard line.hasPrefix("```"), line.hasSuffix("```"), line.count >= 6 else { return nil }
        let contentStart = line.index(line.startIndex, offsetBy: 3)
        let contentEnd = line.index(line.endIndex, offsetBy: -3)
        guard contentStart <= contentEnd else { return nil }
        let content = String(line[contentStart ..< contentEnd])
        return content.isEmpty ? nil : content
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func footnote(from line: String) -> (id: String, text: String)? {
        guard line.hasPrefix("[^") else { return nil }
        guard let close = line.firstIndex(of: "]") else { return nil }
        let after = line.index(after: close)
        guard after < line.endIndex, line[after] == ":" else { return nil }
        let id = String(line[line.index(line.startIndex, offsetBy: 2) ..< close])
        let textStart = line.index(after: after)
        return (id, String(line[textStart...]).trimmingCharacters(in: .whitespaces))
    }

    private static func image(from line: String) -> MarkdownImage? {
        guard line.hasPrefix("![") else { return nil }
        guard let closeAlt = line.firstIndex(of: "]") else { return nil }
        let openSource = line.index(after: closeAlt)
        guard openSource < line.endIndex, line[openSource] == "(" else { return nil }
        guard line.last == ")" else { return nil }

        let altStart = line.index(line.startIndex, offsetBy: 2)
        let sourceStart = line.index(after: openSource)
        let sourceEnd = line.index(before: line.endIndex)
        guard sourceStart <= sourceEnd else { return nil }

        let remainder = String(line[sourceStart ..< sourceEnd]).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        let parsed = parseImageDestinationAndTitle(remainder)
        return MarkdownImage(
            altText: String(line[altStart ..< closeAlt]),
            source: parsed.destination,
            title: parsed.title
        )
    }

    private static func parseImageDestinationAndTitle(_ text: String) -> (destination: String, title: String?) {
        guard let quoteStart = text.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
            return (text, nil)
        }

        let destination = String(text[..<quoteStart]).trimmingCharacters(in: .whitespaces)
        let quote = text[quoteStart]
        let titleStart = text.index(after: quoteStart)
        guard let quoteEnd = text[titleStart...].firstIndex(of: quote) else {
            return (text, nil)
        }

        let title = String(text[titleStart ..< quoteEnd])
        return (destination.isEmpty ? text : destination, title.isEmpty ? nil : title)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "*" } || compact.allSatisfy { $0 == "_" }
    }

    private static func listKind(from trimmedLine: String) -> ListKind? {
        if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("• ") || trimmedLine.hasPrefix("- [") { return .unordered }
        if orderedPrefix(in: trimmedLine) != nil { return .ordered }
        return nil
    }

    private static func listItem(from line: String) -> (kind: ListKind, item: MarkdownListItem)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indent = leadingSpaces / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            let markerLength = trimmed.hasPrefix("• ") ? 2 : 2
            var text = String(trimmed.dropFirst(markerLength))
            var checked: Bool? = nil
            if text.lowercased().hasPrefix("[x] ") {
                checked = true
                text = String(text.dropFirst(4))
            } else if text.hasPrefix("[ ] ") {
                checked = false
                text = String(text.dropFirst(4))
            }
            return (.unordered, MarkdownListItem(indent: indent, text: text, ordinal: nil, isChecked: checked))
        }

        if let ordered = orderedPrefix(in: trimmed) {
            let text = String(trimmed.dropFirst(ordered.markerLength))
            return (.ordered, MarkdownListItem(indent: indent, text: text, ordinal: ordered.ordinal, isChecked: nil))
        }
        return nil
    }

    private static func orderedPrefix(in line: String) -> (ordinal: Int, markerLength: Int)? {
        var digits = ""
        for character in line {
            if character.isNumber { digits.append(character) } else { break }
        }
        guard !digits.isEmpty, let ordinal = Int(digits) else { return nil }
        let dotIndex = line.index(line.startIndex, offsetBy: digits.count)
        guard dotIndex < line.endIndex, line[dotIndex] == "." else { return nil }
        let spaceIndex = line.index(after: dotIndex)
        guard spaceIndex < line.endIndex, line[spaceIndex] == " " else { return nil }
        return (ordinal, digits.count + 2)
    }

    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        return lines[index].contains("|") && isTableSeparator(lines[index + 1])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.trimmingCharacters(in: .whitespaces)
            return compact.count >= 3 && compact.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseTable(_ lines: [String], start: Int) -> (header: [String], rows: [[String]], nextIndex: Int) {
        let header = splitTableRow(lines[start])
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, lines[index].contains("|") {
            rows.append(splitTableRow(lines[index]))
            index += 1
        }
        return (header, rows, index)
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func isDefinitionListStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let term = lines[index].trimmingCharacters(in: .whitespaces)
        let definition = lines[index + 1].trimmingCharacters(in: .whitespaces)
        return !term.isEmpty && definition.hasPrefix(":")
    }

    private static func parseDefinitionList(_ lines: [String], start: Int) -> (entries: [MarkdownDefinitionEntry], nextIndex: Int) {
        var entries: [MarkdownDefinitionEntry] = []
        var index = start
        while index < lines.count, index + 1 < lines.count {
            let term = lines[index].trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { break }
            var definitions: [String] = []
            index += 1
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(":") else { break }
                definitions.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
            }
            guard !definitions.isEmpty else { break }
            entries.append(MarkdownDefinitionEntry(term: term, definitions: definitions))
            if index >= lines.count || lines[index].trimmingCharacters(in: .whitespaces).isEmpty { break }
            if index + 1 >= lines.count || !lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix(":") { break }
        }
        return (entries, index)
    }
}

private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    private let layout: MarkdownTableLayout

    init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
        layout = MarkdownTableLayout(header: header, rows: rows)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(layout.header, rowIndex: 0, isHeader: true)
                ForEach(Array(layout.rows.enumerated()), id: \.offset) { rowIndex, row in
                    tableRow(row, rowIndex: rowIndex + 1, isHeader: false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: BorderRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .stroke(Color.aicovenBorder.opacity(0.9), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableRow(_ cells: [String], rowIndex: Int, isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0 ..< layout.columnCount, id: \.self) { index in
                MarkdownInlineText(cells[index], expandsVertically: false)
                    .font(isHeader ? .aicovenBodySmall.weight(.semibold) : .aicovenBodySmall)
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .frame(width: layout.columnWidths[index], alignment: .leading)
            }
        }
        .background(rowBackground(rowIndex: rowIndex, isHeader: isHeader))
        .overlay(alignment: .leading) {
            if layout.columnCount > 1 {
                GeometryReader { _ in
                    ZStack(alignment: .leading) {
                        ForEach(0 ..< (layout.columnCount - 1), id: \.self) { index in
                            Rectangle()
                                .fill(Color.aicovenBorder.opacity(0.72))
                                .frame(width: 1)
                                .offset(x: layout.dividerOffset(afterColumn: index))
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aicovenBorder.opacity(0.72))
                .frame(height: 1)
        }
    }

    private func rowBackground(rowIndex: Int, isHeader: Bool) -> Color {
        if isHeader {
            return Color.aicovenSurfaceElevated
        }
        return rowIndex.isMultiple(of: 2)
            ? Color.aicovenSurfaceElevated.opacity(0.72)
            : Color.aicovenSurfaceElevated.opacity(0.24)
    }
}

struct MarkdownTableLayout: Equatable {
    static let minColumnWidth: CGFloat = 112
    static let maxColumnWidth: CGFloat = 220

    let columnCount: Int
    let columnWidths: [CGFloat]
    let header: [String]
    let rows: [[String]]

    init(header: [String], rows: [[String]]) {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let normalizedHeader = Self.normalizedRow(header, columnCount: columnCount)
        let normalizedRows = rows.map { Self.normalizedRow($0, columnCount: columnCount) }
        let columnWidths = (0 ..< columnCount).map { column in
            Self.width(for: [normalizedHeader] + normalizedRows, column: column)
        }
        self.columnCount = columnCount
        self.columnWidths = columnWidths
        self.header = normalizedHeader
        self.rows = normalizedRows
    }

    func dividerOffset(afterColumn column: Int) -> CGFloat {
        guard column >= 0 else { return 0 }
        let includedColumns = min(column + 1, columnWidths.count)
        return columnWidths.prefix(includedColumns).reduce(0, +)
    }

    private static func normalizedRow(_ cells: [String], columnCount: Int) -> [String] {
        (0 ..< columnCount).map { index in
            guard index < cells.count else { return "" }
            return softWrappedCell(cells[index])
        }
    }

    private static func width(for rows: [[String]], column: Int) -> CGFloat {
        let longestCell = rows
            .compactMap { row in column < row.count ? row[column] : nil }
            .map { Self.estimatedDisplayLength($0) }
            .max() ?? 0
        let contentWidth = CGFloat(longestCell) * 7.2 + (Spacing.sm * 2)
        return min(max(contentWidth, minColumnWidth), maxColumnWidth)
    }

    private static func estimatedDisplayLength(_ text: String) -> Int {
        text.replacingOccurrences(of: "\u{200B}", with: "").count
    }

    private static func softWrappedCell(_ text: String) -> String {
        guard shouldSoftWrap(text) else {
            return text
        }

        var output = ""
        for character in text {
            output.append(character)
            if character == "/" || character == "." || character == "-" || character == "_" || character == "=" || character == ":" {
                output.append("\u{200B}")
            }
        }
        return output
    }

    private static func shouldSoftWrap(_ text: String) -> Bool {
        guard text.split(whereSeparator: \.isWhitespace).contains(where: { $0.count >= 28 }) else {
            return false
        }
        let lowercase = text.lowercased()
        guard !lowercase.contains("://"),
              !lowercase.contains("<http"),
              !text.contains("](") else {
            return false
        }
        return true
    }
}

private struct MarkdownImagePlaceholderView: View {
    let image: MarkdownImage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "photo")
                .foregroundColor(.aicovenTextSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.placeholderText)
                    .font(.aicovenBodySmall.weight(.semibold))
                    .foregroundColor(.aicovenTextPrimary)
                Text(image.source)
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.aicovenSurfaceElevated.opacity(0.64))
        .clipShape(RoundedRectangle(cornerRadius: BorderRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .stroke(Color.aicovenBorder.opacity(0.72), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(image.placeholderText). Image source not loaded."))
    }
}

#if DEBUG
struct MarkdownView_Previews: PreviewProvider {
    static var previews: some View {
        MarkdownView(text: """
        # Rich Text Formatting Test Suite

        **Bold**, *italic*, ~~strike~~, <u>underline</u>, `code`, <kbd>Cmd</kbd> + <kbd>C</kbd>, H<sub>2</sub>O, E = mc<sup>2</sup>.

        - First item
          - Nested item
            - Third level
        1. First step
        2. Second step

        > Quote with **formatting**
        > and another line.

        | Column 1 | Column 2 | Column 3 |
        |---|---|---|
        | **Bold** | *Italic* | `code` |

        - [ ] Unchecked item
        - [x] Checked item

        ```swift
        print("Hello")
        ```
        """)
        .frame(width: 620)
        .padding()
    }
}
#endif
