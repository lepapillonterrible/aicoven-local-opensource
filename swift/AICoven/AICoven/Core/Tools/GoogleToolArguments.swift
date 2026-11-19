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

    /// What was given as text that is JSON, read as the JSON. Some
    /// models (those told a list holds text) write a list, or each thing
    /// in it, as JSON in text; it is read as what it says. Anything else
    /// is itself.
    private static func read(_ value: AnyJSONValue) -> AnyJSONValue {
        guard case let .string(text) = value,
              let first = text.first(where: { !$0.isWhitespace }), first == "[" || first == "{",
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return value }
        return jsonValue(json)
    }

    /// What `JSONSerialization` read, as a value: true and false as
    /// themselves and not as 1 and 0, a whole number as a whole number.
    private static func jsonValue(_ json: Any) -> AnyJSONValue {
        switch json {
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if let whole = Int(exactly: number.doubleValue), !CFNumberIsFloatType(number) { return .int(whole) }
            return .double(number.doubleValue)
        case let members as [String: Any]:
            return .dictionary(members.mapValues(jsonValue))
        case let elements as [Any]:
            return .array(elements.map(jsonValue))
        default:
            return .null
        }
    }

    /// The rows a call gives to write (`values`): rows of cells, each
    /// cell text, a number or true/false, or null for an empty one. Nil
    /// if it is not that, or has no rows. (The rows, or a row, may be
    /// given as JSON in text.)
    static func rows(in args: [String: AnyJSONValue]) -> [[AnyJSONValue]]? {
        guard let values = args["values"], case let .array(given) = read(values), !given.isEmpty else { return nil }
        var rows: [[AnyJSONValue]] = []
        for row in given {
            guard case let .array(cells) = read(row) else { return nil }
            for cell in cells {
                switch cell {
                case .string, .int, .double, .bool, .null: continue
                case .dictionary, .array: return nil
                }
            }
            rows.append(cells)
        }
        return rows
    }

    /// A cell as the person is shown it before it is written.
    static func shown(_ cell: AnyJSONValue) -> String {
        switch cell {
        case let .string(text): text
        case let .int(number): String(number)
        case let .double(number): String(number)
        case let .bool(flag): flag ? "TRUE" : "FALSE"
        case .null, .dictionary, .array: ""
        }
    }

    /// How Google is to take what is written (`value_input_option`): as
    /// if typed (formulas and dates worked out), which is what it is when
    /// left out, or exactly as written. Nil for anything else.
    static func valueInputOption(in args: [String: AnyJSONValue]) -> String? {
        guard let given = args["value_input_option"], !(given.value is NSNull) else { return "USER_ENTERED" }
        guard let option = given.value as? String, ["USER_ENTERED", "RAW"].contains(option) else { return nil }
        return option
    }

    /// The changes a call asks Google to make (`requests`), in Google's
    /// own form for the kind of file: one or more objects. Nil if it is
    /// not that. (The requests, or a request, may be given as JSON in
    /// text.)
    static func requests(in args: [String: AnyJSONValue]) -> [[String: AnyJSONValue]]? {
        guard let asked = args["requests"], case let .array(given) = read(asked), !given.isEmpty else { return nil }
        var requests: [[String: AnyJSONValue]] = []
        for request in given {
            guard case let .dictionary(members) = read(request), !members.isEmpty else { return nil }
            requests.append(members)
        }
        return requests
    }

    /// The folders a call asks a file to be put in (`parents`): none when
    /// left out, or ids. Nil if it is anything else.
    static func folders(in args: [String: AnyJSONValue]) -> [String]? {
        guard let given = args["parents"], !(given.value is NSNull) else { return [] }
        guard case let .array(ids) = given else { return nil }
        var folders: [String] = []
        for id in ids {
            guard case let .string(folder) = id, isID(folder) else { return nil }
            folders.append(folder)
        }
        return folders
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

    /// The largest file in Drive that is fetched to be read: as large as
    /// a file can be to be attached to a message.
    static let largestFile = AttachmentStore.maxBytes

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
