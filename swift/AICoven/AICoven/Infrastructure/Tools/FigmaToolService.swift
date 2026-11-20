import Foundation

/// What Figma's REST API is asked with a person's personal access token.
nonisolated enum FigmaError: LocalizedError, Equatable {
    /// Figma refused the token: it is wrong, expired or revoked.
    case tokenRefused
    /// Figma is limiting how often this account asks; it may say how many
    /// seconds to wait.
    case rateLimited(retryAfter: Int?)
    /// Figma answered with something other than what was asked for.
    case notAnswered(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .tokenRefused:
            "Figma refused the token."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Figma is limiting how often this account asks. Try again in \($0) seconds." } ?? "Figma is limiting how often this account asks. Try again later."
        case let .notAnswered(status):
            "Figma answered HTTP \(status)."
        case .invalidResponse:
            "Figma's answer could not be read."
        }
    }
}

/// Figma, asked with a personal access token. A token is sent to
/// api.figma.com only, in `X-Figma-Token`, and is never logged or told.
nonisolated enum FigmaToolService {
    static let host = "api.figma.com"

    /// The most characters a token may have (as the cloud app takes them).
    static let longestToken = 512

    /// Who a token belongs to.
    struct Identity: Equatable {
        /// Figma's id of the user.
        let id: String
        /// What the account is shown as: the email, else the handle.
        let label: String
    }

    /// Who a token belongs to, from `GET /v1/me`. Throws
    /// `FigmaError.tokenRefused` where Figma refuses the token.
    @concurrent
    static func identity(token: String, session: URLSession = .shared) async throws -> Identity {
        guard let path = RequestPath.path(of: ["v1", "me"]), let url = URL(string: "https://\(host)\(path)") else {
            throw FigmaError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FigmaError.invalidResponse }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw FigmaError.tokenRefused
        case 429:
            throw FigmaError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default:
            throw FigmaError.notAnswered(status: http.statusCode)
        }
        guard let me = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = me["id"] as? String, !id.isEmpty else {
            throw FigmaError.invalidResponse
        }
        let named = [me["email"], me["handle"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        return Identity(id: id, label: named ?? "Figma")
    }
}

// MARK: - Files and comments

nonisolated extension FigmaError {
    /// Figma accepted the token but does not let this account see the
    /// file, or do this with it.
    static let forbidden = FigmaError.notAnswered(status: 403)
    /// Figma has no such file, node or comment.
    static let notFound = FigmaError.notAnswered(status: 404)
}

nonisolated extension FigmaToolService {
    /// The editors whose links name a file: figma.com/<editor>/<key>/…
    static let fileEditors: Set<String> = ["design", "file", "board", "proto", "slides", "deck", "make"]

    /// A file's key, given as the key or as the file's link; nil for
    /// anything else. A key is ASCII letters and digits; in a link it is
    /// the step after the editor's name, on figma.com over https.
    static func fileKey(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        func isKey(_ key: String, atLeast: Int) -> Bool {
            key.utf8.count >= atLeast && key.utf8.count <= 128 && key.utf8.allSatisfy { byte in
                (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
            }
        }
        // A link has a scheme and steps; a key has neither a colon nor a
        // slash (a key may itself begin "http").
        if text.contains(":") || text.contains("/") {
            guard let link = URLComponents(string: text), link.scheme == "https", let host = link.host?.lowercased(), host == "figma.com" || host == "www.figma.com" else { return nil }
            let steps = link.path.split(separator: "/").map(String.init)
            guard steps.count >= 2, fileEditors.contains(steps[0]), isKey(steps[1], atLeast: 10) else { return nil }
            return steps[1]
        }
        return isKey(text, atLeast: 1) ? text : nil
    }

    /// Whether this reads as the id of a node, as Figma writes them
    /// (`3:21`, or `I5:2;1:8` for one inside an instance).
    static func isNodeID(_ id: String) -> Bool {
        id.range(of: #"\AI?[0-9]+:[0-9]+(;[0-9]+:[0-9]+)*\z"#, options: .regularExpression) != nil
    }

    /// One request of Figma, answered with JSON. 401 and 403 are told
    /// apart by asking whose the token is: a token Figma no longer takes
    /// is `.tokenRefused`; one it takes means the file is not this
    /// account's to see (`.forbidden`).
    @concurrent
    static func ask(_ method: String, _ steps: [String], query: [URLQueryItem] = [], body: [String: Any]? = nil, token: String, session: URLSession = .shared) async throws -> [String: Any] {
        guard let path = RequestPath.path(of: steps), var components = URLComponents(string: "https://\(host)\(path)") else {
            throw FigmaError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw FigmaError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FigmaError.invalidResponse }
        switch http.statusCode {
        case 200 ..< 300:
            guard let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FigmaError.invalidResponse }
            return answer
        case 401, 403:
            // Is it the token, or this file?
            _ = try await identity(token: token, session: session)
            throw FigmaError.forbidden
        case 404:
            throw FigmaError.notFound
        case 429:
            throw FigmaError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default:
            throw FigmaError.notAnswered(status: http.statusCode)
        }
    }

    /// A file's name and its document to `depth` levels, or one node's
    /// subtree.
    static func fileTree(key: String, node: String?, depth: Int, token: String, session: URLSession = .shared) async throws -> (name: String?, document: [String: Any]) {
        let levels = URLQueryItem(name: "depth", value: String(depth))
        if let node {
            let found = try await ask("GET", ["v1", "files", key, "nodes"], query: [URLQueryItem(name: "ids", value: node), levels], token: token, session: session)
            guard let document = ((found["nodes"] as? [String: Any])?[node] as? [String: Any])?["document"] as? [String: Any] else { throw FigmaError.notFound }
            return (found["name"] as? String, document)
        }
        let found = try await ask("GET", ["v1", "files", key], query: [levels], token: token, session: session)
        return (found["name"] as? String, found["document"] as? [String: Any] ?? [:])
    }

    /// A file's comments, as Figma gives them.
    static func comments(key: String, token: String, session: URLSession = .shared) async throws -> [[String: Any]] {
        try await ask("GET", ["v1", "files", key, "comments"], token: token, session: session)["comments"] as? [[String: Any]] ?? []
    }

    /// Posts a comment on a file, or a reply to one.
    static func postComment(key: String, message: String, replyTo: String?, token: String, session: URLSession = .shared) async throws -> [String: Any] {
        var body: [String: Any] = ["message": message]
        if let replyTo { body["comment_id"] = replyTo }
        return try await ask("POST", ["v1", "files", key, "comments"], body: body, token: token, session: session)
    }

    // MARK: What a model is told

    /// The most nodes of a file a model is told of, and how deep it is
    /// read (as the cloud app has them).
    static let mostNodes = 400
    static let standardDepth = 2
    static let deepest = 4
    /// The newest comments a model is told of.
    static let mostComments = 200

    /// Text on one line: each line break in it (of any kind; a CRLF is
    /// one) made one space.
    static func oneLine(_ text: String) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }

    /// How many nodes a node is, with all those under it.
    static func count(of node: [String: Any]) -> Int {
        1 + (node["children"] as? [[String: Any]] ?? []).reduce(0) { $0 + count(of: $1) }
    }

    /// A node and those under it as an outline, a line each: its name,
    /// then its id and kind. No more than `left` nodes are written; where
    /// a node's children were left out, its line says how many of them,
    /// and `omitted` counts every node left out, with those under them.
    static func outline(of node: [String: Any], left: inout Int, indent: Int = 0) -> (lines: [String], omitted: Int) {
        left -= 1
        let children = node["children"] as? [[String: Any]] ?? []
        var lines: [String] = []
        var omitted = 0
        var kept = 0
        for child in children {
            guard left > 0 else { break }
            let under = outline(of: child, left: &left, indent: indent + 1)
            lines += under.lines
            omitted += under.omitted
            kept += 1
        }
        let cut = children.count - kept
        omitted += children.dropFirst(kept).reduce(0) { $0 + count(of: $1) }
        let name = (node["name"] as? String).map(oneLine) ?? "(unnamed)"
        let line = String(repeating: "  ", count: indent) + "- \(name) [\(node["id"] as? String ?? "?"), \(node["type"] as? String ?? "?")]"
            + (cut > 0 ? " (\(cut) more under it not shown)" : "")
        return ([line] + lines, omitted)
    }

    /// A file's comments as a model is told them: those not resolved (or
    /// all), newest first, `mostComments` at most. A reply is resolved
    /// when the comment it answers is: Figma marks only a thread's first.
    static func told(comments: [[String: Any]], includingResolved: Bool) -> (lines: [String], more: Bool) {
        let resolvedIDs = Set(comments.filter { $0["resolved_at"] is String }.compactMap { $0["id"] as? String })
        func isResolved(_ comment: [String: Any]) -> Bool {
            comment["resolved_at"] is String || (comment["parent_id"] as? String).map(resolvedIDs.contains) == true
        }
        let shown = comments
            .filter { includingResolved || !isResolved($0) }
            .sorted { ($0["created_at"] as? String ?? "") > ($1["created_at"] as? String ?? "") }
        let lines = shown.prefix(mostComments).map { comment -> String in
            let id = comment["id"] as? String ?? "?"
            let author = (comment["user"] as? [String: Any])?["handle"] as? String ?? "Someone"
            let when = comment["created_at"] as? String ?? ""
            var notes: [String] = []
            if let parent = comment["parent_id"] as? String, !parent.isEmpty { notes.append("reply to \(parent)") }
            if let node = (comment["client_meta"] as? [String: Any])?["node_id"] as? String { notes.append("on node \(node)") }
            if isResolved(comment) { notes.append("resolved") }
            let message = oneLine(comment["message"] as? String ?? "")
            return "- [\(id)] \(author), \(when)\(notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"): \(message)"
        }
        return (Array(lines), shown.count > mostComments)
    }
}
