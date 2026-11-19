import Foundation

/// How a Google tool's arguments are read, and what its answers are told
/// as.
nonisolated enum GoogleToolArguments {
    /// The id a call names under one of `keys` (the first that is there):
    /// of a file, a document, a spreadsheet or a presentation. Nil if
    /// none reads as an id.
    static func id(_ keys: [String], in args: [String: AnyJSONValue]) -> String? {
        for key in keys {
            guard let given = args[key], !(given.value is NSNull) else { continue }
            guard let id = given.value as? String, isID(id) else { return nil }
            return id
        }
        return nil
    }

    /// Whether this reads as one of Google's ids, as the cloud app takes
    /// them: 1 to 200 ASCII letters, digits, "-" and "_". (An id goes into
    /// the address asked of Google.)
    static func isID(_ id: String) -> Bool {
        guard (1 ... 200).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
                true
            case UInt8(ascii: "-"), UInt8(ascii: "_"):
                true
            default:
                false
            }
        }
    }

    /// What a call says of the format to export a file as.
    enum ExportFormat: Equatable {
        case named(String)
        case leftOut
        /// The argument of this name is there and is no format.
        case unreadable(String)
    }

    /// The format a call names: `export_format` where it is there (and
    /// not null), or else this app's older `export_mime_type`. The one
    /// that is there must be text that says something.
    static func exportFormat(in args: [String: AnyJSONValue]) -> ExportFormat {
        for key in ["export_format", "export_mime_type"] {
            guard let given = args[key], !(given.value is NSNull) else { continue }
            guard let format = given.value as? String, !format.isEmpty else { return .unreadable(key) }
            return .named(format)
        }
        return .leftOut
    }

    /// What a call is told when it names no id that reads as one.
    static func idMissing(_ key: String) -> String {
        "Missing or unreadable '\(key)'. Give the id as Google gives it (google_drive.listFiles tells each file's id)."
    }

    /// The start of the type of a file that is Google's own (a Doc, a
    /// Sheet, Slides): it has no bytes of its own and is read by exporting
    /// it as something else.
    static let ownTypePrefix = "application/vnd.google-apps."

    /// What a file of Google's own is exported as to be read as text, or
    /// nil for one that has no text form (a folder, a form, a drawing).
    static func textExport(ofOwnType mimeType: String) -> String? {
        switch mimeType {
        case "application/vnd.google-apps.document": "text/plain"
        case "application/vnd.google-apps.spreadsheet": "text/csv"
        case "application/vnd.google-apps.presentation": "text/plain"
        default: nil
        }
    }

    /// The most of a file's or document's text a tool tells, as an
    /// attached file's.
    static let longestText = AttachmentContext.longestText

    /// `text` whole, or its start and a mark that it was cut.
    static func cut(_ text: String) -> String {
        text.count > longestText ? String(text.prefix(longestText)) + AttachmentContext.cutMark : text
    }
}

/// The text of what Google's Docs, Slides and Sheets APIs answer with,
/// for a model to read: the words, without the structure they come in.
nonisolated enum GoogleWorkspaceText {

    // MARK: Docs

    /// The text of a document, in order: its paragraphs, and its tables
    /// row by row with a tab between cells.
    static func text(ofDocument document: [String: Any]) -> String {
        let content = (document["body"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return text(ofContent: content)
    }

    /// (A table in a cell of a table, and so on, is followed as deep as
    /// it goes: an answer is read as JSON first, which is only so deep.)
    private static func text(ofContent content: [[String: Any]]) -> String {
        var text = ""
        for element in content {
            if let paragraph = element["paragraph"] as? [String: Any] {
                for part in paragraph["elements"] as? [[String: Any]] ?? [] {
                    text += (part["textRun"] as? [String: Any])?["content"] as? String ?? ""
                }
            } else if let table = element["table"] as? [String: Any] {
                for row in table["tableRows"] as? [[String: Any]] ?? [] {
                    let cells = (row["tableCells"] as? [[String: Any]] ?? []).map { cell in
                        Self.text(ofContent: cell["content"] as? [[String: Any]] ?? [])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ")
                    }
                    text += cells.joined(separator: "\t") + "\n"
                }
            } else if let contents = element["tableOfContents"] as? [String: Any] {
                text += Self.text(ofContent: contents["content"] as? [[String: Any]] ?? [])
            }
        }
        return text
    }

    // MARK: Slides

    /// The text on each slide of a presentation, slide by slide.
    static func text(ofPresentation presentation: [String: Any]) -> String {
        let slides = presentation["slides"] as? [[String: Any]] ?? []
        return slides.enumerated().map { index, slide in
            let said = text(ofPageElements: slide["pageElements"] as? [[String: Any]] ?? [])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "Slide \(index + 1):\n" + (said.isEmpty ? "(No text)" : said)
        }.joined(separator: "\n\n")
    }

    private static func text(ofPageElements elements: [[String: Any]]) -> String {
        var text = ""
        for element in elements {
            if let shape = element["shape"] as? [String: Any] {
                text += runs(of: shape["text"] as? [String: Any])
            } else if let table = element["table"] as? [String: Any] {
                for row in table["tableRows"] as? [[String: Any]] ?? [] {
                    let cells = (row["tableCells"] as? [[String: Any]] ?? []).map { cell in
                        runs(of: cell["text"] as? [String: Any])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ")
                    }
                    text += cells.joined(separator: "\t") + "\n"
                }
            } else if let group = element["elementGroup"] as? [String: Any] {
                text += Self.text(ofPageElements: group["children"] as? [[String: Any]] ?? [])
            }
        }
        return text
    }

    /// The words of a shape's or a cell's text, ending with a new line.
    private static func runs(of text: [String: Any]?) -> String {
        var said = ""
        for element in text?["textElements"] as? [[String: Any]] ?? [] {
            said += (element["textRun"] as? [String: Any])?["content"] as? String ?? ""
        }
        return said.isEmpty || said.hasSuffix("\n") ? said : said + "\n"
    }

    // MARK: Sheets

    /// The sheets of a spreadsheet, each with its size, so that a range
    /// of one can then be read.
    static func sheets(ofSpreadsheet spreadsheet: [String: Any]) -> [String] {
        (spreadsheet["sheets"] as? [[String: Any]] ?? []).compactMap { sheet in
            guard let properties = sheet["properties"] as? [String: Any], let title = properties["title"] as? String else { return nil }
            let grid = properties["gridProperties"] as? [String: Any]
            guard let rows = grid?["rowCount"] as? Int, let columns = grid?["columnCount"] as? Int else { return title }
            return "\(title) (\(rows) rows, \(columns) columns)"
        }
    }

    /// The title of a document, a presentation (`title`) or a spreadsheet
    /// (`properties.title`), or nil if it has none.
    static func title(of file: [String: Any]) -> String? {
        let title = file["title"] as? String ?? (file["properties"] as? [String: Any])?["title"] as? String
        return title?.isEmpty == false ? title : nil
    }
}
