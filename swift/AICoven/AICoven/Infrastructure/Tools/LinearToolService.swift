import Foundation

/// What Linear's API is asked with a person's personal API key.
nonisolated enum LinearError: LocalizedError, Equatable {
    /// Linear refused the key: it is wrong or was revoked.
    case keyRefused
    /// Linear is limiting how often this person asks; it may say how many
    /// seconds to wait.
    case rateLimited(retryAfter: Int?)
    /// Linear answered with an error of its own, in its words.
    case refused(message: String)
    /// Linear answered with something other than what was asked for.
    case notAnswered(status: Int)
    case invalidResponse
    /// Linear has no such issue (or does not let this person see it).
    case notFound

    var errorDescription: String? {
        switch self {
        case .keyRefused:
            "Linear refused the key."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Linear is limiting how often this account asks. Try again in \($0) seconds." } ?? "Linear is limiting how often this account asks. Try again later."
        case let .refused(message):
            "Linear did not do it: \(message)"
        case let .notAnswered(status):
            "Linear answered HTTP \(status)."
        case .invalidResponse:
            "Linear's answer could not be read."
        case .notFound:
            "Linear found no such issue."
        }
    }
}

/// Linear, asked with a personal API key. A key is sent to
/// api.linear.app only, as the whole of `Authorization` (Linear takes a
/// personal key bare, not after "Bearer"), and is never logged or told.
nonisolated enum LinearToolService {
    static let endpoint = "https://api.linear.app/graphql"

    /// The most of Linear's own words about an error that are passed on.
    static let mostOfAMessage = 300

    /// One GraphQL request; its `data`. An answer can carry `errors`
    /// beside its data, whatever its status: they are read first.
    @concurrent
    static func ask(_ query: String, variables: [String: Any] = [:], key: String, session: URLSession = .shared) async throws -> [String: Any] {
        guard let url = URL(string: endpoint) else { throw LinearError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LinearError.invalidResponse }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errors = body?["errors"] as? [[String: Any]] ?? []
        // What each error says it is, in Linear's own codes.
        let kinds = errors.flatMap { error -> [String] in
            let extensions = error["extensions"] as? [String: Any]
            return [extensions?["code"], extensions?["type"]].compactMap { ($0 as? String)?.lowercased() }
        }
        if http.statusCode == 401 || http.statusCode == 403 || kinds.contains(where: { $0.contains("authentication") }) {
            throw LinearError.keyRefused
        }
        if http.statusCode == 429 || kinds.contains(where: { $0.contains("ratelimit") }) {
            throw LinearError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        if let first = errors.first {
            let said = (first["message"] as? String).map { String($0.prefix(mostOfAMessage)) } ?? "no reason given"
            throw LinearError.refused(message: said)
        }
        guard (200 ..< 300).contains(http.statusCode) else { throw LinearError.notAnswered(status: http.statusCode) }
        guard let answer = body?["data"] as? [String: Any] else { throw LinearError.invalidResponse }
        return answer
    }

    /// Who a key belongs to: Linear's id of the person, and what the
    /// connection is shown as (the email, else the name).
    static func identity(key: String, session: URLSession = .shared) async throws -> (id: String, label: String) {
        let data = try await ask("query { viewer { id name email } }", key: key, session: session)
        guard let viewer = data["viewer"] as? [String: Any], let id = viewer["id"] as? String, !id.isEmpty else {
            throw LinearError.invalidResponse
        }
        let named = [viewer["email"], viewer["name"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        return (id, named ?? "Linear")
    }

    // MARK: - Issues

    /// An issue as a call names it: its identifier (`ENG-12`), its id, or
    /// its link on linear.app; nil for anything else.
    static func issueReference(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        func isIdentifier(_ text: String) -> Bool {
            text.range(of: #"\A[A-Za-z][A-Za-z0-9]{0,19}-[0-9]{1,9}\z"#, options: .regularExpression) != nil
        }
        if text.contains("/") {
            // https://linear.app/<workspace>/issue/ENG-12/a-title
            guard let link = URLComponents(string: text), link.scheme == "https", link.host?.lowercased() == "linear.app" else { return nil }
            let steps = link.path.split(separator: "/").map(String.init)
            guard let at = steps.firstIndex(of: "issue"), at + 1 < steps.count, isIdentifier(steps[at + 1]) else { return nil }
            return steps[at + 1].uppercased()
        }
        if isIdentifier(text) { return text.uppercased() }
        return UUID(uuidString: text) != nil ? text.lowercased() : nil
    }

    static let issueQuery = """
    query ($id: String!) {
      issue(id: $id) {
        id identifier title description url priority dueDate
        state { id name type }
        assignee { id name email }
        team { id name }
        comments(first: 20) {
          nodes { url body createdAt user { name } }
        }
      }
    }
    """

    /// One issue, with its state, assignee, team and latest comments.
    static func issue(_ reference: String, key: String, session: URLSession = .shared) async throws -> [String: Any] {
        do {
            let data = try await ask(issueQuery, variables: ["id": reference], key: key, session: session)
            guard let issue = data["issue"] as? [String: Any] else { throw LinearError.notFound }
            return issue
        } catch let LinearError.refused(message) where message.localizedCaseInsensitiveContains("not found") {
            // Linear's own word for an issue it does not have.
            throw LinearError.notFound
        }
    }

    // MARK: What a model is told

    /// What Linear's priority numbers are called.
    static func priorityName(_ priority: Int) -> String {
        switch priority {
        case 1: "Urgent"
        case 2: "High"
        case 3: "Medium"
        case 4: "Low"
        default: "None"
        }
    }

    /// An issue as a model is told it: what it is, where it stands, its
    /// description and its latest comments.
    static func told(issue: [String: Any]) -> String {
        func one(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return nil }
            return String(text.map { $0.isNewline ? " " : $0 })
        }
        func name(_ key: String) -> String? {
            one((issue[key] as? [String: Any])?["name"] as? String)
        }
        let identifier = one(issue["identifier"] as? String) ?? "?"
        var lines = ["[Linear Issue: \(identifier)] \(one(issue["title"] as? String) ?? "(untitled)")"]
        if let url = one(issue["url"] as? String) { lines.append("URL: \(url)") }
        var facts = ["State: \(name("state") ?? "(none)")", "Assignee: \(name("assignee") ?? "(no one)")"]
        if let team = name("team") { facts.append("Team: \(team)") }
        if let priority = issue["priority"] as? Int { facts.append("Priority: \(priorityName(priority))") }
        if let due = one(issue["dueDate"] as? String) { facts.append("Due: \(due)") }
        lines.append(facts.joined(separator: " · "))
        let description = (issue["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append("")
        lines.append("Description:")
        lines.append(description.isEmpty ? "(none)" : GoogleToolArguments.cut(description))
        let comments = (issue["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        if !comments.isEmpty {
            lines.append("")
            lines.append("Comments (the latest \(comments.count)):")
            for comment in comments {
                let author = one((comment["user"] as? [String: Any])?["name"] as? String) ?? "Someone"
                let body = one(comment["body"] as? String) ?? ""
                lines.append("- \(author), \(one(comment["createdAt"] as? String) ?? ""): \(body.count > 2000 ? String(body.prefix(2000)) + "…" : body)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
