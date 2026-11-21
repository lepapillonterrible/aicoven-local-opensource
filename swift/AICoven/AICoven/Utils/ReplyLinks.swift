import Foundation

/// What a reply can have opened, as the cloud app has it. A reply's text
/// and the files it names come from a model, a tool or a page it read, and
/// a tap hands their address to the system: so only an `https` or `mailto`
/// address is one. Any other (a file, a phone number, another app's
/// scheme, this app's own) keeps its words and opens nothing.
nonisolated enum ReplyLinks {
    static let schemes: Set<String> = ["https", "mailto"]

    static func opens(_ url: URL) -> Bool {
        url.scheme.map { schemes.contains($0.lowercased()) } ?? false
    }

    /// A reply's Markdown as text, with only the links that open.
    static func attributed(_ markdown: String) -> AttributedString {
        var text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        let dropped = text.runs[\.link].compactMap { link, range in
            link.map(opens) == false ? range : nil
        }
        for range in dropped {
            text[range].link = nil
        }
        return text
    }
}
