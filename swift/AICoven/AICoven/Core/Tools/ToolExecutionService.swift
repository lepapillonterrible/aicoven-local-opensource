import Foundation

/// Central dispatcher for all tool execution in the agent system.
/// Handles permission checking, rate limiting, and routing to specific tool services.
actor ToolExecutionService {
    
    static let shared = ToolExecutionService()
    
    // Dependencies
    private let fileService = FileToolService.shared
    private let shellService = ShellToolService.shared
    private let toolService: any ChatToolService
    private let githubService = GitHubToolService.shared
    private let googleDriveService = GoogleDriveToolService.shared
    private let connectedAccountsService = ConnectedAccountsService.shared
    
    /// Default initializer uses the shared ToolService singleton.
    init() {
        self.toolService = ToolService.shared
    }
    
    /// Test-friendly initializer that accepts a mock tool service.
    init(toolService: any ChatToolService) {
        self.toolService = toolService
    }
    
    // Configuration
    private var toolWhitelist: [String: Set<String>] = [:] // AgentType -> AllowedTools
    private var globalRateLimit: Int = 60 // Calls per minute
    private var callLog: [Date] = []
    
    // MARK: - Execution Entry Point
    
    /// Execute a tool call with permission and rate limit checks.
    /// - Parameters:
    ///   - toolCall: The parsed tool call to execute.
    ///   - agentType: The type of agent making the call (for permissions).
    ///   - threadID: Context thread ID.
    /// - Returns: Standardized execution result.
    // MARK: - Entitlement gating for paid tools
    
    /// Tool name prefixes that require the Tools Pack purchase.
    private static let toolsPackPrefixes = ["shell.", "github.", "google_drive.", "google_sheets."]
    
    /// Returns true when the given tool name requires the Tools Pack entitlement.
    private func requiresToolsPack(_ toolName: String) -> Bool {
        Self.toolsPackPrefixes.contains { toolName.hasPrefix($0) }
    }
    
    /// Check the Tools Pack entitlement on the main actor.
    private func hasToolsPackEntitlement() async -> Bool {
        await MainActor.run { StoreService.shared.hasToolsPack }
    }

    func execute(toolCall: ParsedToolCall, agentType: String, threadID: String? = nil) async -> ToolExecutionResult {
        // 1. Rate Limiting
        if isRateLimited() {
            return .error(
                tool: toolCall.name,
                message: "Global tool rate limit exceeded. Please wait a moment.",
                errorType: "rate_limit",
                isRetryable: true
            )
        }
        
        // 2. Permission Check
        if !isToolAllowed(toolCall.name, for: agentType) {
            return .permissionDenied(
                tool: toolCall.name,
                message: "Tool '\(toolCall.name)' is not allowed for this agent type.",
                helpfulInstructions: "This agent is not configured to use this tool."
            )
        }
        
        // 3. Entitlement Check – shell, GitHub, Google Drive require Tools Pack
        #if !COMMUNITY_EDITION
        if requiresToolsPack(toolCall.name) {
            let entitled = await hasToolsPackEntitlement()
            if !entitled {
                return .error(
                    tool: toolCall.name,
                    message: "The '\(toolCall.name)' tool requires the Tools Pack upgrade. Go to Profile → Upgrade to unlock shell, GitHub, and Google Drive tools.",
                    errorType: "entitlement_required",
                    isRetryable: false
                )
            }
        }
        #endif
        
        // 3. Routing
        switch toolCall.name {
            
        // --- File Tools ---
        case "file.read":
            guard let path = extractString(from: toolCall.args, key: "path") else {
                return .validationError(tool: toolCall.name, message: "Missing required argument: 'path'")
            }
            return await fileService.readFile(path: path)
            
        case "file.write":
            guard let path = extractString(from: toolCall.args, key: "path"),
                  let content = extractString(from: toolCall.args, key: "content") else {
                return .validationError(tool: toolCall.name, message: "Missing required arguments: 'path' and 'content'")
            }
            return await fileService.writeFile(path: path, content: content)
            
        case "file.list":
            guard let path = extractString(from: toolCall.args, key: "path") else {
                return .validationError(tool: toolCall.name, message: "Missing required argument: 'path'")
            }
            let recursive = extractBool(from: toolCall.args, key: "recursive") ?? false
            return await fileService.listFiles(path: path, recursive: recursive)
            
        // --- Shell Tools ---
        case "shell.execute":
            guard let command = extractString(from: toolCall.args, key: "command") else {
                return .validationError(tool: toolCall.name, message: "Missing required argument: 'command'")
            }
            return await shellService.execute(command: command)
            
        // --- Web Tools ---
        case "web_search":
            // Route to existing ToolService but wrap in standard result
            guard let query = extractString(from: toolCall.args, key: "query") ?? extractString(from: toolCall.args, key: "input") else {
                return .validationError(tool: toolCall.name, message: "Missing 'query' argument")
            }
            
            // Heuristic: if query looks like a URL, use web_browse instead
            if let url = URL(string: query), url.scheme != nil, url.host != nil {
                return await executeWebBrowse(url: url, toolName: toolCall.name)
            }
            
            do {
                let results = try await toolService.webSearch(query: query, maxResults: 5)
                if results.isEmpty {
                     return .success(tool: toolCall.name, result: ["status": AnyJSONValue("no_results")], contextBlock: "[Web Search] No results found for '\(query)'")
                }
                
                let lines = results.enumerated().map { "\($0.offset + 1). \($0.element.title) - \($0.element.url)\n\($0.element.snippet)" }
                let block = "[Web Search Results for '\(query)']\n" + lines.joined(separator: "\n\n")
                
                return .success(tool: toolCall.name, result: ["count": AnyJSONValue(results.count)], contextBlock: block)
            } catch {
                return .error(tool: toolCall.name, message: error.localizedDescription)
            }
            
        case "web_browse":
            guard let urlString = extractString(from: toolCall.args, key: "url"),
                  let url = URL(string: urlString) else {
                return .validationError(tool: toolCall.name, message: "Missing or invalid 'url' argument")
            }
            return await executeWebBrowse(url: url, toolName: toolCall.name)
            
        case "current_time":
            var tz = TimeZone.current
            if let tzString = extractString(from: toolCall.args, key: "timezone"),
               let parsed = TimeZone(identifier: tzString) {
                tz = parsed
            }
            let info = toolService.currentTime(timezone: tz)
            let block = "[Current Time]\n\(info.localISO8601) (Zone: \(info.timezoneIdentifier))"
            return .success(tool: toolCall.name, result: ["iso8601": AnyJSONValue(info.localISO8601)], contextBlock: block)
            
        // --- GitHub Tools ---
        case "github.listRepos", "github.list_repos":
            return await executeGitHubListRepos(toolCall: toolCall)
            
        case "github.readFile", "github.read_file":
            return await executeGitHubReadFile(toolCall: toolCall)
            
        case "github.writeFile", "github.write_file":
            return await executeGitHubWriteFile(toolCall: toolCall)
            
        case "github.listFiles", "github.list_files":
            return await executeGitHubListFiles(toolCall: toolCall)
            
        case "github.createBranch", "github.create_branch":
            return await executeGitHubCreateBranch(toolCall: toolCall)
            
        case "github.createPR", "github.create_pr":
            return await executeGitHubCreatePR(toolCall: toolCall)
            
        case "github.searchCode", "github.search_code":
            return await executeGitHubSearchCode(toolCall: toolCall)
            
        case "github.getPR", "github.get_pr":
            return await executeGitHubGetPR(toolCall: toolCall)
            
        case "github.listPRFiles", "github.list_pr_files":
            return await executeGitHubListPRFiles(toolCall: toolCall)
            
        // --- Google Drive Tools ---
        case "google_drive.listFiles", "google_drive.list_files":
            return await executeGoogleDriveListFiles(toolCall: toolCall)
            
        case "google_drive.readFile", "google_drive.read_file":
            return await executeGoogleDriveReadFile(toolCall: toolCall)
            
        case "google_drive.uploadFile", "google_drive.upload_file":
            return await executeGoogleDriveUploadFile(toolCall: toolCall)
            
        case "google_sheets.readValues", "google_sheets.read_values":
            return await executeGoogleSheetsReadValues(toolCall: toolCall)
            
        case "google_sheets.writeValues", "google_sheets.write_values":
            return await executeGoogleSheetsWriteValues(toolCall: toolCall)

        default:
            return .error(
                tool: toolCall.name,
                message: "Unknown tool: \(toolCall.name)",
                errorType: "unknown_tool",
                isRetryable: false
            )
        }
    }
    
    // MARK: - GitHub Tool Implementations
    
    /// Execute github.listRepos
    private func executeGitHubListRepos(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected. Please connect GitHub in Settings > Connected Apps.")
        }
        
        do {
            let repos = try await githubService.listRepos(accountId: account.id)
            let repoNames = repos.compactMap { $0["full_name"] as? String }
            let block = "[GitHub Repos]\n" + repoNames.joined(separator: "\n")
            return .success(tool: toolCall.name, result: ["count": AnyJSONValue(repos.count)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute github.readFile
    private func executeGitHubReadFile(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected.")
        }
        
        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo"),
              let path = extractString(from: toolCall.args, key: "path") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo', 'path'")
        }
        
        let ref = extractString(from: toolCall.args, key: "ref")
        
        do {
            let content = try await githubService.readFile(
                accountId: account.id,
                owner: owner,
                repo: repo,
                path: path,
                ref: ref
            )
            let block = "[GitHub File: \(owner)/\(repo)/\(path)]\n\(content)"
            return .success(tool: toolCall.name, result: ["path": AnyJSONValue(path)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute github.writeFile
    private func executeGitHubWriteFile(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected.")
        }
        
        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo"),
              let path = extractString(from: toolCall.args, key: "path"),
              let content = extractString(from: toolCall.args, key: "content"),
              let message = extractString(from: toolCall.args, key: "message") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo', 'path', 'content', 'message'")
        }
        
        let branch = extractString(from: toolCall.args, key: "branch")
        let sha = extractString(from: toolCall.args, key: "sha")
        
        do {
            _ = try await githubService.writeFile(
                accountId: account.id,
                owner: owner,
                repo: repo,
                path: path,
                content: content,
                message: message,
                branch: branch,
                sha: sha
            )
            let block = "[GitHub File Written: \(owner)/\(repo)/\(path)]\nCommit message: \(message)"
            return .success(tool: toolCall.name, result: ["path": AnyJSONValue(path)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute github.listFiles
    private func executeGitHubListFiles(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected.")
        }
        
        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo'")
        }
        
        let path = extractString(from: toolCall.args, key: "path") ?? ""
        let ref = extractString(from: toolCall.args, key: "ref")
        
        do {
            let files = try await githubService.listFiles(
                accountId: account.id,
                owner: owner,
                repo: repo,
                path: path,
                ref: ref
            )
            let fileNames = files.compactMap { $0["name"] as? String }
            let block = "[GitHub Files: \(owner)/\(repo)/\(path)]\n" + fileNames.joined(separator: "\n")
            return .success(tool: toolCall.name, result: ["count": AnyJSONValue(files.count)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute github.createBranch
    private func executeGitHubCreateBranch(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected.")
        }
        
        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo"),
              let baseBranch = extractString(from: toolCall.args, key: "base_branch") ?? extractString(from: toolCall.args, key: "baseBranch"),
              let newBranch = extractString(from: toolCall.args, key: "new_branch") ?? extractString(from: toolCall.args, key: "newBranch") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo', 'base_branch', 'new_branch'")
        }
        
        do {
            let result = try await githubService.createBranch(
                accountId: account.id,
                owner: owner,
                repo: repo,
                baseBranch: baseBranch,
                newBranch: newBranch
            )
            let alreadyExisted = result["_branch_already_existed"] as? Bool ?? false
            let block = alreadyExisted
                ? "[GitHub Branch] Branch '\(newBranch)' already exists in \(owner)/\(repo)"
                : "[GitHub Branch Created] '\(newBranch)' from '\(baseBranch)' in \(owner)/\(repo)"
            return .success(tool: toolCall.name, result: ["branch": AnyJSONValue(newBranch)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute github.createPR
    private func executeGitHubCreatePR(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected.")
        }
        
        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo"),
              let title = extractString(from: toolCall.args, key: "title"),
              let head = extractString(from: toolCall.args, key: "head"),
              let base = extractString(from: toolCall.args, key: "base") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo', 'title', 'head', 'base'")
        }
        
        let body = extractString(from: toolCall.args, key: "body")
        
        do {
            let result = try await githubService.createPullRequest(
                accountId: account.id,
                owner: owner,
                repo: repo,
                title: title,
                head: head,
                base: base,
                body: body
            )
            let prNumber = result["number"] as? Int ?? 0
            let htmlUrl = result["html_url"] as? String ?? ""
            let block = "[GitHub PR Created] #\(prNumber): \(title)\n\(htmlUrl)"
            return .success(tool: toolCall.name, result: ["pr_number": AnyJSONValue(prNumber), "url": AnyJSONValue(htmlUrl)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute github.searchCode
    private func executeGitHubSearchCode(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected.")
        }
        
        guard let query = extractString(from: toolCall.args, key: "query") else {
            return .validationError(tool: toolCall.name, message: "Missing required argument: 'query'")
        }
        
        do {
            let result = try await githubService.searchCode(accountId: account.id, query: query)
            let items = result["items"] as? [[String: Any]] ?? []
            let paths = items.compactMap { $0["path"] as? String }
            let block = "[GitHub Code Search: \(query)]\n" + paths.prefix(20).joined(separator: "\n")
            return .success(tool: toolCall.name, result: ["total_count": AnyJSONValue(result["total_count"] as? Int ?? 0)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute github.getPR - fetch pull request details including title, body, state, and diff info
    private func executeGitHubGetPR(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected. Please connect GitHub in Settings > Connected Apps.")
        }
        
        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo'")
        }
        
        // Accept pull_number as int or string
        let pullNumber: Int
        if let num = toolCall.args["pull_number"]?.value as? Int {
            pullNumber = num
        } else if let numStr = extractString(from: toolCall.args, key: "pull_number"),
                  let num = Int(numStr) {
            pullNumber = num
        } else if let num = toolCall.args["number"]?.value as? Int {
            pullNumber = num
        } else if let numStr = extractString(from: toolCall.args, key: "number"),
                  let num = Int(numStr) {
            pullNumber = num
        } else {
            return .validationError(tool: toolCall.name, message: "Missing required argument: 'pull_number'")
        }
        
        do {
            let pr = try await githubService.getPullRequest(
                accountId: account.id,
                owner: owner,
                repo: repo,
                pullNumber: pullNumber
            )
            
            // Extract key PR details for context
            let title = pr["title"] as? String ?? "Untitled"
            let state = pr["state"] as? String ?? "unknown"
            let body = pr["body"] as? String ?? ""
            let htmlUrl = pr["html_url"] as? String ?? ""
            let headRef = (pr["head"] as? [String: Any])?["ref"] as? String ?? ""
            let baseRef = (pr["base"] as? [String: Any])?["ref"] as? String ?? ""
            let additions = pr["additions"] as? Int ?? 0
            let deletions = pr["deletions"] as? Int ?? 0
            let changedFiles = pr["changed_files"] as? Int ?? 0
            
            let block = """
            [GitHub PR #\(pullNumber): \(title)]
            State: \(state)
            Branch: \(headRef) → \(baseRef)
            Changes: +\(additions) -\(deletions) in \(changedFiles) files
            URL: \(htmlUrl)
            
            Description:
            \(body.isEmpty ? "(No description)" : body)
            """
            
            return .success(
                tool: toolCall.name,
                result: [
                    "number": AnyJSONValue(pullNumber),
                    "title": AnyJSONValue(title),
                    "state": AnyJSONValue(state),
                    "url": AnyJSONValue(htmlUrl)
                ],
                contextBlock: block
            )
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute github.listPRFiles - list files changed in a pull request with patches
    private func executeGitHubListPRFiles(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return .error(tool: toolCall.name, message: "GitHub not connected. Please connect GitHub in Settings > Connected Apps.")
        }
        
        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo'")
        }
        
        // Accept pull_number as int or string
        let pullNumber: Int
        if let num = toolCall.args["pull_number"]?.value as? Int {
            pullNumber = num
        } else if let numStr = extractString(from: toolCall.args, key: "pull_number"),
                  let num = Int(numStr) {
            pullNumber = num
        } else if let num = toolCall.args["number"]?.value as? Int {
            pullNumber = num
        } else if let numStr = extractString(from: toolCall.args, key: "number"),
                  let num = Int(numStr) {
            pullNumber = num
        } else {
            return .validationError(tool: toolCall.name, message: "Missing required argument: 'pull_number'")
        }
        
        do {
            let files = try await githubService.listPullRequestFiles(
                accountId: account.id,
                owner: owner,
                repo: repo,
                pullNumber: pullNumber
            )
            
            // Build a detailed view of changed files with patches
            var fileDetails: [String] = []
            for file in files {
                let filename = file["filename"] as? String ?? "unknown"
                let status = file["status"] as? String ?? "modified"
                let additions = file["additions"] as? Int ?? 0
                let deletions = file["deletions"] as? Int ?? 0
                let patch = file["patch"] as? String
                
                var detail = "\(status): \(filename) (+\(additions) -\(deletions))"
                if let patch = patch {
                    // Include patch but truncate if too long
                    let maxPatchLength = 2000
                    let truncatedPatch = patch.count > maxPatchLength
                        ? String(patch.prefix(maxPatchLength)) + "\n... (truncated)"
                        : patch
                    detail += "\n```diff\n\(truncatedPatch)\n```"
                }
                fileDetails.append(detail)
            }
            
            let block = "[GitHub PR #\(pullNumber) Files (\(files.count) changed)]\n\n" + fileDetails.joined(separator: "\n\n")
            
            return .success(
                tool: toolCall.name,
                result: ["count": AnyJSONValue(files.count)],
                contextBlock: block
            )
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    // MARK: - Google Drive Tool Implementations
    
    /// Execute google_drive.listFiles
    private func executeGoogleDriveListFiles(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return .error(tool: toolCall.name, message: "Google Drive not connected. Please connect in Settings > Connected Apps.")
        }
        
        let query = extractString(from: toolCall.args, key: "query")
        
        do {
            let response = try await googleDriveService.listFiles(accountId: account.id, query: query)
            let fileNames = response.files.map { "\($0.name) (\($0.mimeType ?? "unknown"))" }
            let block = "[Google Drive Files]\n" + fileNames.joined(separator: "\n")
            return .success(tool: toolCall.name, result: ["count": AnyJSONValue(response.files.count)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute google_drive.readFile
    private func executeGoogleDriveReadFile(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return .error(tool: toolCall.name, message: "Google Drive not connected.")
        }
        
        guard let fileId = extractString(from: toolCall.args, key: "file_id") ?? extractString(from: toolCall.args, key: "fileId") else {
            return .validationError(tool: toolCall.name, message: "Missing required argument: 'file_id'")
        }
        
        let exportMimeType = extractString(from: toolCall.args, key: "export_mime_type") ?? "text/plain"
        
        do {
            let data = try await googleDriveService.downloadFile(
                accountId: account.id,
                fileId: fileId,
                exportMimeType: exportMimeType
            )
            let content = String(data: data, encoding: .utf8) ?? "<binary content>"
            let block = "[Google Drive File: \(fileId)]\n\(content.prefix(5000))"
            return .success(tool: toolCall.name, result: ["file_id": AnyJSONValue(fileId)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute google_drive.uploadFile
    private func executeGoogleDriveUploadFile(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return .error(tool: toolCall.name, message: "Google Drive not connected.")
        }
        
        guard let name = extractString(from: toolCall.args, key: "name"),
              let content = extractString(from: toolCall.args, key: "content") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'name', 'content'")
        }
        
        let mimeType = extractString(from: toolCall.args, key: "mime_type") ?? "text/plain"
        
        do {
            let file = try await googleDriveService.uploadFile(
                accountId: account.id,
                name: name,
                mimeType: mimeType,
                content: content.data(using: .utf8) ?? Data()
            )
            let block = "[Google Drive File Uploaded]\nName: \(file.name)\nID: \(file.id)"
            return .success(tool: toolCall.name, result: ["file_id": AnyJSONValue(file.id)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute google_sheets.readValues
    private func executeGoogleSheetsReadValues(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return .error(tool: toolCall.name, message: "Google Drive not connected.")
        }
        
        guard let spreadsheetId = extractString(from: toolCall.args, key: "spreadsheet_id") ?? extractString(from: toolCall.args, key: "spreadsheetId"),
              let range = extractString(from: toolCall.args, key: "range") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'spreadsheet_id', 'range'")
        }
        
        do {
            let values = try await googleDriveService.readSpreadsheetValues(
                accountId: account.id,
                spreadsheetId: spreadsheetId,
                range: range
            )
            let formatted = values.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            let block = "[Google Sheets: \(range)]\n\(formatted)"
            return .success(tool: toolCall.name, result: ["row_count": AnyJSONValue(values.count)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    /// Execute google_sheets.writeValues
    private func executeGoogleSheetsWriteValues(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return .error(tool: toolCall.name, message: "Google Drive not connected.")
        }
        
        guard let spreadsheetId = extractString(from: toolCall.args, key: "spreadsheet_id") ?? extractString(from: toolCall.args, key: "spreadsheetId"),
              let range = extractString(from: toolCall.args, key: "range") else {
            return .validationError(tool: toolCall.name, message: "Missing required arguments: 'spreadsheet_id', 'range'")
        }
        
        // Parse values from args - expecting array of arrays
        guard let valuesArg = toolCall.args["values"]?.value as? [[Any]] else {
            return .validationError(tool: toolCall.name, message: "Missing or invalid 'values' argument (expected array of arrays)")
        }
        
        let values = valuesArg.map { row in row.map { String(describing: $0) } }
        
        do {
            _ = try await googleDriveService.writeSpreadsheetValues(
                accountId: account.id,
                spreadsheetId: spreadsheetId,
                range: range,
                values: values
            )
            let block = "[Google Sheets Updated: \(range)]\nWrote \(values.count) rows"
            return .success(tool: toolCall.name, result: ["updated_rows": AnyJSONValue(values.count)], contextBlock: block)
        } catch {
            return .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }
    
    // MARK: - Configuration Methods
    
    func setWhitelist(for agentType: String, tools: Set<String>) {
        toolWhitelist[agentType] = tools
    }
    
    // MARK: - Web Tool Implementations
    
    private func executeWebBrowse(url: URL, toolName: String) async -> ToolExecutionResult {
        do {
            let result = try await toolService.webBrowse(url: url)
            let block = "[Web Browse: \(result.title ?? "No Title")]\nURL: \(result.url.absoluteString)\n\n\(result.content)"
            return .success(
                tool: toolName,
                result: [
                    "url": AnyJSONValue(result.url.absoluteString),
                    "length": AnyJSONValue(result.contentLength),
                    "title": AnyJSONValue(result.title ?? "")
                ],
                contextBlock: block
            )
        } catch {
            return .error(tool: toolName, message: error.localizedDescription)
        }
    }

    // MARK: - Private Helpers
    
    private func isRateLimited() -> Bool {
        let now = Date()
        // Clean old logs (older than 1 minute)
        callLog = callLog.filter { now.timeIntervalSince($0) < 60 }
        
        if callLog.count >= globalRateLimit {
            return true
        }
        
        callLog.append(now)
        return false
    }
    
    private func isToolAllowed(_ toolName: String, for agentType: String) -> Bool {
        // If no whitelist exists for this agent, deny all (deny-by-default security)
        // Or change to allow-all if that fits the policy. For now, let's assume if key missing, allow common tools? 
        // Better: require explicit configuration.
        
        // For Coven agents, we might not have set whitelists yet. 
        // Let's implement a fallback allow-list for basic tools.
        let defaultTools: Set<String> = ["current_time"]
        
        if let allowed = toolWhitelist[agentType] {
            return allowed.contains(toolName)
        }
        
        // Fallback: allow common tools if no specific profile set
        // TODO: In production, switch to strict deny-by-default
        return true 
    }
    
    // Helper to extract typed values from JSON args
    private func extractString(from args: [String: AnyJSONValue], key: String) -> String? {
        if let val = args[key]?.value as? String { return val }
        return nil
    }
    
    private func extractBool(from args: [String: AnyJSONValue], key: String) -> Bool? {
        if let val = args[key]?.value as? Bool { return val }
        return nil
    }
}
