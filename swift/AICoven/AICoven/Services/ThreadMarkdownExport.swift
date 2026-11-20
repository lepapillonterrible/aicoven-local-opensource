import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

nonisolated enum ThreadMarkdownExportError: Error, Equatable {
    /// The thread holds no sent message or completed reply.
    case empty
    case clipboardWriteFailed
}

/// What copying a thread reads and writes. Tests give their own.
struct ThreadMarkdownExportDependencies {
    /// Every message of a thread, oldest first.
    let loadMessages: (_ threadID: String) async throws -> [ChatMessage]
    /// The messages that end a turn that did not complete (see
    /// `ThreadRepository.messagesOfTurnsNotCompleted`).
    let loadUnfinished: (_ threadID: String) async throws -> Set<String>
    let loadRoles: (_ covenID: String) async throws -> [Role]
    /// Who is signed in.
    let currentAccount: @MainActor () -> String
    let writeClipboard: @MainActor (String) -> Bool

    static let live = ThreadMarkdownExportDependencies(
        loadMessages: { try await ChatService.shared.loadMessages(threadId: $0, limit: ThreadMarkdownExport.mostMessages) },
        loadUnfinished: { try await ThreadRepository.shared.messagesOfTurnsNotCompleted(threadID: $0) },
        loadRoles: { try await RoleService.shared.loadRoles(covenId: $0) },
        currentAccount: { UserScope.currentUserID },
        writeClipboard: ThreadMarkdownExport.writeClipboard
    )
}

/// What the person is told when a thread has been copied, or could not be.
struct ThreadMarkdownExportNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case failure
    }

    let id = UUID()
    let kind: Kind
    let message: String

    var title: String {
        switch kind {
        case .success: "Thread Copied"
        case .failure: "Couldn’t Copy Thread"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.message == rhs.message
    }
}

/// A thread as Markdown, as the cloud app writes it: its title as a
/// heading, then each sent message and completed reply under the name of
/// who said it.
nonisolated enum ThreadMarkdownExport {
    /// The most messages of a thread that are copied.
    static let mostMessages = 100_000

    /// The words said of each way it can end.
    static let copied = "The full thread was copied as Markdown."
    static let nothingToCopy = "There aren’t any sent messages or completed replies to copy. Your clipboard was left unchanged."
    static let clipboardFailed = "The thread was prepared, but the clipboard couldn’t be updated. Try again."
    static let failed = "The full thread couldn’t be copied. Your clipboard was left unchanged. Try again."

    /// The document: what is copied.
    static func document(title: String?, entries: [(speaker: String, body: String)]) throws -> String {
        let said = entries.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !said.isEmpty else { throw ThreadMarkdownExportError.empty }
        var markdown = "# \(escapedHeading(title ?? "Untitled"))\n\n"
        for (index, entry) in said.enumerated() {
            markdown += "## \(escapedHeading(entry.speaker))\n\n"
            markdown += entry.body
            if index < said.count - 1 { markdown += "\n\n" }
        }
        return markdown
    }

    /// Whether a message is copied: what the person sent, and replies,
    /// but not what ends a turn that did not complete.
    static func isIncluded(_ message: ChatMessage, unfinished: Set<String>) -> Bool {
        switch message.role {
        case "user": true
        case "assistant": !unfinished.contains(message.id)
        default: false
        }
    }

    /// Who said a message: the person ("You"), or the agent by the name
    /// the reply was kept under, else the thread's agent, else "Agent".
    static func speaker(of message: ChatMessage, roles: [String: String], threadAgent: String?) -> String {
        if message.role == "user" { return "You" }
        if let kept = (message.metadata?["role_name"]?.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !kept.isEmpty {
            return kept
        }
        if let roleID = (message.metadata?["role_id"]?.value as? String)?.lowercased(), let role = roles[roleID] {
            return role
        }
        let agent = threadAgent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return agent.isEmpty ? "Agent" : agent
    }

    /// A heading on one line, with what Markdown would read as markup
    /// written so that it is not.
    static func escapedHeading(_ value: String) -> String {
        let oneLine = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var escaped = oneLine
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "|"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return escaped.isEmpty ? "Untitled" : escaped
    }

    /// Reads the thread and writes its document.
    @MainActor
    static func makeDocument(thread: Thread, dependencies: ThreadMarkdownExportDependencies) async throws -> String {
        try Task.checkCancellation()
        let messages = try await dependencies.loadMessages(thread.id)
        let unfinished = try await dependencies.loadUnfinished(thread.id)
        let roles = try await thread.covenId.asyncMap(dependencies.loadRoles) ?? []
        try Task.checkCancellation()
        let names = Dictionary(roles.map { ($0.id.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        let entries = messages.filter { isIncluded($0, unfinished: unfinished) }.map { message in
            (
                speaker(of: message, roles: names, threadAgent: thread.agentName),
                message.role == "assistant" ? MessageAdapter.sanitizeContentForDisplay(message.content) : message.content
            )
        }
        return try document(title: thread.title, entries: entries)
    }

    @MainActor
    static func writeClipboard(_ value: String) -> Bool {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = value
        return UIPasteboard.general.string == value
        #else
        return false
        #endif
    }
}

private extension Optional {
    func asyncMap<Mapped>(_ transform: (Wrapped) async throws -> Mapped) async rethrows -> Mapped? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
