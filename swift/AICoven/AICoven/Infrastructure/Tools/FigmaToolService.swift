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
    /// Figma said it could not render what was asked.
    case couldNotRender

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
        case .couldNotRender:
            "Figma could not render those nodes."
        }
    }
}

/// Figma, asked with a personal access token. A token is sent to
/// api.figma.com only, in `X-Figma-Token`, and is never logged or told.
nonisolated enum FigmaToolService {
    static let host = "api.figma.com"

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

    // MARK: Rendering frames

    /// The most nodes rendered by one call, the scales Figma is asked
    /// for, and the most bytes of one rendered picture that are fetched
    /// (as the cloud app has them).
    static let mostFramesAtOnce = 3
    static let scales: ClosedRange<Double> = 0.5 ... 2
    static let largestRenderFetched = 10 * 1024 * 1024

    /// The nodes a call asks to have rendered (`nodes`): 1 to 3 node ids,
    /// given as a list, as a list written as JSON in text, or as text
    /// with commas between them. Nil for anything else. A node named
    /// twice is rendered once.
    static func nodes(in args: [String: AnyJSONValue]) -> [String]? {
        var given: [String]
        switch args["nodes"] {
        case let .array(list)?:
            given = []
            for entry in list {
                guard case let .string(id) = entry else { return nil }
                given.append(id)
            }
        case let .string(text)?:
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("["),
               let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] {
                guard let ids = list as? [String] else { return nil }
                given = ids
            } else {
                given = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            }
        default:
            return nil
        }
        var nodes: [String] = []
        for id in given.map({ $0.trimmingCharacters(in: .whitespaces) }) where !nodes.contains(id) {
            guard isNodeID(id) else { return nil }
            nodes.append(id)
        }
        return (1 ... mostFramesAtOnce).contains(nodes.count) ? nodes : nil
    }

    /// The scale a call asks for (`scale`): 1 when left out or unreadable,
    /// and kept between a half and two.
    static func scale(in args: [String: AnyJSONValue]) -> Double {
        let asked: Double? = switch args["scale"] {
        case let .double(number)?: number
        case let .int(number)?: Double(number)
        case let .string(text)?: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
        guard let asked, asked.isFinite, asked > 0 else { return 1 }
        return min(scales.upperBound, max(scales.lowerBound, asked))
    }

    /// Where Figma has put a PNG of each node, for a while: the node's
    /// id and the link. A node Figma rendered nothing for is left out.
    static func renderLinks(key: String, nodes: [String], scale: Double, token: String, session: URLSession = .shared) async throws -> [String: String] {
        let found = try await ask("GET", ["v1", "images", key], query: [
            URLQueryItem(name: "ids", value: nodes.joined(separator: ",")),
            URLQueryItem(name: "format", value: "png"),
            URLQueryItem(name: "scale", value: String(format: "%g", scale)),
        ], token: token, session: session)
        if let failure = found["err"], !(failure is NSNull) { throw FigmaError.couldNotRender }
        guard let images = found["images"] as? [String: Any] else { throw FigmaError.invalidResponse }
        return images.compactMapValues { $0 as? String }
    }

    /// Whether a rendered picture is fetched from this address: one Figma
    /// gave for its storage, which must be an https address of a named
    /// host on the internet: no user in it, no port of its own, not this
    /// machine or this network by name, and not an address in numbers.
    static func isFetchable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        guard host.contains("."), !host.hasSuffix("."), !host.contains(":") else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        // An address written in numbers, however (10.0.0.1, 2130706433.1,
        // 0x7f.0x0.0x0.0x1), names no host.
        let isANumber: (Substring) -> Bool = { part in
            if part.hasPrefix("0x") { return part.dropFirst(2).allSatisfy(\.isHexDigit) }
            return part.allSatisfy { $0.isASCII && $0.isNumber }
        }
        if host.split(separator: ".").allSatisfy(isANumber) { return false }
        return true
    }

    /// Why a rendered picture was not fetched.
    enum FetchFailure: Error, Equatable {
        case notFetchable
        case unavailable
        case tooLarge
    }

    /// Fetches a rendered picture from where Figma put it. The token is
    /// not sent (the link is signed), a redirect is not followed, and no
    /// more than `largestRenderFetched` bytes are taken.
    @concurrent
    static func fetchRender(_ link: String, session: URLSession = .shared) async throws -> Data {
        guard let url = URL(string: link), isFetchable(url) else { throw FetchFailure.notFetchable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { throw FetchFailure.unavailable }
        guard response.expectedContentLength <= Int64(largestRenderFetched) else { throw FetchFailure.tooLarge }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > largestRenderFetched { throw FetchFailure.tooLarge }
        }
        guard !data.isEmpty else { throw FetchFailure.unavailable }
        return data
    }

    /// Follows no redirect: the picture is at the address Figma gave, or
    /// it is not fetched.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// A frame as a model is sent it, or why it is not.
    enum Rendered: Equatable {
        case picture(LLMImage, width: Int, height: Int)
        case notRendered(reason: String)
    }

    /// Fetches the picture Figma made of one node and makes it what a
    /// model is sent: a JPEG, 1568 pixels on its longest edge at most.
    static func rendered(from link: String?, session: URLSession = .shared) async -> Rendered {
        guard let link else { return .notRendered(reason: "Figma returned no image") }
        let fetched: Data
        do {
            fetched = try await fetchRender(link, session: session)
        } catch FetchFailure.tooLarge {
            return .notRendered(reason: "the image is too large")
        } catch {
            return .notRendered(reason: "the image could not be fetched")
        }
        guard AttachmentImage.pixelSize(of: fetched) != nil else { return .notRendered(reason: "the image could not be read") }
        guard let jpeg = AttachmentImage.forModel(fetched, largest: AttachmentImage.largestToolPicture, tries: AttachmentImage.triesForToolPictures),
              let size = AttachmentImage.pixelSize(of: jpeg) else {
            return .notRendered(reason: "the image is too large")
        }
        return .picture(LLMImage(data: jpeg, mimeType: "image/jpeg"), width: size.width, height: size.height)
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
            let author = ((comment["user"] as? [String: Any])?["handle"] as? String).map(oneLine) ?? "Someone"
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
