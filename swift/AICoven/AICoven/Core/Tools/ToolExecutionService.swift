import Foundation

/// Central dispatcher for all tool execution in the agent system.
/// Handles permission checking, rate limiting, and routing to specific tool services.
actor ToolExecutionService {

    static let shared = ToolExecutionService()

    // Dependencies
    private let fileService = FileToolService.shared
    private let shellService = ShellToolService.shared
    private let toolService: any ChatToolService
    private let githubService: GitHubToolService
    private let googleDriveService: GoogleDriveToolService
    private let connectedAccountsService: ConnectedAccountsService

    /// Whether the person has the Tools Pack.
    private let hasToolsPack: @Sendable () async -> Bool

    /// Asks the person before a tool changes something, and waits for the
    /// answer.
    private let ask: @Sendable (ToolApproval) async -> ApprovalAnswer

    /// Which connections the coven of a thread lets its agents use.
    private let covenConnections: @Sendable (_ threadID: String) async -> CovenConnections?

    /// Default initializer uses the shared ToolService singleton.
    init() {
        toolService = ToolService.shared
        ask = Self.askInItsThread
        covenConnections = { await CovenService.shared.connections(forThread: $0) }
        githubService = .shared
        googleDriveService = .shared
        connectedAccountsService = .shared
        hasToolsPack = Self.hasBoughtTheToolsPack
    }

    /// Test-friendly initializer that accepts a mock tool service, an
    /// answer to every approval in place of the person's, and a coven's
    /// choice of connections in place of the thread's (none made, unless
    /// given). It can also be given its own connected accounts, GitHub
    /// and Google services that ask a scripted server, and whether the
    /// Tools Pack was bought.
    init(
        toolService: any ChatToolService,
        ask: @escaping @Sendable (ToolApproval) async -> ApprovalAnswer = { _ in .denied },
        covenConnections: @escaping @Sendable (_ threadID: String) async -> CovenConnections? = { _ in nil },
        connectedAccounts: ConnectedAccountsService = .shared,
        githubService: GitHubToolService = .shared,
        googleDriveService: GoogleDriveToolService = .shared,
        hasToolsPack: @escaping @Sendable () async -> Bool = ToolExecutionService.hasBoughtTheToolsPack
    ) {
        self.toolService = toolService
        self.ask = ask
        self.covenConnections = covenConnections
        connectedAccountsService = connectedAccounts
        self.githubService = githubService
        self.googleDriveService = googleDriveService
        self.hasToolsPack = hasToolsPack
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
    private static let toolsPackPrefixes = ["shell.", "github.", "google_drive.", "google_docs.", "google_sheets.", "google_slides.", "figma."]

    /// Returns true when the given tool name requires the Tools Pack entitlement.
    private func requiresToolsPack(_ toolName: String) -> Bool {
        Self.toolsPackPrefixes.contains { toolName.hasPrefix($0) }
    }

    /// Check the Tools Pack entitlement on the main actor.
    nonisolated static let hasBoughtTheToolsPack: @Sendable () async -> Bool = {
        await MainActor.run { StoreService.shared.hasToolsPack }
    }

    private func hasToolsPackEntitlement() async -> Bool {
        await hasToolsPack()
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

    func execute(toolCall called: ParsedToolCall, agentType: String, threadID: String? = nil) async -> ToolExecutionResult {
        // A tool called by a name it had before is the tool as it is named
        // now: allowed, refused and run as that one.
        let toolCall = ParsedToolCall(name: ToolNames.offeredName(of: called.name), args: called.args, reason: called.reason)

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

        // 3. A connected app's tool is used only as the thread's coven
        // lets its agents use that app, whatever else would be said of it.
        // (An MCP server's is checked where the server is found.)
        if let refusal = await covenRefusal(ofAppTool: toolCall.name, in: threadID) {
            return refusal
        }

        // 4. Entitlement Check – shell, GitHub, Google Drive require Tools Pack
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

        // 5. MCP Tool Routing
        if toolCall.name.hasPrefix("mcp.") {
            return await executeMCPTool(toolCall: toolCall, threadID: threadID)
        }

        // 6. Built-in Routing
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

        case "github.getRepo", "github.get_repo":
            return await executeGitHubGetRepo(toolCall: toolCall)

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

        case "github.getPullRequest", "github.get_pull_request", "github.get_pr":
            return await executeGitHubGetPR(toolCall: toolCall)

        case "github.listPullRequestFiles", "github.list_pull_request_files", "github.list_pr_files":
            return await executeGitHubListPRFiles(toolCall: toolCall)

        // --- Google Drive Tools ---
        case "google_drive.listFiles", "google_drive.list_files":
            return await executeGoogleDriveListFiles(toolCall: toolCall)

        case "google_drive.readFile", "google_drive.read_file":
            return await executeGoogleDriveReadFile(toolCall: toolCall)

        case "google_drive.uploadFile", "google_drive.upload_file":
            return await executeGoogleDriveUploadFile(toolCall: toolCall, threadID: threadID)

        case "google_docs.read":
            return await executeGoogleDocsRead(toolCall: toolCall)

        case "google_sheets.read":
            return await executeGoogleSheetsRead(toolCall: toolCall)

        case "google_slides.read":
            return await executeGoogleSlidesRead(toolCall: toolCall)

        case "google_sheets.readValues", "google_sheets.read_values":
            return await executeGoogleSheetsReadValues(toolCall: toolCall)

        case "google_sheets.updateValues", "google_sheets.write_values":
            return await executeGoogleSheetsUpdateValues(toolCall: toolCall, threadID: threadID)

        case "google_sheets.batchUpdate":
            return await executeGoogleRequests(.spreadsheet, toolCall: toolCall, threadID: threadID)

        case "google_slides.update":
            return await executeGoogleRequests(.presentation, toolCall: toolCall, threadID: threadID)

        case "google_docs.update":
            return await executeGoogleDocsUpdate(toolCall: toolCall, threadID: threadID)

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

    private func executeMCPTool(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
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

        let wasMarkedReadOnly = server.cachedTools?.first { $0.name == actionName }?.readOnlyHint == true

        // The server is used only as the thread's coven lets its agents
        // use it: not at all if it is not on there, and only its tools
        // marked as read-only if it is on to read.
        if let threadID {
            let decision = await CovenConnectionRules.decision(forToolMarkedReadOnly: wasMarkedReadOnly, ofMCPServer: server.id, in: covenConnections(threadID))
            if let refusal = CovenConnectionRules.refusal(decision, tool: toolCall.name, connection: server.name, isOfAnMCPServer: true) {
                return .error(tool: toolCall.name, message: refusal.message, errorType: refusal.code)
            }
        }

        // A tool the server marks as only reading is used without asking.
        // Any other (one it does not mark, or does not list) may change
        // something on the person's behalf, so they are asked first.
        if !wasMarkedReadOnly {
            let asked = await answer(in: threadID) {
                .mcp(server: server.name, address: Self.shownAddress(of: server), tool: actionName, arguments: toolCall.args, threadID: $0)
            }
            if let refusal = await ToolExecutionResult.refusal(asked, tool: toolCall.name) {
                return refusal
            }
        }

        // The stored auth token (Bearer/API key), as connection tests use it.
        let token = try? await connectedAccountsService.getMCPToken(forServerId: server.id)
        // What the thread's coven lets now: it may have been switched to
        // read-only or off while the person decided. Read before the
        // server is, so that the server's reading stays the last wait.
        var connectionsNow: CovenConnections?
        if let threadID {
            connectionsNow = await covenConnections(threadID)
        }

        // The last thing before the call, with nothing waited for after
        // it: the server as it is stored now. The person may have taken a
        // while, and what they approved (or what needed no asking) is this
        // tool on this server at this address. If the server has been
        // removed, renamed or pointed elsewhere, or a tool that needed no
        // asking is no longer marked as only reading, it is not that any
        // more, and the tool is not called.
        guard let current = await connectedAccountsService.getMCPServer(id: server.id),
              current.name == server.name, current.serverUrl == server.serverUrl else {
            return .error(
                tool: toolCall.name,
                message: "This MCP server was removed or changed before its tool could be called: the tool was not called.",
                errorType: "mcp_server_changed"
            )
        }
        // The tool as the server lists it now: the current protocol sends
        // the arguments its schema marks for it as headers too.
        let listed = current.cachedTools?.first { $0.name == actionName }
        // And as the thread's coven lets the server be used now, for the
        // tool as it is marked now.
        if threadID != nil {
            let decision = CovenConnectionRules.decision(forToolMarkedReadOnly: listed?.readOnlyHint == true, ofMCPServer: current.id, in: connectionsNow)
            if let refusal = CovenConnectionRules.refusal(decision, tool: toolCall.name, connection: current.name, isOfAnMCPServer: true) {
                return .error(tool: toolCall.name, message: refusal.message, errorType: refusal.code)
            }
        }
        guard wasMarkedReadOnly == false || listed?.readOnlyHint == true else {
            return .error(
                tool: toolCall.name,
                message: "This tool is no longer marked as read-only by its MCP server: the tool was not called. Ask again to be asked first.",
                errorType: "mcp_server_changed"
            )
        }
        let client = mcpClient(current, token)

        do {
            let items = try await client.callTool(name: actionName, arguments: toolCall.args, tool: listed)
            await client.disconnect()
            let block = "[MCP: \(actionName) on \(server.name)]\n" + items.map(\.shown).joined(separator: "\n\n")

            return await .success(
                tool: toolCall.name,
                result: ["status": AnyJSONValue("success"), "item_count": AnyJSONValue(items.count)],
                contextBlock: block
            )
        } catch let MCPClientError.toolFailed(said) {
            await client.disconnect()
            // The tool ran and says it failed: the model is told what it said.
            return await .error(tool: toolCall.name, message: "The tool reported an error: \(said)")
        } catch {
            await client.disconnect()
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

        guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
        }
        guard let path = extractString(from: toolCall.args, key: "path") else {
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'path'", field: "path")
        }
        let (owner, repo) = (repository.owner, repository.name)

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

        guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
        }
        // The commit message as the cloud app names it, or as this app did.
        guard let path = extractString(from: toolCall.args, key: "path"),
              let content = extractString(from: toolCall.args, key: "content"),
              let message = Self.given(extractString(from: toolCall.args, key: "commit_message")) ?? Self.given(extractString(from: toolCall.args, key: "message")) else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'path', 'content', 'commit_message'")
        }
        // A path that would not be sent is refused before anything is
        // looked up or anyone is asked.
        guard Self.isAPathWithinARepository(path) else {
            return await .validationError(tool: toolCall.name, message: "'path' is not the path of a file in the repository.", field: "path")
        }
        let (owner, repo) = (repository.owner, repository.name)

        let branch = Self.given(extractString(from: toolCall.args, key: "branch"))
        var sha = Self.given(extractString(from: toolCall.args, key: "sha"))

        // GitHub replaces a file only when told the sha of the one that
        // is there. Where the call names none, it is looked up, as the
        // cloud app does; the person is then asked knowing whether a file
        // is replaced. (With no thread there is no one to ask, and the
        // write is refused below without looking.)
        if sha == nil, threadID != nil {
            do {
                sha = try await githubService.shaOfFile(accountId: account.id, owner: owner, repo: repo, path: path, ref: branch)
            } catch {
                return await .error(tool: toolCall.name, message: "Could not look at '\(path)' before writing it: \(error.localizedDescription)")
            }
        }
        let replaces = sha != nil

        if let refusal = await refusal(ofAppChange: toolCall, in: threadID, { .gitHubWriteFile(owner: owner, repo: repo, path: path, branch: branch, message: message, content: content, replaces: replaces, threadID: $0) }) {
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
            let block = "[GitHub File Written: \(owner)/\(repo)/\(path)]\n\(replaces ? "Replaced the file that was there." : "A new file.")\nCommit message: \(message)"
            return await .success(tool: toolCall.name, result: ["path": AnyJSONValue(path), "replaced": AnyJSONValue(replaces)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.listFiles
    private func executeGitHubListFiles(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
        }
        let (owner, repo) = (repository.owner, repository.name)

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
            // A folder is told apart from a file by the slash after it.
            let fileNames: [String] = files.compactMap { file in
                guard let name = file["name"] as? String else { return nil }
                return file["type"] as? String == "dir" ? name + "/" : name
            }
            let block = "[GitHub Files: \(owner)/\(repo)/\(path)]\n" + fileNames.joined(separator: "\n")
            return await .success(tool: toolCall.name, result: ["count": AnyJSONValue(files.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.getRepo: what a repository is and which branch is
    /// its default.
    private func executeGitHubGetRepo(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
        }

        do {
            let found = try await githubService.getRepo(accountId: account.id, owner: repository.owner, repo: repository.name)
            let fullName = found["full_name"] as? String ?? repository.fullName
            let defaultBranch = found["default_branch"] as? String ?? ""
            let description = found["description"] as? String ?? ""
            let block = """
            [GitHub Repo: \(fullName)]
            Default branch: \(defaultBranch.isEmpty ? "(none)" : defaultBranch)
            Description: \(description.isEmpty ? "(none)" : description)
            """
            return await .success(
                tool: toolCall.name,
                result: [
                    "full_name": AnyJSONValue(fullName),
                    "default_branch": AnyJSONValue(defaultBranch),
                    "description": AnyJSONValue(description),
                ],
                contextBlock: block
            )
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.createBranch
    private func executeGitHubCreateBranch(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected.")
        }

        guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
        }
        // The branches as the cloud app names them (`base_ref`,
        // `new_branch`), or as it and this app also take them.
        let args = toolCall.args
        guard let baseBranch = extractString(from: args, key: "base_ref") ?? extractString(from: args, key: "base_branch") ?? extractString(from: args, key: "baseBranch"),
              let newBranch = extractString(from: args, key: "new_branch") ?? extractString(from: args, key: "branch") ?? extractString(from: args, key: "newBranch") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'base_ref', 'new_branch'")
        }
        // A branch's name goes into the address asked of GitHub: one that
        // would not be sent is refused before anyone is asked.
        guard Self.isAPathWithinARepository(baseBranch) else {
            return await .validationError(tool: toolCall.name, message: "'base_ref' is not the name of a branch.", field: "base_ref")
        }
        guard Self.isAPathWithinARepository(newBranch) else {
            return await .validationError(tool: toolCall.name, message: "'new_branch' is not the name of a branch.", field: "new_branch")
        }
        let (owner, repo) = (repository.owner, repository.name)

        if let refusal = await refusal(ofAppChange: toolCall, in: threadID, { .gitHubCreateBranch(owner: owner, repo: repo, newBranch: newBranch, baseBranch: baseBranch, threadID: $0) }) {
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

        guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
        }
        guard let title = extractString(from: toolCall.args, key: "title"),
              let head = extractString(from: toolCall.args, key: "head"),
              let base = extractString(from: toolCall.args, key: "base") else {
            return await .validationError(tool: toolCall.name, message: "Missing required arguments: 'title', 'head', 'base'")
        }
        let (owner, repo) = (repository.owner, repository.name)

        let body = extractString(from: toolCall.args, key: "body")

        if let refusal = await refusal(ofAppChange: toolCall, in: threadID, { .gitHubCreatePR(owner: owner, repo: repo, title: title, head: head, base: base, body: body, threadID: $0) }) {
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

        guard let asked = extractString(from: toolCall.args, key: "query") else {
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'query'", field: "query")
        }
        // A repository named beside the query is added to it, as the
        // cloud app adds it. (A query that names repositories of its own
        // still searches those too: this is no limit on where it looks.)
        var query = asked
        // (One given as null is one left out, as models write it.)
        if let given = toolCall.args["repo"], !(given.value is NSNull) {
            guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
                return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
            }
            query += " repo:\(repository.fullName)"
        }
        let page = GitHubToolArguments.page(in: toolCall.args)
        let perPage = GitHubToolArguments.perPage(in: toolCall.args, standard: 30)

        do {
            let result = try await githubService.searchCode(accountId: account.id, query: query, page: page, perPage: perPage)
            let items = result["items"] as? [[String: Any]] ?? []
            let total = result["total_count"] as? Int ?? 0
            // Each result with the repository it is in: a search can
            // reach more than one.
            let found: [String] = items.compactMap { item in
                guard let path = item["path"] as? String else { return nil }
                let within = (item["repository"] as? [String: Any])?["full_name"] as? String
                return within.map { "\($0): \(path)" } ?? path
            }
            // GitHub says so when it stopped looking before it had looked
            // everywhere.
            let incomplete = result["incomplete_results"] as? Bool == true
            let block = "[GitHub Code Search: \(query)]\n"
                + (found.isEmpty ? "(No results on this page)" : found.joined(separator: "\n"))
                + "\n(Page \(page), \(found.count) of \(total) results\(incomplete ? "; GitHub did not finish looking, so there may be more" : ""))"
            return await .success(tool: toolCall.name, result: ["total_count": AnyJSONValue(total), "page": AnyJSONValue(page)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute github.getPullRequest - fetch pull request details including title, body, state, and diff info
    private func executeGitHubGetPR(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected. Please connect GitHub in Settings > \(SettingsPane.connectedApps.listedTitle).")
        }

        guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
        }
        guard let pullNumber = GitHubToolArguments.pullNumber(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'pull_number'", field: "pull_number")
        }
        let (owner, repo) = (repository.owner, repository.name)

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

    /// Execute github.listPullRequestFiles - list files changed in a pull request with patches
    private func executeGitHubListPRFiles(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .github) else {
            return await .error(tool: toolCall.name, message: "GitHub not connected. Please connect GitHub in Settings > \(SettingsPane.connectedApps.listedTitle).")
        }

        guard let repository = GitHubToolArguments.repository(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GitHubToolArguments.repositoryMissing, field: "repo")
        }
        guard let pullNumber = GitHubToolArguments.pullNumber(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'pull_number'", field: "pull_number")
        }
        let (owner, repo) = (repository.owner, repository.name)

        do {
            let page = GitHubToolArguments.page(in: toolCall.args)
            let files = try await githubService.listPullRequestFiles(
                accountId: account.id,
                owner: owner,
                repo: repo,
                pullNumber: pullNumber,
                page: page,
                perPage: GitHubToolArguments.perPage(in: toolCall.args, standard: 50)
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

            let block = "[GitHub PR #\(pullNumber) Files (\(files.count) on page \(page))]\n\n" + fileDetails.joined(separator: "\n\n")

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
        // As many as asked for, between 1 and 100 (Google's most a page).
        let pageSize = min(100, max(1, GitHubToolArguments.whole("page_size", in: toolCall.args) ?? 50))

        do {
            let response = try await googleDriveService.listFiles(accountId: account.id, query: query, pageSize: pageSize)
            // Each file with its id: the other tools are asked by id.
            let files = response.files.map { "\($0.name) (\($0.mimeType ?? "unknown")), id: \($0.id)" }
            let block = "[Google Drive Files]\n"
                + (files.isEmpty ? "(No files)" : files.joined(separator: "\n"))
                + (response.nextPageToken == nil ? "" : "\n(There are more files than these. A narrower query finds the rest.)")
            return await .success(tool: toolCall.name, result: ["count": AnyJSONValue(response.files.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_drive.readFile: a file's text. A file of Google's
    /// own (a Doc, a Sheet, Slides) is exported as text; any other is read
    /// as it is.
    private func executeGoogleDriveReadFile(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let fileId = GoogleToolArguments.id(["file_id", "fileId"], in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GoogleToolArguments.idMissing("file_id"), field: "file_id")
        }

        // What to export it as: what the call names (by the cloud app's
        // name for it, or, where that is not there, this app's older one),
        // or what suits the file. A format that is named is the one asked
        // for: one that says nothing is not made up for.
        let named: String?
        switch GoogleToolArguments.exportFormat(in: toolCall.args) {
        case let .named(format): named = format
        case .leftOut: named = nil
        case let .unreadable(key):
            return await .validationError(tool: toolCall.name, message: "'\(key)' must be a MIME type such as text/plain, or be left out.", field: key)
        }

        do {
            var exportMimeType = named
            if exportMimeType == nil {
                let file = try await googleDriveService.getFile(accountId: account.id, fileId: fileId)
                if let type = file.mimeType, type.hasPrefix(GoogleToolArguments.ownTypePrefix) {
                    guard let export = GoogleToolArguments.textExport(ofOwnType: type) else {
                        return await .error(tool: toolCall.name, message: "'\(file.name)' is a \(type.dropFirst(GoogleToolArguments.ownTypePrefix.count)) in Google Drive, which has no text to read.")
                    }
                    exportMimeType = export
                } else if let size = file.size.flatMap(Int.init), size > GoogleToolArguments.largestFile {
                    // A file is read whole before its text is told: one
                    // too large to hold is not fetched.
                    return await .error(tool: toolCall.name, message: "'\(file.name)' is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), which is too large to read here (the most is \(ByteCountFormatter.string(fromByteCount: Int64(GoogleToolArguments.largestFile), countStyle: .file))).")
                }
            }
            let data = try await googleDriveService.downloadFile(
                accountId: account.id,
                fileId: fileId,
                exportMimeType: exportMimeType
            )
            guard let content = String(data: data, encoding: .utf8) else {
                // As the cloud app says it.
                let block = "[Google Drive File: \(fileId)]\n[Binary file, \(data.count) bytes - cannot display as text]"
                return await .success(tool: toolCall.name, result: ["file_id": AnyJSONValue(fileId), "size_bytes": AnyJSONValue(data.count)], contextBlock: block)
            }
            let block = "[Google Drive File: \(fileId)]\n\(GoogleToolArguments.cut(content))"
            return await .success(tool: toolCall.name, result: ["file_id": AnyJSONValue(fileId), "size_bytes": AnyJSONValue(data.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_docs.read: a document's title and text.
    private func executeGoogleDocsRead(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let documentId = GoogleToolArguments.id(["document_id", "documentId"], in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GoogleToolArguments.idMissing("document_id"), field: "document_id")
        }

        do {
            let document = try await googleDriveService.readDocument(accountId: account.id, documentId: documentId)
            let title = GoogleWorkspaceText.title(of: document) ?? documentId
            let text = GoogleWorkspaceText.text(ofDocument: document)
            let block = "[Google Doc: \(title)]\n" + (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(The document is empty)" : GoogleToolArguments.cut(text))
            return await .success(tool: toolCall.name, result: ["document_id": AnyJSONValue(documentId), "title": AnyJSONValue(title)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_sheets.read: a spreadsheet's title and its sheets,
    /// each with its size (their values are read with
    /// google_sheets.readValues).
    private func executeGoogleSheetsRead(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let spreadsheetId = GoogleToolArguments.id(["spreadsheet_id", "spreadsheetId"], in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GoogleToolArguments.idMissing("spreadsheet_id"), field: "spreadsheet_id")
        }

        do {
            let spreadsheet = try await googleDriveService.readSpreadsheet(
                accountId: account.id,
                spreadsheetId: spreadsheetId,
                fields: "properties.title,sheets.properties(title,gridProperties(rowCount,columnCount))"
            )
            let title = GoogleWorkspaceText.title(of: spreadsheet) ?? spreadsheetId
            let sheets = GoogleWorkspaceText.sheets(ofSpreadsheet: spreadsheet)
            let block = "[Google Sheet: \(title)]\nSheets:\n" + (sheets.isEmpty ? "(None)" : sheets.map { "- \($0)" }.joined(separator: "\n"))
            return await .success(tool: toolCall.name, result: ["spreadsheet_id": AnyJSONValue(spreadsheetId), "title": AnyJSONValue(title), "sheet_count": AnyJSONValue(sheets.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_slides.read: a presentation's title and the text on
    /// each of its slides.
    private func executeGoogleSlidesRead(toolCall: ParsedToolCall) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let presentationId = GoogleToolArguments.id(["presentation_id", "presentationId"], in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GoogleToolArguments.idMissing("presentation_id"), field: "presentation_id")
        }

        do {
            let presentation = try await googleDriveService.readPresentation(accountId: account.id, presentationId: presentationId)
            let title = GoogleWorkspaceText.title(of: presentation) ?? presentationId
            let slides = (presentation["slides"] as? [[String: Any]])?.count ?? 0
            let text = GoogleWorkspaceText.text(ofPresentation: presentation)
            let block = "[Google Slides: \(title)]\n" + (slides == 0 ? "(The presentation has no slides)" : GoogleToolArguments.cut(text))
            return await .success(tool: toolCall.name, result: ["presentation_id": AnyJSONValue(presentationId), "title": AnyJSONValue(title), "slide_count": AnyJSONValue(slides)], contextBlock: block)
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
        // The folders to put it in, by id, as the cloud app takes them.
        guard let folders = GoogleToolArguments.folders(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: "'parents' must be a list of folder ids, or be left out.", field: "parents")
        }

        if let refusal = await refusal(ofAppChange: toolCall, in: threadID, { .driveUpload(name: name, mimeType: mimeType, content: content, folders: folders, threadID: $0) }) {
            return refusal
        }

        do {
            let file = try await googleDriveService.uploadFile(
                accountId: account.id,
                name: name,
                mimeType: mimeType,
                content: content.data(using: .utf8) ?? Data(),
                parentFolderIds: folders
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

        guard let spreadsheetId = GoogleToolArguments.id(["spreadsheet_id", "spreadsheetId"], in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GoogleToolArguments.idMissing("spreadsheet_id"), field: "spreadsheet_id")
        }
        guard let range = Self.given(extractString(from: toolCall.args, key: "range")) else {
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'range'", field: "range")
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

    /// Execute google_sheets.updateValues (this app's older name for it
    /// was writeValues): write cells of a spreadsheet.
    private func executeGoogleSheetsUpdateValues(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let spreadsheetId = GoogleToolArguments.id(["spreadsheet_id", "spreadsheetId"], in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GoogleToolArguments.idMissing("spreadsheet_id"), field: "spreadsheet_id")
        }
        guard let range = Self.given(extractString(from: toolCall.args, key: "range")) else {
            return await .validationError(tool: toolCall.name, message: "Missing required argument: 'range'", field: "range")
        }
        guard let rows = GoogleToolArguments.rows(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: "Missing or invalid 'values': give rows of cells, such as [[\"Name\", \"Total\"], [\"Ada\", 3]].", field: "values")
        }
        guard let inputOption = GoogleToolArguments.valueInputOption(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: "'value_input_option' must be USER_ENTERED or RAW, or be left out.", field: "value_input_option")
        }

        let shown = rows.map { $0.map(GoogleToolArguments.shown) }
        if let refusal = await refusal(ofAppChange: toolCall, in: threadID, { .sheetsWrite(spreadsheetID: spreadsheetId, range: range, values: shown, asTyped: inputOption == "USER_ENTERED", threadID: $0) }) {
            return refusal
        }

        do {
            let answer = try await googleDriveService.writeSpreadsheetValues(
                accountId: account.id,
                spreadsheetId: spreadsheetId,
                range: range,
                // Each cell as it was given: text as text, a number as a number.
                values: rows.map { $0.map { cell in cell == .null ? "" : MCPClient.plain(cell) } },
                inputOption: inputOption
            )
            // What Google says it wrote (a row counts if a cell in it was
            // written); where it does not say, how many rows were sent.
            let written = answer["updatedRows"] as? Int
            let cells = answer["updatedCells"] as? Int
            let block = "[Google Sheets Updated: \(answer["updatedRange"] as? String ?? range)]\n"
                + (written.map { "Wrote \($0) \($0 == 1 ? "row" : "rows")" } ?? "Sent \(rows.count) \(rows.count == 1 ? "row" : "rows")")
                + (cells.map { " (\($0) \($0 == 1 ? "cell" : "cells"))" } ?? "")
            return await .success(tool: toolCall.name, result: ["updated_rows": AnyJSONValue(written ?? rows.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    /// Execute google_sheets.batchUpdate or google_slides.update: changes
    /// to a spreadsheet or a presentation, in Google's own form of
    /// requests, which the person is shown as they will be sent.
    private func executeGoogleRequests(_ file: ToolApproval.GoogleFile, toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        let keys = file == .spreadsheet ? ["spreadsheet_id", "spreadsheetId"] : ["presentation_id", "presentationId"]
        guard let id = GoogleToolArguments.id(keys, in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GoogleToolArguments.idMissing(keys[0]), field: keys[0])
        }
        guard let requests = GoogleToolArguments.requests(in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: Self.requestsMissing, field: "requests")
        }

        return await makeGoogleChanges(file, id: id, requests: requests, account: account.id, toolCall: toolCall, threadID: threadID) {
            .googleRequests(file, id: id, requests: requests, threadID: $0)
        }
    }

    /// Execute google_docs.update: text added to a document (`content`,
    /// at `index` or at the end), or changes in Google's own form of
    /// requests (`requests`).
    private func executeGoogleDocsUpdate(toolCall: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        guard let account = await connectedAccountsService.getConnectedAccount(for: .googleDrive) else {
            return await .error(tool: toolCall.name, message: "Google Drive not connected.")
        }

        guard let id = GoogleToolArguments.id(["document_id", "documentId"], in: toolCall.args) else {
            return await .validationError(tool: toolCall.name, message: GoogleToolArguments.idMissing("document_id"), field: "document_id")
        }

        // Requests, where the call gives them: they are what is asked.
        if let given = toolCall.args["requests"], !(given.value is NSNull) {
            guard let requests = GoogleToolArguments.requests(in: toolCall.args) else {
                return await .validationError(tool: toolCall.name, message: Self.requestsMissing, field: "requests")
            }
            return await makeGoogleChanges(.document, id: id, requests: requests, account: account.id, toolCall: toolCall, threadID: threadID) {
                .googleRequests(.document, id: id, requests: requests, threadID: $0)
            }
        }

        // Otherwise text to add, at a position or at the end.
        guard let text = Self.given(extractString(from: toolCall.args, key: "content")) else {
            return await .validationError(tool: toolCall.name, message: "Give 'content' (text to add to the document) or 'requests' (Google Docs API requests).", field: "content")
        }
        var index: Int?
        if let given = toolCall.args["index"], !(given.value is NSNull) {
            guard let position = GitHubToolArguments.whole("index", in: toolCall.args), position >= 1 else {
                return await .validationError(tool: toolCall.name, message: "'index' must be a position in the document (1 is its start), or be left out to add at the end.", field: "index")
            }
            index = position
        }
        let place: [String: AnyJSONValue] = index.map { ["location": .dictionary(["index": .int($0)])] } ?? ["endOfSegmentLocation": .dictionary([:])]
        let request: [String: AnyJSONValue] = ["insertText": .dictionary(place.merging(["text": .string(text)]) { first, _ in first })]

        return await makeGoogleChanges(.document, id: id, requests: [request], account: account.id, toolCall: toolCall, threadID: threadID) {
            .docsAddText(documentID: id, text: text, index: index, threadID: $0)
        }
    }

    private static let requestsMissing = "Missing or invalid 'requests': give one or more requests as the Google API takes them (a list of objects)."

    /// Asks the person about changes to a Google file and, if they
    /// approve, asks Google to make them.
    private func makeGoogleChanges(
        _ file: ToolApproval.GoogleFile,
        id: String,
        requests: [[String: AnyJSONValue]],
        account: String,
        toolCall: ParsedToolCall,
        threadID: String?,
        _ describe: @Sendable (_ threadID: String) -> ToolApproval
    ) async -> ToolExecutionResult {
        if let refusal = await refusal(ofAppChange: toolCall, in: threadID, describe) {
            return refusal
        }

        let plain = requests.map { $0.mapValues(MCPClient.plain) }
        do {
            switch file {
            case .document: _ = try await googleDriveService.updateDocument(accountId: account, documentId: id, requests: plain)
            case .spreadsheet: _ = try await googleDriveService.batchUpdateSpreadsheet(accountId: account, spreadsheetId: id, requests: plain)
            case .presentation: _ = try await googleDriveService.updatePresentation(accountId: account, presentationId: id, requests: plain)
            }
            let block = "[Google \(file.named) Changed: \(id)]\n\(requests.count) \(requests.count == 1 ? "change" : "changes") made."
            return await .success(tool: toolCall.name, result: ["id": AnyJSONValue(id), "changes": AnyJSONValue(requests.count)], contextBlock: block)
        } catch {
            return await .error(tool: toolCall.name, message: error.localizedDescription)
        }
    }

    // MARK: - Approvals

    /// Where a server is, as an approval shows it: its host (and port, if
    /// it names one), without the path or anything else of its address,
    /// which can carry a key.
    nonisolated static func shownAddress(of server: MCPServerAccount) -> String {
        guard let url = URL(string: server.serverUrl), let named = url.host, !named.isEmpty else { return "an address that cannot be read" }
        // An IPv6 address is written between brackets, as in an address.
        let host = named.contains(":") ? "[\(named)]" : named
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Makes the client a server's tool is called with; tests give one
    /// that answers from a script.
    private var mcpClient: @Sendable (MCPServerAccount, String?) -> MCPClient = { MCPClient(server: $0, token: $1) }

    func setMCPClient(_ make: @escaping @Sendable (MCPServerAccount, String?) -> MCPClient) {
        mcpClient = make
    }

    /// Why a connected app's tool may not be used in the thread, as its
    /// coven's choice of connections has it now; nil if it may, or it is
    /// no connected app's tool. Without a thread there is no coven.
    private func covenRefusal(ofAppTool tool: String, in threadID: String?) async -> ToolExecutionResult? {
        guard let threadID, let app = CovenConnectionRules.app(of: tool) else { return nil }
        let decision = await CovenConnectionRules.decision(forAppTool: tool, in: covenConnections(threadID))
        let connection = ConnectedAppProvider(rawValue: app)?.displayName ?? app
        guard let refusal = CovenConnectionRules.refusal(decision, tool: tool, connection: connection) else { return nil }
        return .error(tool: tool, message: refusal.message, errorType: refusal.code)
    }

    /// Asks the person about a connected app's change and, if they approve
    /// it, looks again at what the thread's coven lets: they may have
    /// taken a while, and a coven switched to read-only or off meanwhile
    /// is not written to. Nil means go ahead.
    private func refusal(ofAppChange toolCall: ParsedToolCall, in threadID: String?, _ describe: @Sendable (_ threadID: String) -> ToolApproval) async -> ToolExecutionResult? {
        if let refused = await ToolExecutionResult.refusal(answer(in: threadID, describe), tool: toolCall.name) {
            return refused
        }
        return await covenRefusal(ofAppTool: toolCall.name, in: threadID)
    }

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

    /// Whether this is a path GitHub is asked about as it stands: it has
    /// steps, and none is empty, "." or "..". (A branch's name is one too.)
    nonisolated static func isAPathWithinARepository(_ path: String) -> Bool {
        let steps = GitHubToolService.steps(of: path)
        return !steps.isEmpty && GitHubToolService.path(of: steps) != nil
    }

    /// An optional argument that says something: one given as "" is one
    /// left out.
    nonisolated static func given(_ text: String?) -> String? {
        text?.isEmpty == false ? text : nil
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
