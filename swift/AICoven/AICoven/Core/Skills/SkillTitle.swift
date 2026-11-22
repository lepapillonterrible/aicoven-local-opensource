import Foundation

/// What a skill added from a file is called, as the cloud app names one: a
/// `SKILL.md` by the `name:` in its leading frontmatter, else by its
/// folder; any other file by its own name.
nonisolated enum SkillTitle {
    /// The longest title kept.
    static let longest = 120

    /// A title as it is kept: one line, single spaces, no longer than the
    /// longest; "Untitled" for none.
    static func kept(_ title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let cut = String(oneLine.prefix(longest)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? "Untitled" : cut
    }

    /// The title of a skill whose text is `text`, from a file named
    /// `fileName` in the folder `folder` (empty where there is none).
    static func of(text: String, fileName: String, folder: String) -> String {
        let named = (fileName as NSString).deletingPathExtension
        guard fileName == "SKILL.md" else { return kept(named) }
        return kept(frontmatterName(in: text) ?? (folder.isEmpty ? named : folder))
    }

    /// The top-level, single-line `name:` of a text's leading, closed
    /// frontmatter, where it is a string; nil for any other form (a name
    /// that is a list, a number, null, nested, or none).
    static func frontmatterName(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        for line in lines[1 ..< end] {
            guard line.hasPrefix("name:") else {
                // A flow collection left open can continue onto unindented
                // lines holding nested keys: a later name is not promoted
                // past one.
                if line.first?.isWhitespace == false, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") {
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("{") || value.hasPrefix("["), flowDepth(of: value) > 0 { return nil }
                }
                continue
            }
            let raw = line.dropFirst(5)
            guard raw.first?.isWhitespace != false else { return nil }
            let value = raw.trimmingCharacters(in: .whitespaces)
            let name: String? = if let quote = value.first, quote == "'" || quote == "\"" {
                quotedScalar(value, quote: quote)
            } else {
                plainScalar(value)
            }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// A quoted name: the first unescaped quote closes it, and only a
    /// comment may follow.
    private static func quotedScalar(_ value: String, quote: Character) -> String? {
        var close: String.Index?
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let next = value.index(after: index)
            if quote == "\"", value[index] == "\\" {
                index = next < value.endIndex ? value.index(after: next) : next
                continue
            }
            if value[index] == quote {
                if quote == "'", next < value.endIndex, value[next] == "'" {
                    index = value.index(after: next)
                    continue
                }
                close = index
                break
            }
            index = next
        }
        guard let close else { return nil }
        let suffix = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix("#") else { return nil }
        let quoted = String(value[...close])
        if quote == "'" {
            return String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return try? JSONDecoder().decode(String.self, from: Data(quoted.utf8))
    }

    /// A plain name: it may have a comment after it, but a collection, a
    /// null, a boolean or a number is no name.
    private static func plainScalar(_ value: String) -> String? {
        let name = value.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        let notNames = ["~", "null", "true", "false", "yes", "no", "on", "off", ".nan", ".inf", "+.inf", "-.inf"]
        guard !notNames.contains(name.lowercased()), Double(name) == nil,
              !name.hasPrefix("- "), !name.contains(": "),
              name.first.map({ !"#[{|>&*!%@`".contains($0) }) ?? false else { return nil }
        return name
    }

    /// Open brackets minus closed ones in a flow value, leaving out quoted
    /// strings and a trailing comment. A quote opens a string only at the
    /// start of an item; an apostrophe inside a word is text.
    private static func flowDepth(of value: String) -> Int {
        var depth = 0
        var quote: Character?
        var previous: Character = " "
        var lastToken: Character = "["
        var characters = value.makeIterator()
        while let character = characters.next() {
            if let open = quote {
                if open == "\"", character == "\\" { _ = characters.next() } else if character == open { quote = nil }
            } else if character == "\"" || character == "'", "[{,:".contains(lastToken) {
                quote = character
            } else if character == "#", previous.isWhitespace {
                break
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
            }
            previous = character
            if quote == nil, !character.isWhitespace { lastToken = character }
        }
        return depth
    }
}
