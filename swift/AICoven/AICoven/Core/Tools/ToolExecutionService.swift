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

    /// Asks the person before a tool changes something, and waits for the
    /// answer.
    private let ask: @Sendable (ToolApproval) async -> ApprovalAnswer

    /// Default initializer uses the shared ToolService singleton.
    init() {
        toolService = ToolService.shared
        ask = Self.askInItsThread
    }

    /// Test-friendly initializer that accepts a mock tool service, and an
    /// answer to every approval in place of the person's.
    init(toolService: any ChatToolService, ask: @escaping @Sendable (ToolApproval) async -> ApprovalAnswer = { _ in .denied }) {
        self.toolService = toolService
        self.ask = ask
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

    // MARK: - Image generation

    /// What `image.generate` was asked for, or why it cannot be made.
    struct ImageRequest: Equatable {
        let prompt: String
        let model: String?
        let size: String
        let quality: String?
    }

    /// Reads a call's arguments: a prompt that says something, OpenAI as
    /// the provider if one is named, and a size that reads as one.
    nonisolated static func imageRequest(from args: [String: AnyJSONValue]) -> Result<ImageRequest, ImageRequestRefusal> {
        func text(_ key: String) -> String? {
            let value = (args[key]?.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        guard let prompt = text("prompt") else {
            return .failure(ImageRequestRefusal(message: "Missing required argument: 'prompt'", field: "prompt"))
        }
        if let provider = text("provider"), provider.lowercased() != "openai" {
            return .failure(ImageRequestRefusal(message: "Images are made with OpenAI in this app; '\(provider)' is not available. Leave 'provider' out.", field: "provider"))
        }
        // A size that was given must read as one: only one left out (or
        // given as null, as models write what they leave out) is the
        // default.
        let size: String
        if let given = args["size"], !(given.value is NSNull) {
            guard let asked = given.value as? String, ImageGenerationService.isSize(asked) else {
                return .failure(ImageRequestRefusal(message: "'size' must be width x height in pixels, like '1024x1024'.", field: "size"))
            }
            size = asked
        } else {
            size = ImageGenerationService.defaultSize
        }
        return .success(ImageRequest(prompt: prompt, model: text("model"), size: size, quality: text("quality")))
    }

    struct ImageRequestRefusal: Error, Equatable {
        let message: String
        let field: String
    }

    /// What the model is told of a picture that was made: that the person
    /// has it, not where it is.
    nonisolated static func imageContextBlock(for made: ImageGenerationService.Generated) -> String {
        var lines = ["[Generated image]", "An image was made with \(made.model) (\(made.size)) and is shown to the user in the app, with your reply. Do not write a link or a file name for it."]
        if let revised = made.revisedPrompt, !revised.isEmpty {
            lines.append("Prompt as the model revised it: \(revised)")
        }
        return lines.joined(separator: "\n")
    }

    /// Makes the picture with the person's OpenAI key and keeps it in the
    /// attachment store for the thread; the turn gives it to its reply.
    private func generateImage(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        let request: ImageRequest
        switch Self.imageRequest(from: toolCall.args) {
        case let .success(asked): request = asked
        case let .failure(refusal): return .validationError(tool: toolCall.name, message: refusal.message, field: refusal.field)
        }
        guard let threadID else {
            return .error(tool: toolCall.name, message: "An image can be made only in a thread.", errorType: "image_needs_a_thread")
        }
        // The key is the signed-in account's. A turn can outlive the
        // account it was started as, so the thread must be that account's
        // before anything is asked with its key. The account and its key
        // are read together, with nothing between them, so the key is
        // that account's whatever is signed in a moment later.
        let keyed = imageService
        let (account, service) = await MainActor.run { (UserScope.currentUserID, keyed()) }
        let isTheAccounts: Bool
        do {
            isTheAccounts = try await ThreadRepository.shared.isThread(threadID, of: account)
        } catch {
            let failure = error as NSError
            AppErrorReporter.log(message: "A thread's account could not be read (\(failure.domain) \(failure.code)).", context: "ToolExecutionService.generateImage")
            return .error(tool: toolCall.name, message: "The thread could not be read: no image was made.", errorType: "image_thread_unreadable", isRetryable: true)
        }
        guard isTheAccounts else {
            return .error(tool: toolCall.name, message: "This thread is not the signed-in account's: no image was made.", errorType: "image_account_changed")
        }
        guard let service else {
            return .error(
                tool: toolCall.name,
                message: "Image generation needs an OpenAI connection with a key.",
                errorType: "image_provider_key_required",
                helpfulInstructions: "Add an OpenAI connection in Settings to make images."
            )
        }
        let made: ImageGenerationService.Generated
        do {
            made = try await service.generate(prompt: request.prompt, model: request.model, size: request.size, quality: request.quality)
        } catch is CancellationError {
            return .error(tool: toolCall.name, message: "Stopped before the image was made.", errorType: "cancelled")
        } catch let failure as ImageGenerationService.Failure {
            return .error(tool: toolCall.name, message: failure.errorDescription ?? "The image could not be made.", errorType: "image_generation_failed", isRetryable: failure != .keyRefused)
        } catch {
            let failure = error as NSError
            AppErrorReporter.log(message: "An image could not be made (\(failure.domain) \(failure.code)).", context: "ToolExecutionService.generateImage")
            return .error(tool: toolCall.name, message: "The image could not be made: OpenAI could not be reached.", errorType: "image_generation_failed", isRetryable: true)
        }
        do {
            let kept = try await AttachmentStore.shared.add(made.data, named: Self.generatedImageName, mimeType: made.mimeType, toThread: threadID)
            return .success(
                tool: toolCall.name,
                result: [Self.generatedFilesKey: .array([kept.messageMetadata]), "provider": .string("openai"), "model": .string(made.model), "size": .string(made.size)],
                contextBlock: Self.imageContextBlock(for: made)
            )
        } catch {
            // Made, but not kept on this device, whatever stopped it (the
            // data locked, the account changed, the disk): there is
            // nothing to show.
            let failure = error as NSError
            AppErrorReporter.log(message: "A generated image could not be kept (\(failure.domain) \(failure.code)).", context: "ToolExecutionService.generateImage")
            return .error(tool: toolCall.name, message: "The image was made but could not be kept on this device.", errorType: "image_persistence_failed")
        }
    }

    /// What a generated image is called; the store adds the kind it keeps.
    nonisolated static let generatedImageName = "Generated image.png"

    /// Where a tool's result lists the files it made for the person, each
    /// as a message keeps an attachment.
    nonisolated static let generatedFilesKey = "generated_attachments"

    /// The files a tool's result says it made for the person.
    nonisolated static func generatedFiles(in result: ToolExecutionResult) -> [FileAttachmentDetail] {
        guard result.status == "ok", case let .array(entries)? = result.result?[generatedFilesKey] else { return [] }
        return entries.compactMap(FileAttachmentDetail.init(messageMetadata:))
    }

    /// The service a picture is asked of, with the person's OpenAI key;
    /// nil where there is no key. Tests give one that answers from a script.
    nonisolated static let imageServiceWithTheStoredKey: @Sendable () -> ImageGenerationService? = {
        guard let key = ProviderAccountService.apiKeyFromKeychain(forProvider: "openai"), !key.isEmpty else { return nil }
        return ImageGenerationService(apiKey: key)
    }

    private var imageService = imageServiceWithTheStoredKey

    func setImageService(_ make: @escaping @Sendable () -> ImageGenerationService?) {
        imageService = make
    }

    // MARK: - Execution

    func execute(toolCall: ParsedToolCall, agentType: String, threadID: String? = nil) async -> ToolExecutionResult {
        // 1. Rate Limiting
        if isRateLimited() {
            return await .error(
                tool: toolCall.name,
                message: "Global tool rate limit exceeded. Please wait a moment.",
                errorType: "rate_limit",
                isRetryable: true
            )
        }

        // 2. Permission Check
        if !isToolAllowed(toolCall.name, for: agentType) {
            return await .permissionDenied(
                tool: toolCall.name,
                message: "Tool '\(toolCall.name)' is not allowed for this agent type.",
                helpfulInstructions: "This agent is not configured to use this tool."
            )
        }

        // 3. Entitlement Check – shell, GitHub, Google Drive require Tools Pack
        if requiresToolsPack(toolCall.name) {
            let entitled = await hasToolsPackEntitlement()
            if !entitled {
                return await .error(
                    tool: toolCall.name,
                    message: "The '\(toolCall.name)' tool requires the Tools Pack upgrade. Go to Profile → Upgrade to unlock shell, GitHub, and Google Drive tools.",
                    errorType: "entitlement_required",
                    isRetryable: false
                )
            }
        }

        // 4. MCP Toll Routing
        if toolCall.name.hasPrefix("mcp.") {
            return await executeMCPTool(toolCall: toolCall)
        }

        // 5. Built-in Routing
        switch toolCall.name {

        // --- File Tools ---
        case "file.read":
            guard let path = extractString(from: toolCall.args, key: "path") else {
                return await .validationError(tool: toolCall.name, message: "Missing required argument: 'path'")
            }
            return await fileService.readFile(path: path)

        case "file.write":
            guard let path = extractString(from: toolCall.args, key: "path"),
                  let content = extractString(from: toolCall.args, key: "content") else {
                return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'path' and 'content'")
            }
            return await fileService.writeFile(path: path, content: content) { resolvedPath, replaces in
                await self.answer(in: threadID) { .fileWrite(path: resolvedPath, content: content, replaces: replaces, threadID: $0) }
            }

        case "file.list":
            guard let path = extractString(from: toolCall.args, key: "path") else {
                return .validationError(tool: toolCall.name, message: "Missing required argument: 'path'")
            }
            let recursive = extractBool(from: toolCall.args, key: "recursive") ?? false
            return await fileService.listFiles(path: path, recursive: recursive)

        // --- Shell Tools ---
        case "shell.execute":
            guard let command = extractString(from: toolCall.args, key: "command") else {
                return await .validationError(tool: toolCall.name, message: "Missing required argument: 'command'")
            }
            return await shellService.execute(command: command) { command, directory in
                await self.answer(in: threadID) { .shell(command: command, directory: directory, threadID: $0) }
            }

        // --- Image generation ---
        case "image.generate":
            return await generateImage(toolCall: toolCall, threadID: threadID)

        // --- Web Tools ---
        case "web_search":
            // Route to existing ToolService but wrap in standard result
            guard let query = extractString(from: toolCall.args, key: "query") ?? extractString(from: toolCall.args, key: "input") else {
                return await .validationError(tool: toolCall.name, message: "Missing 'query' argument")
            }

            // Heuristic: if query looks like a URL, use web_browse instead
            if let url = URL(string: query), url.scheme != nil, url.host != nil {
                return await executeWebBrowse(url: url, toolName: toolCall.name)
            }

            do {
                // Use the injected toolService to enable mocking in tests.
                let results = try await toolService.webSearch(query: query, maxResults: 5)
                if results.isEmpty {
                    return await .success(tool: toolCall.name, result: ["status": AnyJSONValue("no_results")], contextBlock: "[Web Search] No results found for '\(query)'")
                }

                let lines = results.enumerated().map { "\($0.offset + 1). \($0.element.title) - \($0.element.url)\n\($0.element.snippet)" }
                let block = "[Web Search Results for '\(query)']\n" + lines.joined(separator: "\n\n")

                return await .success(tool: toolCall.name, result: ["count": AnyJSONValue(results.count)], contextBlock: block)
            } catch let error as NSError {
                // Provide more detailed error info for debugging iOS issues
                let message = "Web search failed: \(error.localizedDescription) (domain: \(error.domain), code: \(error.code))"
                return await .error(tool: toolCall.name, message: message)
            } catch {
                return await .error(tool: toolCall.name, message: "Web search failed: \(error.localizedDescription)")
            }

        case "web_browse":
            guard let urlString = extractString(from: toolCall.args, key: "url"),
                  let url = URL(string: urlString) else {
                return await .validationError(tool: toolCall.name, message: "Missing or invalid 'url' argument")
            }
            return await executeWebBrowse(url: url, toolName: toolCall.name)

        case "current_time":
            // Inline implementation to avoid toolService dependency and potential
            // iOS initialization issues. This is pure computation with no side effects.
            var tz = TimeZone.current
            if let tzString = extractString(from: toolCall.args, key: "timezone"),
               let parsed = TimeZone(identifier: tzString) {
                tz = parsed
            }
            let now = Date()
            let localFormatter = ISO8601DateFormatter()
            localFormatter.timeZone = tz
            let localISO8601 = localFormatter.string(from: now)

            // Build a human-readable format so small models (2B-4B) don't
            // need to parse ISO8601 or do timezone math.
            let readableFmt = DateFormatter()
            readableFmt.locale = Locale(identifier: "en_US_POSIX")
            readableFmt.calendar = Calendar(identifier: .gregorian)
            readableFmt.timeZone = tz
            readableFmt.dateFormat = "h:mm a, EEEE MMMM d, yyyy"
            let readableTime = readableFmt.string(from: now)

            let gmtOffset = tz.secondsFromGMT(for: now)
            let gmtHours = gmtOffset / 3600
            let gmtMins = abs(gmtOffset % 3600) / 60
            let gmtLabel = gmtMins == 0
                ? String(format: "GMT%+d", gmtHours)
                : String(format: "GMT%+d:%02d", gmtHours, gmtMins)

            let block = """
            [Current Time]
            Timezone: \(tz.identifier) (\(gmtLabel))
            Local time: \(readableTime)
            ISO8601: \(localISO8601)
            """
            return await .success(tool: toolCall.name, result: ["iso8601": AnyJSONValue(localISO8601)], contextBlock: block)

        // --- GitHub Tools ---
        case "github.listRepos", "github.list_repos":
            return await executeGitHubListRepos(toolCall: toolCall)

        case "github.readFile", "github.read_file":
            return await executeGitHubReadFile(toolCall: toolCall)

        case "github.writeFile", "github.write_file":
            return await executeGitHubWriteFile(toolCall: toolCall, threadID: threadID)

        case "github.listFiles", "github.list_files":
            return await executeGitHubListFiles(toolCall: toolCall)

        case "github.createBranch", "github.create_branch":
            return await executeGitHubCreateBranch(toolCall: toolCall, threadID: threadID)

        case "github.createPR", "github.create_pr":
            return await executeGitHubCreatePR(toolCall: toolCall, threadID: threadID)

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
            return await executeGoogleDriveUploadFile(toolCall: toolCall, threadID: threadID)

        case "google_sheets.readValues", "google_sheets.read_values":
            return await executeGoogleSheetsReadValues(toolCall: toolCall)

        case "google_sheets.writeValues", "google_sheets.write_values":
            return await executeGoogleSheetsWriteValues(toolCall: toolCall, threadID: threadID)

        default:
            return await .error(
                tool: toolCall.name,
                message: "Unknown tool: \(toolCall.name)",
                errorType: "unknown_tool",
                isRetryable: false
            )
        }
    }

    // MARK: - MCP Tool Implementations

    private func executeMCPTool(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        // e.g. "mcp.my_server.tool_name"
        let parts = toolCall.name.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else {
            return await .validationError(tool: toolCall.name, message: "Invalid MCP tool name format")
        }

        let serverSlug = String(parts[1])
        let actionName = String(parts[2])

        // Find matching server
        let servers = await connectedAccountsService.getAllMCPServers()
        let matchingServer = servers.first { server in
            let slug = server.name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return slug == serverSlug
        }

        guard let server = matchingServer else {
            return await .error(tool: toolCall.name, message: "MCP server '\(serverSlug)' not found or not connected.")
        }

        // Fetch the stored auth token (Bearer/API key) from keychain so
        // runtime tool calls use the same auth path as MCP connection tests.
        let token = try? await connectedAccountsService.getMCPToken(forServerId: server.id)
        let client = MCPClient(server: server, token: token)

        do {
            let items = try await client.callTool(name: actionName, arguments: toolCall.args)
            let texts = items.compactMap(\.text)
            let block = "[MCP: \(actionName) on \(server.name)]\n" + texts.joined(separator: "\n\n")

            return await .success(
                tool: toolCall.name,
                result: ["status": AnyJSONValue("success"), "item_count": AnyJSONValue(items.count)],
                contextBlock: block
            )
        } catch {
            return await .error(tool: toolCall.name, message: "MCP Server Error: \(error.localizedDescription)")
        }
    }

    // MARK: - GitHub Tool Implementations

    /// Execute github.listRepos
    private func executeGitHubListRepos(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected. Please connect GitHub in Settings > \(SettingsPane.connectedApps.listedTitle).")
        }

        do {
            let repos = try await githubService.listRepos(accountId: account.id)
            let repoNames = repos.compactMap { $0["full_name"] as? String }
            let block = "[GitHub Repos]\n" + repoNames.joined(separator: "\n")
            return await .success(tool: toolCall.name, result: ["count": AnyJSONValue(repos.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.readFile
    private func executeGitHubReadFile(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo"),
              let path = extractString(from: toolCall.args, key: "path") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo', 'path'")
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
            return await .success(tool: toolCall.name, result: ["path": AnyJSONValue(path)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.writeFile
    private func executeGitHubWriteFile(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo"),
              let path = extractString(from: toolCall.args, key: "path"),
              let content = extractString(from: toolCall.args, key: "content"),
              let message = extractString(from: toolCall.args, key: "message") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo', 'path', 'content', 'message'")
        }

        let branch = extractString(from: toolCall.args, key: "branch")
        let sha = extractString(from: toolCall.args, key: "sha")

        if let refusal = await ToolExecutionResult.refusal(answer(in: threadID) { .gitHubWriteFile(owner: owner, repo: repo, path: path, branch: branch, message: message, content: content, threadID: $0) }, tool: toolCall.name) {
            return refusal
        }

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
            return await .success(tool: toolCall.name, result: ["path": AnyJSONValue(path)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.listFiles
    private func executeGitHubListFiles(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo'")
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
            return await .success(tool: toolCall.name, result: ["count": AnyJSONValue(files.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.createBranch
    private func executeGitHubCreateBranch(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo"),
              let baseBranch = extractString(from: toolCall.args, key: "base_branch") ?? extractString(from: toolCall.args, key: "baseBranch"),
              let newBranch = extractString(from: toolCall.args, key: "new_branch") ?? extractString(from: toolCall.args, key: "newBranch") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo', 'base_branch', 'new_branch'")
        }

        if let refusal = await ToolExecutionResult.refusal(answer(in: threadID) { .gitHubCreateBranch(owner: owner, repo: repo, newBranch: newBranch, baseBranch: baseBranch, threadID: $0) }, tool: toolCall.name) {
            return refusal
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
            return await .success(tool: toolCall.name, result: ["branch": AnyJSONValue(newBranch)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.createPR
    private func executeGitHubCreatePR(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo"),
              let title = extractString(from: toolCall.args, key: "title"),
              let head = extractString(from: toolCall.args, key: "head"),
              let base = extractString(from: toolCall.args, key: "base") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo', 'title', 'head', 'base'")
        }

        let body = extractString(from: toolCall.args, key: "body")

        if let refusal = await ToolExecutionResult.refusal(answer(in: threadID) { .gitHubCreatePR(owner: owner, repo: repo, title: title, head: head, base: base, body: body, threadID: $0) }, tool: toolCall.name) {
            return refusal
        }

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
            return await .success(tool: toolCall.name, result: ["pr_number": AnyJSONValue(prNumber), "url": AnyJSONValue(htmlUrl)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.searchCode
    private func executeGitHubSearchCode(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let query = extractString(from: toolCall.args, key: "query") else {
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'query'")
        }

        do {
            let result = try await githubService.searchCode(accountId: account.id, query: query)
            let items = result["items"] as? [[String: Any]] ?? []
            let paths = items.compactMap { $0["path"] as? String }
            let block = "[GitHub Code Search: \(query)]\n" + paths.prefix(20).joined(separator: "\n")
            return await .success(tool: toolCall.name, result: ["total_count": AnyJSONValue(result["total_count"] as? Int ?? 0)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.getPR - fetch pull request details including title, body, state, and diff info
    private func executeGitHubGetPR(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected. Please connect GitHub in Settings > \(SettingsPane.connectedApps.listedTitle).")
        }

        guard let owner = extractString(from: toolCall.args, key: "owner"),
              let repo = extractString(from: toolCall.args, key: "repo") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'owner', 'repo'")
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
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'pull_number'")
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

            return await .success(
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
            return await .error(tool: toolCall.name, message: "GitHub not connected. Please connect GitHub in Settings > \(SettingsPane.connectedApps.listedTitle).")
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
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'pull_number'")
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
                if let patch {
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

            return await .success(
                tool: toolCall.name,
                result: ["count": AnyJSONValue(files.count)],
                contextBlock: block
            )
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    // MARK: - Google Drive Tool Implementations

    /// Execute google_drive.listFiles
    private func executeGoogleDriveListFiles(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return .error(tool: toolCall.name, message: "Google Drive not connected. Please connect in Settings > \(SettingsPane.connectedApps.listedTitle).")
        }

        let query = extractString(from: toolCall.args, key: "query")

        do {
            let response = try await googleDriveService.listFiles(accountId: account.id, query: query)
            let fileNames = response.files.map { "\($0.name) (\($0.mimeType ?? "unknown"))" }
            let block = "[Google Drive Files]\n" + fileNames.joined(separator: "\n")
            return await .success(tool: toolCall.name, result: ["count": AnyJSONValue(response.files.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_drive.readFile
    private func executeGoogleDriveReadFile(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let fileId = extractString(from: toolCall.args, key: "file_id") ?? extractString(from: toolCall.args, key: "fileId") else {
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'file_id'")
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
            return await .success(tool: toolCall.name, result: ["file_id": AnyJSONValue(fileId)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_drive.uploadFile
    private func executeGoogleDriveUploadFile(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let name = extractString(from: toolCall.args, key: "name"),
              let content = extractString(from: toolCall.args, key: "content") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'name', 'content'")
        }

        let mimeType = extractString(from: toolCall.args, key: "mime_type") ?? "text/plain"

        if let refusal = await ToolExecutionResult.refusal(answer(in: threadID) { .driveUpload(name: name, mimeType: mimeType, content: content, threadID: $0) }, tool: toolCall.name) {
            return refusal
        }

        do {
            let file = try await googleDriveService.uploadFile(
                accountId: account.id,
                name: name,
                mimeType: mimeType,
                content: content.data(using: .utf8) ?? Data()
            )
            let block = "[Google Drive File Uploaded]\nName: \(file.name)\nID: \(file.id)"
            return await .success(tool: toolCall.name, result: ["file_id": AnyJSONValue(file.id)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_sheets.readValues
    private func executeGoogleSheetsReadValues(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let spreadsheetId = extractString(from: toolCall.args, key: "spreadsheet_id") ?? extractString(from: toolCall.args, key: "spreadsheetId"),
              let range = extractString(from: toolCall.args, key: "range") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'spreadsheet_id', 'range'")
        }

        do {
            let values = try await googleDriveService.readSpreadsheetValues(
                accountId: account.id,
                spreadsheetId: spreadsheetId,
                range: range
            )
            let formatted = values.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            let block = "[Google Sheets: \(range)]\n\(formatted)"
            return await .success(tool: toolCall.name, result: ["row_count": AnyJSONValue(values.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_sheets.writeValues
    private func executeGoogleSheetsWriteValues(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let spreadsheetId = extractString(from: toolCall.args, key: "spreadsheet_id") ?? extractString(from: toolCall.args, key: "spreadsheetId"),
              let range = extractString(from: toolCall.args, key: "range") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'spreadsheet_id', 'range'")
        }

        // Parse values from args - expecting array of arrays
        guard let valuesArg = toolCall.args["values"]?.value as? [[Any]] else {
            return await .validationError(tool: toolCall.name, message: "Missing or invalid 'values' argument (expected array of arrays)")
        }

        let values = valuesArg.map { row in row.map { String(describing: $0) } }

        if let refusal = await ToolExecutionResult.refusal(answer(in: threadID) { .sheetsWrite(spreadsheetID: spreadsheetId, range: range, values: values, threadID: $0) }, tool: toolCall.name) {
            return refusal
        }

        do {
            _ = try await googleDriveService.writeSpreadsheetValues(
                accountId: account.id,
                spreadsheetId: spreadsheetId,
                range: range,
                values: values
            )
            let block = "[Google Sheets Updated: \(range)]\nWrote \(values.count) rows"
            return await .success(tool: toolCall.name, result: ["updated_rows": AnyJSONValue(values.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    // MARK: - Approvals

    /// Asks the person, in the thread the tool call came from, about what
    /// `describe` says is about to happen, and waits for the answer. Without
    /// a thread there is nowhere to ask and no one to answer.
    private func answer(in threadID: String?, _ describe: @Sendable (_ threadID: String) -> ToolApproval) async -> ApprovalAnswer {
        guard let threadID else { return .notAsked }
        return await ask(describe(threadID))
    }

    /// Asks in the app's approval spot, naming the thread that asked and
    /// where it lives. An approval that cannot say which thread it is from
    /// (the thread has been deleted, its coven is gone, or either could not
    /// be read) is not asked: the person would be answering for somewhere
    /// else. Why is logged.
    static func askInItsThread(_ approval: ToolApproval) async -> ApprovalAnswer {
        var approval = approval
        do {
            let thread = try await ThreadService.shared.getThread(threadId: approval.threadID)
            approval.threadTitle = thread.title ?? approval.threadTitle
            if let covenID = thread.covenId {
                guard let coven = try await CovenService.shared.loadCovens().first(where: { $0.id == covenID }) else {
                    AppErrorReporter.log(message: "An approval's coven was not found", context: "ToolExecutionService.askInItsThread")
                    return .notAsked
                }
                approval.covenName = coven.name
            }
        } catch {
            AppErrorReporter.log(error: error, context: "ToolExecutionService.askInItsThread")
            return .notAsked
        }
        return await ToolApprovals.shared.ask(approval)
    }

    // MARK: - Configuration Methods

    func setWhitelist(for agentType: String, tools: Set<String>) {
        toolWhitelist[agentType] = tools
    }

    // MARK: - Web Tool Implementations

    private func executeWebBrowse(url: URL, toolName: String) async -> ToolExecutionResult {
        do {
            // Use ToolService.shared directly to avoid iOS initialization issues
            let result = try await ToolService.shared.webBrowse(url: url)
            let block = "[Web Browse: \(result.title ?? "No Title")]\nURL: \(result.url.absoluteString)\n\n\(result.content)"
            return await .success(
                tool: toolName,
                result: [
                    "url": AnyJSONValue(result.url.absoluteString),
                    "length": AnyJSONValue(result.contentLength),
                    "title": AnyJSONValue(result.title ?? "")
                ],
                contextBlock: block
            )
        } catch let error as NSError {
            // Provide more detailed error info for debugging iOS issues
            let message = "Web browse failed: \(error.localizedDescription) (domain: \(error.domain), code: \(error.code))"
            return .error(tool: toolName, message: message)
        } catch {
            return await .error(tool: toolName, message: "Web browse failed: \(error.localizedDescription)")
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
        if let allowed = toolWhitelist[agentType] {
            return allowed.contains(toolName)
        }

        // Missing whitelist means no tool is allowed (deny by default).
        return false
    }

    /// Helper to extract typed values from JSON args
    private func extractString(from args: [String: AnyJSONValue], key: String) -> String? {
        if let val = args[key]?.value as? String { return val }
        return nil
    }

    private func extractBool(from args: [String: AnyJSONValue], key: String) -> Bool? {
        if let val = args[key]?.value as? Bool { return val }
        return nil
    }
}
