import Foundation
import PDFKit

/// What a turn is told of the files attached to its message: for each, a
/// part that starts `[Attachment: <name>]` and holds the text that could be
/// read from it, put after the message. The parts have the form the cloud
/// app gives them.
nonisolated enum AttachmentContext {
    /// The most characters of one attachment's text a turn is given.
    static let longestText = 20000

    /// What ends a text that was cut at the limit.
    static let cutMark = "\n...(truncated)..."

    static let binaryNote = "(Binary file, could not extract text)"
    static let pictureNote = "(A picture. You are not shown it.)"
    static let pdfWithoutTextNote = "(A PDF with no text that could be read)"

    /// What goes after the message for these attachments, in their order;
    /// empty when there are none. Each is read with `read` and worked on
    /// off the caller's actor. One that cannot be read is said so by name,
    /// and the others are still read.
    @concurrent
    static func block(
        for attachments: [FileAttachmentDetail],
        longestText: Int = longestText,
        read: @Sendable (FileAttachmentDetail) async throws -> Data = bytes(of:)
    ) async -> String {
        var parts: [String] = []
        for attachment in attachments {
            // A turn that was stopped is not read for.
            guard !Task.isCancelled else { break }
            let name = plainName(attachment.name)
            do {
                let data = try await read(attachment)
                parts.append(part(named: name, body(of: data, mimeType: attachment.mimeType, longestText: longestText)))
            } catch AttachmentStore.Failure.missing {
                parts.append("\n\n[Attachment: \(name) not found]\n")
            } catch {
                let failure = error as NSError
                AppErrorReporter.log(message: "An attachment could not be read (\(failure.domain) \(failure.code)).", context: "AttachmentContext.block")
                parts.append("\n\n[Attachment: \(name) failed to process]\n")
            }
        }
        return parts.joined()
    }

    /// An attachment's bytes: from the app's own store, or, for one that
    /// names a file elsewhere, from that file.
    static func bytes(of attachment: FileAttachmentDetail) async throws -> Data {
        if let url = attachment.url {
            return try Data(contentsOf: url)
        }
        return try await AttachmentStore.shared.data(of: attachment.id)
    }

    static func part(named name: String, _ body: String) -> String {
        "\n\n[Attachment: \(name)]\n\(body)\n"
    }

    /// What is said of a file with these bytes: a PDF's text as it is; any
    /// other text between fences; a note for a PDF without text, for a
    /// picture and for anything else. Text longer than `longestText`
    /// characters is cut there and marked.
    static func body(of data: Data, mimeType: String?, longestText: Int = longestText) -> String {
        if mimeType == "application/pdf" || data.starts(with: Data("%PDF-".utf8)) {
            if let text = text(ofPDF: data, longest: longestText) {
                return text.isEmpty ? pdfWithoutTextNote : text
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return fenced(cut(text, at: longestText))
        }
        return mimeType?.hasPrefix("image/") == true ? pictureNote : binaryNote
    }

    /// The text of a PDF's pages, each followed by a new line, without
    /// white space around the whole, cut and marked at `longest`
    /// characters; pages after the one that passes the limit are not read.
    /// Empty for a PDF with no text (a scan, or one that needs a
    /// password); nil if these bytes are not a PDF that can be opened.
    static func text(ofPDF data: Data, longest: Int = longestText) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        // What was read, without the white space it ends with, and how
        // many characters that is. Reading goes on until it is over the
        // limit, so that text is only whole when every page was read.
        var text = ""
        var length = 0
        // The white space read since, given only if more text follows it.
        var gap = ""
        for index in 0 ..< document.pageCount {
            guard length <= longest, !Task.isCancelled else { break }
            let page = (document.page(at: index)?.string ?? "") + "\n"
            let body = page.dropLast(page.reversed().prefix(while: \.isWhitespace).count)
            guard !body.isEmpty else {
                gap += page
                continue
            }
            // Nothing is kept of the white space a document starts with.
            let kept = text.isEmpty ? String(body.drop(while: \.isWhitespace)) : gap + body
            text += kept
            length += kept.count
            gap = String(page[body.endIndex...])
        }
        return cut(text, at: longest)
    }

    /// `text`, or its first `longest` characters and the mark that it was cut.
    static func cut(_ text: String, at longest: Int) -> String {
        guard let end = text.index(text.startIndex, offsetBy: longest, limitedBy: text.endIndex), end < text.endIndex else {
            return text
        }
        return String(text[..<end]) + cutMark
    }

    /// `text` between fences on lines of their own. The fence is three
    /// backticks, or one more than the longest run of them in the text, so
    /// that nothing in the file reads as the end of it.
    static func fenced(_ text: String) -> String {
        var longestRun = 0
        var run = 0
        for character in text.utf8 {
            run = character == UInt8(ascii: "`") ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)\n\(text)\n\(fence)"
    }

    /// A file's name on one line: a name is given as it is but for line
    /// breaks and other control characters, which become spaces, so that
    /// it cannot read as more than a name.
    static func plainName(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : scalar
        }))
    }
}
