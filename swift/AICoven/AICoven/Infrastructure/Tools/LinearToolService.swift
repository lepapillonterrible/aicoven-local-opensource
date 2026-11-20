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

    /// The most characters of a comment a model is told, the mark that it
    /// was cut included.
    static let mostOfAComment = 2000

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
                lines.append("- \(author), \(one(comment["createdAt"] as? String) ?? ""): \(body.count > mostOfAComment ? String(body.prefix(mostOfAComment - 1)) + "…" : body)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Changing an issue

nonisolated extension LinearToolService {
    /// The most pages of a team's states or members that are read (250 a
    /// page).
    static let mostPages = 20

    /// A team's workflow states or its members, all pages of them.
    private static func all(_ field: String, wanting: String, ofTeam teamID: String, key: String, session: URLSession) async throws -> [[String: Any]] {
        let query = """
        query ($id: String!, $after: String) {
          team(id: $id) {
            \(field)(first: 250, after: $after) {
              nodes { \(wanting) }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
        """
        var found: [[String: Any]] = []
        var after: String?
        for _ in 0 ..< mostPages {
            var variables: [String: Any] = ["id": teamID]
            if let after { variables["after"] = after }
            let data = try await ask(query, variables: variables, key: key, session: session)
            guard let page = (data["team"] as? [String: Any])?[field] as? [String: Any] else { throw LinearError.invalidResponse }
            found += page["nodes"] as? [[String: Any]] ?? []
            let info = page["pageInfo"] as? [String: Any]
            guard info?["hasNextPage"] as? Bool == true else { return found }
            guard let next = info?["endCursor"] as? String, !next.isEmpty else { throw LinearError.invalidResponse }
            after = next
        }
        // More than can be read: a name not found among these may yet be there.
        throw LinearError.refused(message: "the team has more \(field) than can be read")
    }

    /// Every workflow state of a team (id, name).
    static func states(ofTeam teamID: String, key: String, session: URLSession = .shared) async throws -> [[String: Any]] {
        try await all("states", wanting: "id name", ofTeam: teamID, key: key, session: session)
    }

    /// Every member of a team (id, name, email).
    static func members(ofTeam teamID: String, key: String, session: URLSession = .shared) async throws -> [[String: Any]] {
        try await all("members", wanting: "id name email", ofTeam: teamID, key: key, session: session)
    }

    /// Comments on an issue as the key's person; the comment's link.
    static func addComment(toIssue issueID: String, body: String, key: String, session: URLSession = .shared) async throws -> String? {
        let data = try await ask("""
        mutation ($issueId: String!, $body: String!) {
          commentCreate(input: { issueId: $issueId, body: $body }) {
            success
            comment { url }
          }
        }
        """, variables: ["issueId": issueID, "body": body], key: key, session: session)
        guard let made = data["commentCreate"] as? [String: Any], made["success"] as? Bool == true else {
            throw LinearError.refused(message: "Linear did not add the comment")
        }
        return (made["comment"] as? [String: Any])?["url"] as? String
    }

    /// Changes an issue (`changes` is Linear's `IssueUpdateInput`); the
    /// issue as it is afterwards.
    static func update(issue issueID: String, changes: [String: Any], key: String, session: URLSession = .shared) async throws -> [String: Any] {
        let data = try await ask("""
        mutation ($id: String!, $input: IssueUpdateInput!) {
          issueUpdate(id: $id, input: $input) {
            success
            issue {
              identifier url title description priority dueDate
              state { name }
              assignee { name }
            }
          }
        }
        """, variables: ["id": issueID, "input": changes], key: key, session: session)
        guard let made = data["issueUpdate"] as? [String: Any], made["success"] as? Bool == true, let issue = made["issue"] as? [String: Any] else {
            throw LinearError.refused(message: "Linear did not update the issue")
        }
        return issue
    }

    // MARK: What a call asks to change

    /// What `linear.updateIssue` is asked to change, as its call says it.
    struct Asked: Equatable {
        var title: String?
        var description: String?
        var priority: Int?
        var dueDate: String?
        /// A status by its name, and an assignee by name or email: Linear
        /// is asked which of the team's they are.
        var status: String?
        var assignee: String?

        var isNothing: Bool {
            self == Asked()
        }
    }

    /// Why a call's arguments could not be read.
    struct ArgumentRefusal: Error, Equatable {
        let message: String
        let field: String
    }

    /// Reads what a call asks to change. An argument left out, or given
    /// as null, is not changed; one that is given must read as what it
    /// is. At least one must be given.
    static func asked(in args: [String: AnyJSONValue]) -> Result<Asked, ArgumentRefusal> {
        func given(_ key: String) -> AnyJSONValue? {
            guard let value = args[key], value != .null else { return nil }
            return value
        }
        func text(_ key: String, mayBeEmpty: Bool = false) -> Result<String?, ArgumentRefusal> {
            guard let value = given(key) else { return .success(nil) }
            guard case let .string(text) = value, mayBeEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(ArgumentRefusal(message: "'\(key)' must be text\(mayBeEmpty ? "" : " that says something"), or be left out.", field: key))
            }
            return .success(mayBeEmpty ? text : text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var asked = Asked()
        do {
            asked.title = try text("title").get()
            asked.description = try text("description", mayBeEmpty: true).get()
            asked.status = try text("status").get()
            asked.assignee = try text("assignee").get()
            asked.dueDate = try text("due_date").get()
        } catch {
            return .failure(error as? ArgumentRefusal ?? ArgumentRefusal(message: "The arguments could not be read.", field: "issue"))
        }
        // A title is one line (and is shown to the person on one).
        if let title = asked.title, title.contains(where: \.isNewline) {
            return .failure(ArgumentRefusal(message: "'title' must be one line.", field: "title"))
        }
        if let due = asked.dueDate, due.range(of: #"\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\z"#, options: .regularExpression) == nil {
            return .failure(ArgumentRefusal(message: "'due_date' must be a date written YYYY-MM-DD.", field: "due_date"))
        }
        if let priority = given("priority") {
            let number: Int? = switch priority {
            case let .int(value): value
            case let .double(value): Int(exactly: value)
            case let .string(digits): ["0", "1", "2", "3", "4"].contains(digits.trimmingCharacters(in: .whitespaces)) ? Int(digits.trimmingCharacters(in: .whitespaces)) : nil
            default: nil
            }
            guard let number, (0 ... 4).contains(number) else {
                return .failure(ArgumentRefusal(message: "'priority' must be a whole number from 0 to 4: 0 (none), 1 (urgent), 2 (high), 3 (medium) or 4 (low).", field: "priority"))
            }
            asked.priority = number
        }
        guard !asked.isNothing else {
            return .failure(ArgumentRefusal(message: "Give at least one of 'status', 'assignee', 'title', 'description', 'priority', 'due_date'.", field: "status"))
        }
        return .success(asked)
    }

    /// The state of that name among a team's (case does not matter), or
    /// why there is none: the names there are.
    static func state(named name: String, among states: [[String: Any]], team: String) -> Result<(id: String, name: String), ArgumentRefusal> {
        let wanted = name.lowercased()
        let named = states.compactMap { state -> (id: String, name: String)? in
            guard let id = state["id"] as? String, let name = state["name"] as? String else { return nil }
            return (id, name)
        }
        if let found = named.first(where: { $0.name.lowercased() == wanted }) { return .success(found) }
        return .failure(ArgumentRefusal(message: "No status '\(name)' in team \(team). Statuses: \(named.map(\.name).joined(separator: ", "))", field: "status"))
    }

    /// The one member of a team with that name or email (case does not
    /// matter), or why there is not exactly one.
    static func member(matching wanted: String, among members: [[String: Any]], team: String) -> Result<(id: String, name: String), ArgumentRefusal> {
        let sought = wanted.lowercased()
        let matches = members.compactMap { member -> (id: String, name: String)? in
            guard let id = member["id"] as? String, let name = member["name"] as? String else { return nil }
            return name.lowercased() == sought || (member["email"] as? String)?.lowercased() == sought ? (id, name) : nil
        }
        guard matches.count == 1 else {
            return .failure(ArgumentRefusal(message: "'\(wanted)' matches \(matches.count) members of team \(team); give one member's name or email.", field: "assignee"))
        }
        return .success(matches[0])
    }

    /// An issue's title on one line, as the person is shown it.
    static func title(of issue: [String: Any]) -> String {
        let title = oneLine(issue["title"] as? String ?? "")
        return title.isEmpty ? "(untitled)" : title
    }

    /// Text on one line: a name of Linear's shown within a line.
    static func oneLine(_ text: String) -> String {
        String(text.map { $0.isNewline ? " " : $0 }).trimmingCharacters(in: .whitespaces)
    }

    /// An issue as an approval names it: its identifier and its title.
    static func named(_ issue: [String: Any]) -> String {
        "\(issue["identifier"] as? String ?? "?"): \(title(of: issue))"
    }
}
