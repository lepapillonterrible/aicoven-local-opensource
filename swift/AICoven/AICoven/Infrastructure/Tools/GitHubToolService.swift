import Foundation

/// Service for GitHub API operations using connected account tokens.
/// Provides tools for repos, files, branches, PRs, and issues.
actor GitHubToolService {

    /// Shared singleton instance
    static let shared = GitHubToolService()

    /// Base URL for GitHub API
    private let baseURL = "https://api.github.com"

    /// Connected accounts service for token management
    private let accountsService = ConnectedAccountsService.shared

    private init() {}

    // MARK: - HTTP Helpers

    /// Make an authenticated request to GitHub API
    private func request(
        method: String,
        path: String,
        accountId: String,
        queryParams: [String: String]? = nil,
        body: [String: Any]? = nil,
        timeout: TimeInterval = 15.0
    ) async throws -> (Data, HTTPURLResponse) {
        // Get access token
        let accessToken = try await accountsService.getAccessToken(forAccountId: accountId)

        // Build URL
        var components = URLComponents(string: baseURL + path)!
        if let queryParams {
            components.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw GitHubError.invalidURL(path: path)
        }

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = timeout

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Execute request
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse
        }

        // Handle 401 by attempting token refresh
        if httpResponse.statusCode == 401 {
            // For GitHub, tokens don't expire, so 401 means revoked
            throw GitHubError.unauthorized(message: "GitHub token has been revoked. Please reconnect your GitHub account.")
        }

        return (data, httpResponse)
    }

    /// Parse GitHub error response into actionable message
    private func parseError(statusCode: Int, data: Data, context: String) -> GitHubError {
        let message: String = if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                 let msg = json["message"] as? String {
            msg
        } else {
            String(data: data, encoding: .utf8) ?? "Unknown error"
        }

        switch statusCode {
        case 404:
            return .notFound(resource: context, message: message)
        case 409:
            return .conflict(message: message)
        case 422:
            return .validationError(message: message)
        case 403:
            return .forbidden(message: message)
        default:
            return .apiError(statusCode: statusCode, message: message)
        }
    }

    // MARK: - Repositories

    /// List repositories accessible by the connected account
    func listRepos(
        accountId: String,
        visibility: String = "all",
        affiliation: String = "owner,collaborator,organization_member",
        perPage: Int = 50
    ) async throws -> [[String: Any]] {
        let params = [
            "visibility": visibility,
            "affiliation": affiliation,
            "per_page": String(min(perPage, 100))
        ]

        let (data, response) = try await request(
            method: "GET",
            path: "/user/repos",
            accountId: accountId,
            queryParams: params
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: "list_repos")
        }

        guard let repos = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.invalidResponse
        }

        return repos
    }

    /// Get repository information
    func getRepo(accountId: String, owner: String, repo: String) async throws -> [String: Any] {
        let (data, response) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)",
            accountId: accountId
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: "\(owner)/\(repo)")
        }

        guard let repoInfo = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse
        }

        return repoInfo
    }

    // MARK: - Files

    /// List files in a repository path
    func listFiles(
        accountId: String,
        owner: String,
        repo: String,
        path: String = "",
        ref: String? = nil
    ) async throws -> [[String: Any]] {
        var params: [String: String] = [:]
        if let ref { params["ref"] = ref }

        let (data, response) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/contents/\(path)",
            accountId: accountId,
            queryParams: params.isEmpty ? nil : params
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: path)
        }

        // API returns either a list (directory) or a single file object
        if let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return files
        } else if let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [file]
        } else {
            throw GitHubError.invalidResponse
        }
    }

    /// Read file contents from a repository
    func readFile(
        accountId: String,
        owner: String,
        repo: String,
        path: String,
        ref: String? = nil
    ) async throws -> String {
        var params: [String: String] = [:]
        if let ref { params["ref"] = ref }

        let (data, response) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/contents/\(path)",
            accountId: accountId,
            queryParams: params.isEmpty ? nil : params
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: path)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoding = json["encoding"] as? String, encoding == "base64",
              let content = json["content"] as? String else {
            throw GitHubError.invalidResponse
        }

        // Decode base64 content
        let cleanedContent = content.replacingOccurrences(of: "\n", with: "")
        guard let decodedData = Data(base64Encoded: cleanedContent),
              let decodedString = String(data: decodedData, encoding: .utf8) else {
            throw GitHubError.decodingFailed(path: path)
        }

        return decodedString
    }

    /// Write file to a repository (create or update)
    func writeFile(
        accountId: String,
        owner: String,
        repo: String,
        path: String,
        content: String,
        message: String,
        branch: String? = nil,
        sha: String? = nil
    ) async throws -> [String: Any] {
        // Encode content as base64
        guard let contentData = content.data(using: .utf8) else {
            throw GitHubError.encodingFailed(path: path)
        }
        let base64Content = contentData.base64EncodedString()

        var body: [String: Any] = [
            "message": message,
            "content": base64Content
        ]
        if let branch { body["branch"] = branch }
        if let sha { body["sha"] = sha }

        let (data, response) = try await request(
            method: "PUT",
            path: "/repos/\(owner)/\(repo)/contents/\(path)",
            accountId: accountId,
            body: body,
            timeout: 20.0
        )

        if response.statusCode != 200, response.statusCode != 201 {
            throw parseError(statusCode: response.statusCode, data: data, context: path)
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse
        }

        return result
    }

    /// Get file info including SHA (for updates)
    func getFileInfo(
        accountId: String,
        owner: String,
        repo: String,
        path: String,
        ref: String? = nil
    ) async throws -> (content: String, sha: String)? {
        var params: [String: String] = [:]
        if let ref { params["ref"] = ref }

        let (data, response) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/contents/\(path)",
            accountId: accountId,
            queryParams: params.isEmpty ? nil : params
        )

        if response.statusCode == 404 {
            return nil
        }

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: path)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoding = json["encoding"] as? String, encoding == "base64",
              let content = json["content"] as? String,
              let sha = json["sha"] as? String else {
            throw GitHubError.invalidResponse
        }

        // Decode base64 content
        let cleanedContent = content.replacingOccurrences(of: "\n", with: "")
        guard let decodedData = Data(base64Encoded: cleanedContent),
              let decodedString = String(data: decodedData, encoding: .utf8) else {
            throw GitHubError.decodingFailed(path: path)
        }

        return (content: decodedString, sha: sha)
    }

    // MARK: - Branches

    /// List branches for a repository
    func listBranches(
        accountId: String,
        owner: String,
        repo: String,
        perPage: Int = 50
    ) async throws -> [[String: Any]] {
        let params = ["per_page": String(min(perPage, 100))]

        let (data, response) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/branches",
            accountId: accountId,
            queryParams: params
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: "branches")
        }

        guard let branches = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.invalidResponse
        }

        return branches
    }

    /// Create a new branch from a base ref
    func createBranch(
        accountId: String,
        owner: String,
        repo: String,
        baseBranch: String,
        newBranch: String
    ) async throws -> [String: Any] {
        // 1. Get the SHA of the base branch
        let (refData, refResponse) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/git/refs/heads/\(baseBranch)",
            accountId: accountId
        )

        if refResponse.statusCode != 200 {
            throw parseError(statusCode: refResponse.statusCode, data: refData, context: "base branch '\(baseBranch)'")
        }

        guard let refJson = try JSONSerialization.jsonObject(with: refData) as? [String: Any],
              let object = refJson["object"] as? [String: Any],
              let baseSha = object["sha"] as? String else {
            throw GitHubError.invalidResponse
        }

        // 2. Create the new branch ref
        let body: [String: Any] = [
            "ref": "refs/heads/\(newBranch)",
            "sha": baseSha
        ]

        let (createData, createResponse) = try await request(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/git/refs",
            accountId: accountId,
            body: body
        )

        // Handle "already exists" gracefully
        if createResponse.statusCode == 422 {
            let errorText = String(data: createData, encoding: .utf8)?.lowercased() ?? ""
            if errorText.contains("already exists") || errorText.contains("reference already exists") {
                // Fetch existing branch info
                let (existingData, existingResponse) = try await request(
                    method: "GET",
                    path: "/repos/\(owner)/\(repo)/git/refs/heads/\(newBranch)",
                    accountId: accountId
                )

                if existingResponse.statusCode == 200,
                   var result = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                    result["_branch_already_existed"] = true
                    return result
                }
            }
        }

        if createResponse.statusCode != 200, createResponse.statusCode != 201 {
            throw parseError(statusCode: createResponse.statusCode, data: createData, context: "create branch '\(newBranch)'")
        }

        guard var result = try JSONSerialization.jsonObject(with: createData) as? [String: Any] else {
            throw GitHubError.invalidResponse
        }

        result["_branch_already_existed"] = false

        // Wait for branch propagation
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        return result
    }

    // MARK: - Pull Requests

    /// Create a pull request
    func createPullRequest(
        accountId: String,
        owner: String,
        repo: String,
        title: String,
        head: String,
        base: String,
        body: String? = nil,
        draft: Bool = false
    ) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "title": title,
            "head": head,
            "base": base,
            "draft": draft
        ]
        if let body { payload["body"] = body }

        let (data, response) = try await request(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/pulls",
            accountId: accountId,
            body: payload,
            timeout: 20.0
        )

        if response.statusCode != 200, response.statusCode != 201 {
            throw parseError(statusCode: response.statusCode, data: data, context: "create PR")
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse
        }

        return result
    }

    /// Get a pull request
    func getPullRequest(
        accountId: String,
        owner: String,
        repo: String,
        pullNumber: Int
    ) async throws -> [String: Any] {
        let (data, response) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/pulls/\(pullNumber)",
            accountId: accountId
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: "PR #\(pullNumber)")
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse
        }

        return result
    }

    /// List files changed in a pull request
    func listPullRequestFiles(
        accountId: String,
        owner: String,
        repo: String,
        pullNumber: Int,
        perPage: Int = 50
    ) async throws -> [[String: Any]] {
        let params = ["per_page": String(min(perPage, 100))]

        let (data, response) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/pulls/\(pullNumber)/files",
            accountId: accountId,
            queryParams: params
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: "PR #\(pullNumber) files")
        }

        guard let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.invalidResponse
        }

        return files
    }

    // MARK: - Issues

    /// List issues for a repository
    func listIssues(
        accountId: String,
        owner: String,
        repo: String,
        state: String = "open",
        perPage: Int = 50
    ) async throws -> [[String: Any]] {
        let params = [
            "state": state,
            "per_page": String(min(perPage, 100))
        ]

        let (data, response) = try await request(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/issues",
            accountId: accountId,
            queryParams: params
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: "issues")
        }

        guard let issues = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.invalidResponse
        }

        return issues
    }

    /// Create an issue
    func createIssue(
        accountId: String,
        owner: String,
        repo: String,
        title: String,
        body: String? = nil,
        labels: [String]? = nil
    ) async throws -> [String: Any] {
        var payload: [String: Any] = ["title": title]
        if let body { payload["body"] = body }
        if let labels { payload["labels"] = labels }

        let (data, response) = try await request(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/issues",
            accountId: accountId,
            body: payload,
            timeout: 20.0
        )

        if response.statusCode != 200, response.statusCode != 201 {
            throw parseError(statusCode: response.statusCode, data: data, context: "create issue")
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse
        }

        return result
    }

    // MARK: - Search

    /// Search code in repositories
    func searchCode(
        accountId: String,
        query: String,
        perPage: Int = 30
    ) async throws -> [String: Any] {
        let params = [
            "q": query,
            "per_page": String(min(perPage, 100))
        ]

        let (data, response) = try await request(
            method: "GET",
            path: "/search/code",
            accountId: accountId,
            queryParams: params,
            timeout: 20.0
        )

        if response.statusCode != 200 {
            throw parseError(statusCode: response.statusCode, data: data, context: "search")
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse
        }

        return result
    }
}

// MARK: - Errors

/// Errors that can occur during GitHub API operations
enum GitHubError: LocalizedError {
    case invalidURL(path: String)
    case invalidResponse
    case unauthorized(message: String)
    case notFound(resource: String, message: String)
    case conflict(message: String)
    case validationError(message: String)
    case forbidden(message: String)
    case apiError(statusCode: Int, message: String)
    case decodingFailed(path: String)
    case encodingFailed(path: String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(path):
            "Invalid GitHub API URL: \(path)"
        case .invalidResponse:
            "Invalid response from GitHub API"
        case let .unauthorized(message):
            "GitHub unauthorized: \(message)"
        case let .notFound(resource, message):
            "GitHub resource not found (\(resource)): \(message)"
        case let .conflict(message):
            "GitHub conflict: \(message)"
        case let .validationError(message):
            "GitHub validation error: \(message)"
        case let .forbidden(message):
            "GitHub forbidden: \(message)"
        case let .apiError(statusCode, message):
            "GitHub API error (\(statusCode)): \(message)"
        case let .decodingFailed(path):
            "Failed to decode file content: \(path)"
        case let .encodingFailed(path):
            "Failed to encode file content: \(path)"
        }
    }
}
