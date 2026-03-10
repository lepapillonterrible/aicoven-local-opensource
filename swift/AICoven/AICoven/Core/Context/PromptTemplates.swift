import Foundation

// MARK: - PromptTemplates

/// Centralized prompt templates for agent instructions, tool documentation, and safety policies.
/// Used by ContextBuilder and ChatService to construct consistent prompts.
enum PromptTemplates {

    // MARK: - Tool Definitions

    /// All available tools with their schemas and descriptions.
    /// This is used to generate dynamic tool documentation in the system prompt.
    static let toolDefinitions: [ToolDefinition] = [
        // Web tools
        ToolDefinition(
            name: "web_search",
            description: "Search the web for information using DuckDuckGo.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Search query", required: true)
            ],
            example: #"{"tool": "web_search", "input": {"query": "latest Swift concurrency features"}, "reason": "Need to find current documentation"}"#,
            inputExamples: [
                ToolInputExample(description: "Simple factual search", input: ["query": "Swift 6 release date"]),
                ToolInputExample(description: "Technical search with specifics", input: ["query": "MLX framework iOS memory optimization KV cache"]),
                ToolInputExample(description: "Current events search", input: ["query": "WWDC 2026 announcements"]),
            ]
        ),
        ToolDefinition(
            name: "web_browse",
            description: "Read the content of a specific webpage URL.",
            parameters: [
                ToolParameter(name: "url", type: "string", description: "The URL to visit", required: true)
            ],
            example: #"{"tool": "web_browse", "input": {"url": "https://example.com"}, "reason": "Read page content"}"#,
            inputExamples: [
                ToolInputExample(description: "Read a documentation page", input: ["url": "https://developer.apple.com/documentation/swiftui"]),
                ToolInputExample(description: "Read a GitHub repository", input: ["url": "https://github.com/ml-explore/mlx-swift"]),
            ]
        ),
        ToolDefinition(
            name: "current_time",
            description: "Get the current date and time. Optionally specify a timezone identifier (e.g. 'Europe/London', 'America/New_York', 'Asia/Tokyo') to get the time in that timezone.",
            parameters: [
                ToolParameter(name: "timezone", type: "string", description: "IANA timezone identifier, e.g. 'Europe/London'. Defaults to the user's local timezone if omitted.", required: false)
            ],
            example: #"{"tool": "current_time", "input": {"timezone": "Europe/London"}, "reason": "Need to know current time in London"}"#,
            inputExamples: [
                ToolInputExample(description: "Local time (no timezone)", input: [:]),
                ToolInputExample(description: "Specific city timezone", input: ["timezone": "Asia/Tokyo"]),
                ToolInputExample(description: "Named timezone abbreviation", input: ["timezone": "America/New_York"]),
            ]
        ),

        // File tools
        ToolDefinition(
            name: "file.read",
            description: "Read the contents of a local file.",
            parameters: [
                ToolParameter(name: "path", type: "string", description: "Absolute path to the file", required: true)
            ],
            example: #"{"tool": "file.read", "input": {"path": "/Users/me/document.txt"}, "reason": "Need to read file contents"}"#,
            inputExamples: [
                ToolInputExample(description: "Read a text file", input: ["path": "/Users/me/notes.txt"]),
                ToolInputExample(description: "Read a config file", input: ["path": "/Users/me/project/.env"]),
            ]
        ),
        ToolDefinition(
            name: "file.write",
            description: "Write content to a local file. Creates the file if it doesn't exist.",
            parameters: [
                ToolParameter(name: "path", type: "string", description: "Absolute path for the file", required: true),
                ToolParameter(name: "content", type: "string", description: "Content to write", required: true)
            ],
            example: #"{"tool": "file.write", "input": {"path": "/Users/me/output.txt", "content": "Hello World"}, "reason": "Save results to file"}"#,
            inputExamples: [
                ToolInputExample(description: "Write a simple file", input: ["path": "/Users/me/output.txt", "content": "Hello World"]),
                ToolInputExample(description: "Write a script", input: ["path": "/tmp/test.py", "content": "print('hello')"]),
            ]
        ),
        ToolDefinition(
            name: "file.list",
            description: "List files and directories at a given path.",
            parameters: [
                ToolParameter(name: "path", type: "string", description: "Directory path to list", required: true),
                ToolParameter(name: "recursive", type: "boolean", description: "Whether to list recursively", required: false)
            ],
            example: #"{"tool": "file.list", "input": {"path": "/Users/me/Documents", "recursive": false}, "reason": "Explore directory"}"#,
            inputExamples: [
                ToolInputExample(description: "List a directory", input: ["path": "/Users/me/Documents"]),
                ToolInputExample(description: "Recursive listing", input: ["path": "/Users/me/project/src", "recursive": "true"]),
            ]
        ),

        // Shell tools
        ToolDefinition(
            name: "shell.execute",
            description: "Execute a shell command on the local system. Requires user approval for safety.",
            parameters: [
                ToolParameter(name: "command", type: "string", description: "Shell command to execute", required: true)
            ],
            example: #"{"tool": "shell.execute", "input": {"command": "ls -la"}, "reason": "List directory with details"}"#,
            inputExamples: [
                ToolInputExample(description: "Run a shell command", input: ["command": "ls -la /Users/me"]),
                ToolInputExample(description: "Run a Python one-liner", input: ["command": "python3 -c 'print(2+2)'"]),
                ToolInputExample(description: "Check git status", input: ["command": "git -C /Users/me/project status"]),
            ]
        ),

        // GitHub tools
        ToolDefinition(
            name: "github.listRepos",
            description: "List repositories accessible to the connected GitHub account.",
            parameters: [],
            example: #"{"tool": "github.listRepos", "input": {}, "reason": "Find available repositories"}"#
        ),
        ToolDefinition(
            name: "github.readFile",
            description: "Read a file from a GitHub repository.",
            parameters: [
                ToolParameter(name: "owner", type: "string", description: "Repository owner", required: true),
                ToolParameter(name: "repo", type: "string", description: "Repository name", required: true),
                ToolParameter(name: "path", type: "string", description: "File path in repository", required: true),
                ToolParameter(name: "ref", type: "string", description: "Branch or commit SHA", required: false)
            ],
            example: #"{"tool": "github.readFile", "input": {"owner": "user", "repo": "project", "path": "README.md"}, "reason": "Read documentation"}"#,
            inputExamples: [
                ToolInputExample(description: "Read a file from main", input: ["owner": "apple", "repo": "swift", "path": "README.md"]),
                ToolInputExample(description: "Read from a specific branch", input: ["owner": "user", "repo": "project", "path": "src/main.swift", "ref": "feature/new"]),
            ]
        ),
        ToolDefinition(
            name: "github.writeFile",
            description: "Create or update a file in a GitHub repository.",
            parameters: [
                ToolParameter(name: "owner", type: "string", description: "Repository owner", required: true),
                ToolParameter(name: "repo", type: "string", description: "Repository name", required: true),
                ToolParameter(name: "path", type: "string", description: "File path", required: true),
                ToolParameter(name: "content", type: "string", description: "File content", required: true),
                ToolParameter(name: "message", type: "string", description: "Commit message", required: true),
                ToolParameter(name: "branch", type: "string", description: "Target branch", required: false),
                ToolParameter(name: "sha", type: "string", description: "SHA of file being replaced (for updates)", required: false)
            ],
            example: "{\"tool\": \"github.writeFile\", \"input\": {\"owner\": \"user\", \"repo\": \"project\", \"path\": \"README.md\", \"content\": \"Title\", \"message\": \"Update readme\"}, \"reason\": \"Update documentation\"}"
        ),
        ToolDefinition(
            name: "github.listFiles",
            description: "List files in a GitHub repository directory.",
            parameters: [
                ToolParameter(name: "owner", type: "string", description: "Repository owner", required: true),
                ToolParameter(name: "repo", type: "string", description: "Repository name", required: true),
                ToolParameter(name: "path", type: "string", description: "Directory path (empty for root)", required: false),
                ToolParameter(name: "ref", type: "string", description: "Branch or commit SHA", required: false)
            ],
            example: #"{"tool": "github.listFiles", "input": {"owner": "user", "repo": "project", "path": "src"}, "reason": "Explore source directory"}"#
        ),
        ToolDefinition(
            name: "github.createBranch",
            description: "Create a new branch from an existing branch.",
            parameters: [
                ToolParameter(name: "owner", type: "string", description: "Repository owner", required: true),
                ToolParameter(name: "repo", type: "string", description: "Repository name", required: true),
                ToolParameter(name: "base_branch", type: "string", description: "Branch to create from", required: true),
                ToolParameter(name: "new_branch", type: "string", description: "Name for new branch", required: true)
            ],
            example: #"{"tool": "github.createBranch", "input": {"owner": "user", "repo": "project", "base_branch": "main", "new_branch": "feature/new"}, "reason": "Create feature branch"}"#
        ),
        ToolDefinition(
            name: "github.createPR",
            description: "Create a pull request.",
            parameters: [
                ToolParameter(name: "owner", type: "string", description: "Repository owner", required: true),
                ToolParameter(name: "repo", type: "string", description: "Repository name", required: true),
                ToolParameter(name: "title", type: "string", description: "PR title", required: true),
                ToolParameter(name: "head", type: "string", description: "Source branch", required: true),
                ToolParameter(name: "base", type: "string", description: "Target branch", required: true),
                ToolParameter(name: "body", type: "string", description: "PR description", required: false)
            ],
            example: #"{"tool": "github.createPR", "input": {"owner": "user", "repo": "project", "title": "Add feature", "head": "feature/new", "base": "main"}, "reason": "Open PR for review"}"#
        ),
        ToolDefinition(
            name: "github.searchCode",
            description: "Search for code across GitHub repositories.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Search query (can include qualifiers like repo:owner/name)", required: true)
            ],
            example: #"{"tool": "github.searchCode", "input": {"query": "repo:user/project extension:swift"}, "reason": "Find Swift files in repository"}"#
        ),
        ToolDefinition(
            name: "github.getPR",
            description: "Get details of a pull request including title, description, state, and diff statistics.",
            parameters: [
                ToolParameter(name: "owner", type: "string", description: "Repository owner", required: true),
                ToolParameter(name: "repo", type: "string", description: "Repository name", required: true),
                ToolParameter(name: "pull_number", type: "integer", description: "Pull request number", required: true)
            ],
            example: #"{"tool": "github.getPR", "input": {"owner": "user", "repo": "project", "pull_number": 42}, "reason": "Review pull request details"}"#
        ),
        ToolDefinition(
            name: "github.listPRFiles",
            description: "List all files changed in a pull request with their patches/diffs.",
            parameters: [
                ToolParameter(name: "owner", type: "string", description: "Repository owner", required: true),
                ToolParameter(name: "repo", type: "string", description: "Repository name", required: true),
                ToolParameter(name: "pull_number", type: "integer", description: "Pull request number", required: true)
            ],
            example: #"{"tool": "github.listPRFiles", "input": {"owner": "user", "repo": "project", "pull_number": 42}, "reason": "See what files changed in PR"}"#
        ),

        // Google Drive tools
        ToolDefinition(
            name: "google_drive.listFiles",
            description: "List files in Google Drive.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Optional search query (Drive query syntax)", required: false)
            ],
            example: #"{"tool": "google_drive.listFiles", "input": {"query": "name contains 'report'"}, "reason": "Find report files"}"#
        ),
        ToolDefinition(
            name: "google_drive.readFile",
            description: "Read/download a file from Google Drive.",
            parameters: [
                ToolParameter(name: "file_id", type: "string", description: "Google Drive file ID", required: true),
                ToolParameter(name: "export_mime_type", type: "string", description: "Export format for Google Docs (e.g., text/plain)", required: false)
            ],
            example: #"{"tool": "google_drive.readFile", "input": {"file_id": "abc123"}, "reason": "Read file contents"}"#
        ),
        ToolDefinition(
            name: "google_drive.uploadFile",
            description: "Upload a file to Google Drive.",
            parameters: [
                ToolParameter(name: "name", type: "string", description: "File name", required: true),
                ToolParameter(name: "content", type: "string", description: "File content", required: true),
                ToolParameter(name: "mime_type", type: "string", description: "MIME type (default: text/plain)", required: false)
            ],
            example: #"{"tool": "google_drive.uploadFile", "input": {"name": "notes.txt", "content": "Meeting notes..."}, "reason": "Save notes to Drive"}"#
        ),
        ToolDefinition(
            name: "google_sheets.readValues",
            description: "Read values from a Google Sheets spreadsheet.",
            parameters: [
                ToolParameter(name: "spreadsheet_id", type: "string", description: "Spreadsheet ID", required: true),
                ToolParameter(name: "range", type: "string", description: "A1 notation range (e.g., Sheet1!A1:C10)", required: true)
            ],
            example: #"{"tool": "google_sheets.readValues", "input": {"spreadsheet_id": "abc123", "range": "Sheet1!A1:D10"}, "reason": "Read data from spreadsheet"}"#
        ),
        ToolDefinition(
            name: "google_sheets.writeValues",
            description: "Write values to a Google Sheets spreadsheet.",
            parameters: [
                ToolParameter(name: "spreadsheet_id", type: "string", description: "Spreadsheet ID", required: true),
                ToolParameter(name: "range", type: "string", description: "A1 notation range", required: true),
                ToolParameter(name: "values", type: "array", description: "2D array of values to write", required: true)
            ],
            example: #"{"tool": "google_sheets.writeValues", "input": {"spreadsheet_id": "abc123", "range": "Sheet1!A1", "values": [["Name", "Value"], ["Test", "123"]]}, "reason": "Update spreadsheet"}"#
        )
    ]

    // MARK: - Tool Protocol Instructions

    /// Instructions for how the agent should call tools.
    /// Supports JSON, angle-bracket, and square-bracket formats.
    // MARK: - MLX-Optimized Tool Instructions (for small local models)

    /// Shorter, more directive tool-calling instructions optimized for small
    /// models (4B-7B) that struggle with long prompts. Uses assertive language
    /// and few-shot examples to maximize compliance.
    static let mlxToolProtocolInstructions: String = """
    CRITICAL TOOL-CALLING RULES:

    You have access to the tools listed in AVAILABLE TOOLS above. When you need information you don't have (current time, file contents, web data), you MUST respond with ONLY a JSON object. Do NOT write any other text before or after the JSON. Do NOT use tools that are not listed in AVAILABLE TOOLS.

    JSON FORMAT:
    {"tool": "tool_name", "input": {"param": "value"}, "reason": "brief reason"}

    EXAMPLES OF CORRECT BEHAVIOR:

    User: What time is it?
    Correct response: {"tool": "current_time", "input": {"timezone": "UTC"}, "reason": "Get current time"}

    User: Tell me about the project at /Users/me/myproject
    Correct response: {"tool": "file.list", "input": {"path": "/Users/me/myproject"}, "reason": "List project files"}

    User: Read the file at /Users/me/readme.txt
    Correct response: {"tool": "file.read", "input": {"path": "/Users/me/readme.txt"}, "reason": "Read file contents"}

    User: Search the web for Swift concurrency
    Correct response: {"tool": "web_search", "input": {"query": "Swift concurrency"}, "reason": "Search for information"}

    User: Run ls -la in /Users/me
    Correct response: {"tool": "shell.execute", "input": {"command": "ls -la /Users/me"}, "reason": "List directory with details"}

    User: Write a script that calculates 2+2 and run it
    Correct response: {"tool": "shell.execute", "input": {"command": "python3 -c 'print(2+2)'"}, "reason": "Calculate 2+2 using Python"}

    User: Run a Node.js script
    Correct response: {"tool": "shell.execute", "input": {"command": "node -e 'console.log(42)'"}, "reason": "Run Node.js code"}

    User: What is 2+2?
    Correct response: 2+2 = 4 (no tool needed, answer directly)

    User: Check my gmail for emails from App Store Connect
    Correct response: {"tool": "mcp.zapier.find_email", "input": {"search": "from:appstoreconnect"}, "reason": "Search Gmail for App Store Connect emails"}

    User: Send a Slack message to #general saying hello
    Correct response: {"tool": "mcp.zapier.send_slack_message", "input": {"channel": "#general", "message": "hello"}, "reason": "Send Slack message"}

    IMPORTANT: You DO have access to external services (email, Slack, calendar, etc.) through MCP tools. NEVER say "I can't access external systems." If a user asks about their email, calendar, or any connected service, use the appropriate mcp.* tool.

    RULES:
    - ONLY use tools from the AVAILABLE TOOLS list above. Do NOT invent tools.
    - There is NO "python" tool, NO "code" tool, NO "execute" tool. Use shell.execute to run ANY command or script.
    - Do NOT wrap your JSON in markdown code fences (```). Output raw JSON only.
    - If the user asks about time, dates, or schedules → use current_time
    - If the user mentions a file path or directory → use file.read or file.list
    - If the user asks to search something online → use web_search
    - If the user asks to run a command or script → use shell.execute
    - Call ONE tool at a time, wait for the result
    - After receiving a tool result, answer the user's question using that data
    - Do NOT wrap your response in <think>, <thought>, or any XML/HTML tags
    - Do NOT include internal reasoning or chain-of-thought in your response
    - Respond directly with either a tool call JSON or a natural-language answer
    /no_think
    """

    /// Generate a lean system prompt for MLX models with only essential sections.
    ///
    /// For MCP tools, this uses a two-tier approach:
    ///   1. A compressed catalog (~200 tokens) listing all servers and tool names
    ///   2. Full documentation only for the ~8 tools most relevant to the
    ///      current user message (selected by semantic + keyword hybrid search)
    ///
    /// Tool selection uses `EmbeddingService.searchRelevantTools` when an
    /// embedding provider is configured (semantic cosine + lexical overlap),
    /// falling back to pure keyword matching otherwise.
    ///
    /// - Parameters:
    ///   - enabledTools: Set of tool names that are enabled.
    ///   - mcpServers: Active MCP server configurations.
    ///   - userMessage: Current user message, used to select relevant MCP tools.
    @MainActor
    static func generateMLXAgentPrompt(
        enabledTools: Set<String>,
        mcpServers: [MCPServerAccount] = [],
        userMessage: String = ""
    ) async -> String {
        var sections: [String] = []

        // Brief role description
        sections.append("You are a helpful AI assistant running locally. You have tools to help you answer questions that need real-time or external data.")

        // Native tools: use ToolRelevanceService to select the most relevant
        // subset when many native tools are enabled (GitHub + Google Drive
        // can push the count above 15). Always-loaded tools (current_time,
        // web_search, shell.execute) bypass scoring.
        let allNativeDefs = toolDefinitions.filter { enabledTools.contains($0.name) }
        let nativeDefs: [ToolDefinition]
        if allNativeDefs.count > 8, !userMessage.isEmpty {
            nativeDefs = await ToolRelevanceService.shared.selectRelevantNativeTools(
                userMessage: userMessage,
                allTools: allNativeDefs,
                limit: 8
            )
            // Add compressed catalog for excluded native tools.
            let excluded = allNativeDefs.filter { def in !nativeDefs.contains(where: { $0.name == def.name }) }
            if let catalog = ToolRelevanceService.generateCompressedNativeCatalog(excluded: excluded) {
                sections.append(catalog)
            }
        } else {
            nativeDefs = allNativeDefs
        }

        // MCP tools: use tiered approach for local models.
        // 1) Compressed catalog of ALL MCP tools (~200 tokens).
        // 2) Full docs only for the most relevant tools to this message.
        let allMCPDefs = mcpToolDefinitions(from: mcpServers)
        let relevantMCPDefs: [ToolDefinition]

        if allMCPDefs.count > maxLocalModelMCPTools {
            // Too many MCP tools for full docs — select the most relevant
            // using semantic search (with keyword fallback).
            relevantMCPDefs = await selectRelevantMCPTools(
                userMessage: userMessage,
                allMCPTools: allMCPDefs
            )
            // Add the compressed catalog so the model knows what else exists.
            if let catalog = generateCompressedMCPCatalog(from: mcpServers) {
                sections.append(catalog)
            }
        } else {
            // Few enough MCP tools to include all with full docs.
            relevantMCPDefs = allMCPDefs
        }

        // Filter to only enabled tools and combine native + selected MCP.
        let enabledMCPDefs = relevantMCPDefs.filter { enabledTools.contains($0.name) }
        let allDefs = nativeDefs + enabledMCPDefs

        if !allDefs.isEmpty {
            sections.append(generateToolDocumentation(for: allDefs, compact: true))
        }

        // MLX-optimized protocol
        sections.append(mlxToolProtocolInstructions)

        return sections.joined(separator: "\n\n")
    }

    static let toolProtocolInstructions: String = """
    TOOL-CALLING PROTOCOL:

    When you need to use a tool, respond with a tool call in one of these formats:

    1. JSON format (preferred):
       {"tool": "tool_name", "input": {"param": "value"}, "reason": "why you need this"}

    2. Angle-bracket format:
       <TOOL_CALL>tool_name {"param": "value"}</TOOL_CALL>

    3. Square-bracket format:
       [TOOL_CALL: name=tool_name] {"param": "value"} [/TOOL_CALL]

    RULES:
    - Call only ONE tool at a time
    - Wait for the result before making another tool call
    - When you have enough information, provide your final answer in natural language
    - Do NOT include tool call syntax in your final answer
    """

    // MARK: - Thought Block Instructions

    /// Instructions for using <thought> blocks for reasoning visibility.
    static let thoughtBlockInstructions: String = """
    REASONING VISIBILITY:

    You may use <thought> blocks to show your reasoning process:

    <thought>
    Let me analyze this step by step:
    1. First, I need to understand the user's request...
    2. The relevant information is...
    3. I should use tool X because...
    </thought>

    Thought blocks help the user understand your reasoning but are stripped from the final display.
    """

    // MARK: - Scratchpad Instructions

    /// Instructions for using <scratchpad> blocks to track multi-step tasks.
    static let scratchpadInstructions: String = """
    TASK TRACKING (for multi-step operations):

    Use a <scratchpad> block to track progress on complex tasks:

    <scratchpad>
    - [x] Step 1: Understand the requirements
    - [x] Step 2: Search for relevant files
    - [ ] Step 3: Analyze the code
    - [ ] Step 4: Make changes
    - [ ] Step 5: Verify the solution
    </scratchpad>

    Update the scratchpad as you complete each step. Mark completed items with [x].
    """

    // MARK: - Memory Write Instructions

    /// Instructions for proposing memory writes.
    static let memoryWriteInstructions: String = """
    MEMORY PROPOSALS:

    If you learn important information that should be remembered for future conversations,
    propose a memory write using this format:

    [MEMORY_WRITE: scope=user|thread]
    The information to remember as a concise summary.
    [/MEMORY_WRITE]

    - Use scope=user for information relevant across all conversations
    - Use scope=thread for information specific to this conversation
    - Keep memories concise and factual
    - Memory proposals require user confirmation before being saved
    """

    // MARK: - Safety Policies

    /// Safety policies for agent behavior.
    static let safetyPolicies: String = """
    SAFETY POLICIES:

    1. PRIVACY: Treat all user data as private. Do not expose sensitive information.
    2. CONFIRMATION: Always confirm before making changes to files or executing commands.
    3. SHELL SAFETY: Shell commands require explicit user approval. Never run destructive commands.
    4. RATE LIMITS: Respect tool rate limits. If limited, wait before retrying.
    5. ERROR HANDLING: If a tool fails, explain the error and suggest alternatives.
    6. SCOPE: Stay within the boundaries of what the user has asked.
    """

    // MARK: - Full Agent System Prompt

    /// Generate a complete agent system prompt with tool documentation.
    /// - Parameters:
    ///   - enabledTools: Set of tool names that are enabled for this agent.
    ///   - mcpServers: List of MCP servers to append dynamic tools from.
    ///   - includeThoughtBlocks: Whether to include thought block instructions.
    ///   - includeScratchpad: Whether to include scratchpad instructions.
    ///   - includeMemoryWrite: Whether to include memory write instructions.
    /// - Returns: Complete system prompt string.
    static func generateAgentPrompt(
        enabledTools: Set<String>,
        mcpServers: [MCPServerAccount] = [],
        includeThoughtBlocks: Bool = true,
        includeScratchpad: Bool = true,
        includeMemoryWrite: Bool = true
    ) -> String {
        var sections: [String] = []

        // Base role description
        sections.append("""
        You are a capable AI assistant running locally on the user's device.
        You have access to various tools to help accomplish tasks.
        Use the provided context (memories, conversation history) to respond helpfully.
        """)

        // Tool documentation
        if !enabledTools.isEmpty {
            let nativeDefs = toolDefinitions.filter { enabledTools.contains($0.name) }
            let mcpDefs = mcpToolDefinitions(from: mcpServers).filter { enabledTools.contains($0.name) }
            let allDefs = nativeDefs + mcpDefs

            if !allDefs.isEmpty {
                sections.append(generateToolDocumentation(for: allDefs, compact: false))
            }
            sections.append(toolProtocolInstructions)
        }

        // Optional sections
        if includeThoughtBlocks {
            sections.append(thoughtBlockInstructions)
        }
        if includeScratchpad {
            sections.append(scratchpadInstructions)
        }
        if includeMemoryWrite {
            sections.append(memoryWriteInstructions)
        }

        // Safety policies always included
        sections.append(safetyPolicies)

        return sections.joined(separator: "\n\n")
    }

    /// Generate tool documentation section for enabled tools.
    ///
    /// - Parameter compact: When `true` (used by `generateMLXAgentPrompt`),
    ///   omits `inputExamples` to save context tokens. The few-shot examples
    ///   in `mlxToolProtocolInstructions` serve local models instead.
    private static func generateToolDocumentation(
        for tools: [ToolDefinition],
        compact: Bool = false
    ) -> String {
        var lines = ["AVAILABLE TOOLS:"]

        for tool in tools {
            lines.append("")
            lines.append("## \(tool.name)")
            lines.append(tool.description)

            if !tool.parameters.isEmpty {
                lines.append("Parameters:")
                for param in tool.parameters {
                    let req = param.required ? "(required)" : "(optional)"
                    lines.append("  - \(param.name): \(param.type) \(req) - \(param.description)")
                }
            }

            lines.append("Example: \(tool.example)")

            // Append structured input examples for cloud models.
            // Local models skip these (compact=true) — LoRA training
            // data and few-shot examples handle parameter accuracy.
            if !compact, !tool.inputExamples.isEmpty {
                lines.append("Input examples:")
                for ex in tool.inputExamples {
                    let params = ex.input.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
                    let inputStr = ex.input.isEmpty ? "{}" : "{\(params)}"
                    lines.append("  \(ex.description): \(inputStr)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Default Tool Sets

    /// Basic tools available in all chat contexts.
    static let basicChatTools: Set<String> = ["web_search", "web_browse", "current_time"]

    /// File tools for local file operations.
    static let fileTools: Set<String> = ["file.read", "file.write", "file.list"]

    /// Shell tools for command execution.
    static let shellTools: Set<String> = ["shell.execute"]

    /// GitHub tools for repository operations.
    static let githubTools: Set<String> = [
        "github.listRepos", "github.readFile", "github.writeFile",
        "github.listFiles", "github.createBranch", "github.createPR", "github.searchCode",
        "github.getPR", "github.listPRFiles"
    ]

    /// Google Drive/Sheets tools.
    static let googleDriveTools: Set<String> = [
        "google_drive.listFiles", "google_drive.readFile", "google_drive.uploadFile",
        "google_sheets.readValues", "google_sheets.writeValues"
    ]

    /// All tools combined.
    static let allTools: Set<String> = basicChatTools
        .union(fileTools)
        .union(shellTools)
        .union(githubTools)
        .union(googleDriveTools)

    /// Dynamically resolve the Set of actual enabled native tools according to Connected Accounts + Entitlements.
    static func connectedToolSet() async -> Set<String> {
        var tools = basicChatTools.union(fileTools)

        // The shell tool currently requires the Tools Pack IAP entitlement
        let hasToolsPack = await MainActor.run { StoreService.shared.hasToolsPack }
        if hasToolsPack {
            tools.formUnion(shellTools)
        }

        let accountsService = ConnectedAccountsService.shared

        if await accountsService.getConnectedAccount(for: .github) != nil {
            tools.formUnion(githubTools)
        }

        if await accountsService.getConnectedAccount(for: .googleDrive) != nil {
            tools.formUnion(googleDriveTools)
        }

        return tools
    }
}

// MARK: - Supporting Types

/// A concrete input example for a tool, showing a specific use case with
/// exact parameter values. Used by cloud models (Anthropic `input_examples`,
/// OpenAI/Gemini description injection) to improve parameter accuracy.
struct ToolInputExample: Sendable {
    /// Human-readable description of what this example demonstrates.
    let description: String
    /// The exact input dictionary the model should produce for this case.
    let input: [String: String]
}

/// Definition of a tool including its parameters and usage example.
/// Conforms to Sendable since all properties are value types.
struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [ToolParameter]
    let example: String
    /// Structured input examples for native function-calling providers.
    /// 2-3 per tool covering minimal, typical, and edge-case usage.
    let inputExamples: [ToolInputExample]

    init(
        name: String,
        description: String,
        parameters: [ToolParameter],
        example: String,
        inputExamples: [ToolInputExample] = []
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.example = example
        self.inputExamples = inputExamples
    }
}

/// Parameter definition for a tool.
/// Conforms to Sendable since all properties are value types.
struct ToolParameter: Sendable {
    let name: String
    let type: String
    let description: String
    let required: Bool
}

// MARK: - Integration Helpers

extension PromptTemplates {
    /// Convert MCP tools from servers into internal ToolDefinitions for prompting.
    static func mcpToolDefinitions(from servers: [MCPServerAccount]) -> [ToolDefinition] {
        var defs: [ToolDefinition] = []
        for server in servers {
            guard let tools = server.cachedTools else { continue }

            let safeServerName = server.name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            for tool in tools {
                // E.g. mcp.zapier.send_slack_message
                let combinedName = "mcp.\(safeServerName).\(tool.name)"
                var params: [ToolParameter] = []

                if let properties = tool.inputSchema["properties"]?.value as? [String: AnyJSONValue] {
                    let requiredFields = tool.inputSchema["required"]?.value as? [String] ?? []

                    // Note: Sorting keys for deterministic output in prompt
                    for key in properties.keys.sorted() {
                        if case let .dictionary(propDict) = properties[key] {
                            let type = propDict["type"]?.value as? String ?? "string"
                            let desc = propDict["description"]?.value as? String ?? ""
                            params.append(ToolParameter(
                                name: key,
                                type: type,
                                description: desc,
                                required: requiredFields.contains(key)
                            ))
                        }
                    }
                }

                defs.append(ToolDefinition(
                    name: combinedName,
                    description: tool.description ?? "MCP Tool from \(server.name)",
                    parameters: params,
                    example: "{\"tool\": \"\(combinedName)\", \"input\": {}, \"reason\": \"Use \(tool.name)\"}"
                ))
            }
        }
        return defs
    }
}

// MARK: - MCP Tool Tiering for Local Models

extension PromptTemplates {

    /// Maximum number of MCP tools to include with full documentation in
    /// local model (MLX/Ollama) prompts. Keeps context usage predictable.
    private static let maxLocalModelMCPTools = 8

    /// Select the most relevant MCP tools for a user message using hybrid
    /// semantic + keyword matching. Tries embedding-based search first via
    /// `EmbeddingService`; falls back to pure keyword matching if no
    /// embedding provider is configured.
    ///
    /// Entirely dynamic — works with any MCP server and tool names.
    @MainActor
    static func selectRelevantMCPTools(
        userMessage: String,
        allMCPTools: [ToolDefinition],
        limit: Int = maxLocalModelMCPTools
    ) async -> [ToolDefinition] {
        guard !allMCPTools.isEmpty else { return [] }

        // Try semantic search first — uses the same hybrid cosine + lexical
        // scoring as memory retrieval. Returns nil if no embedding provider
        // is configured, in which case we fall back to keyword matching.
        if let semanticResults = await EmbeddingService.shared.searchRelevantTools(
            query: userMessage,
            tools: allMCPTools,
            topK: limit
        ), !semanticResults.isEmpty {
            let selected = semanticResults.map(\.tool)
            // Pad with defaults if semantic search returned very few.
            if selected.count < 3 {
                let selectedNames = Set(selected.map(\.name))
                let extras = allMCPTools
                    .filter { !selectedNames.contains($0.name) }
                    .prefix(limit - selected.count)
                return selected + Array(extras)
            }
            return selected
        }

        // Fallback: pure keyword matching (works without any provider).
        return selectRelevantMCPToolsByKeyword(
            userMessage: userMessage,
            allMCPTools: allMCPTools,
            limit: limit
        )
    }

    /// Keyword-only fallback for tool selection when no embedding provider
    /// is available. Scores tools by word overlap between the user message
    /// and tool names/descriptions.
    private static func selectRelevantMCPToolsByKeyword(
        userMessage: String,
        allMCPTools: [ToolDefinition],
        limit: Int
    ) -> [ToolDefinition] {
        // Tokenize user message into lowercase words for matching.
        let messageWords = userMessage.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 3 } // Skip short noise words

        guard !messageWords.isEmpty else {
            // No meaningful words — return a small default set.
            return Array(allMCPTools.prefix(min(5, limit)))
        }

        // Score each tool based on how many user words appear in its name
        // or description. Name matches are weighted higher since they're
        // more specific (e.g. "send_email" matches "email" directly).
        var scored: [(tool: ToolDefinition, score: Int)] = []
        for tool in allMCPTools {
            let lowerName = tool.name.lowercased()
            let lowerDesc = tool.description.lowercased()
            var score = 0
            for word in messageWords {
                if lowerName.contains(word) { score += 3 }
                if lowerDesc.contains(word) { score += 1 }
            }
            if score > 0 {
                scored.append((tool, score))
            }
        }

        // Sort by score descending, take top N.
        let selected = scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.tool)

        // If keyword matching found very few, pad with the first few tools
        // from the full list so the model has some MCP awareness.
        if selected.count < 3 {
            let selectedNames = Set(selected.map(\.name))
            let extras = allMCPTools
                .filter { !selectedNames.contains($0.name) }
                .prefix(limit - selected.count)
            return selected + extras
        }

        return Array(selected)
    }

    /// Generate a compressed one-line-per-server catalog of all MCP tools.
    /// This gives the model awareness of what tools exist (~200 tokens for
    /// 200+ tools) without burning context on full parameter documentation.
    ///
    /// Completely dynamic — works with any server name and any tool names.
    ///
    /// Example output:
    ///   MCP TOOL CATALOG (207 tools across 12 servers):
    ///   - zapier_mcp (15): send_email, find_email, draft_email, ...
    ///   - my_notion (40): create_page, find_page, update_block, ...
    static func generateCompressedMCPCatalog(
        from servers: [MCPServerAccount]
    ) -> String? {
        // Group tools by server name for the catalog.
        var serverEntries: [(name: String, toolNames: [String])] = []
        var totalCount = 0

        for server in servers {
            guard let tools = server.cachedTools, !tools.isEmpty else { continue }
            let safeServerName = server.name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Use the short tool name (not mcp.server.tool prefix) to keep
            // the catalog compact.
            let names = tools.map(\.name)
            serverEntries.append((name: safeServerName, toolNames: names))
            totalCount += names.count
        }

        guard totalCount > 0 else { return nil }

        var lines: [String] = []
        lines.append("MCP TOOL CATALOG (\(totalCount) tools across \(serverEntries.count) servers):")
        lines.append("To call: {\"tool\": \"mcp.<server>.<tool_name>\", \"input\": {...}, \"reason\": \"...\"}")

        for entry in serverEntries {
            // Show up to 5 tool names per server for brevity.
            let preview = entry.toolNames.prefix(5).joined(separator: ", ")
            let suffix = entry.toolNames.count > 5 ? ", ... (\(entry.toolNames.count - 5) more)" : ""
            lines.append("- \(entry.name) (\(entry.toolNames.count)): \(preview)\(suffix)")
        }

        lines.append("")
        lines.append("Only the most relevant tools are documented in detail below. For others, use the naming pattern above.")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Conversion to LLMToolDefinition

extension PromptTemplates {

    /// Maximum MCP tools to include in cloud model native function calling.
    /// Cloud models handle more tools than local ones, but 200+ still wastes
    /// tokens the user pays for on every request. 20 is generous enough to
    /// cover multi-step workflows while keeping costs reasonable.
    private static let maxCloudModelMCPTools = 20

    /// Convert internal tool definitions to protocol-level `LLMToolDefinition`
    /// objects for native function calling via `ChatOptions.tools`.
    ///
    /// When there are many MCP tools, applies the same semantic + keyword
    /// selection used for local models (but with a higher limit) to avoid
    /// sending 200+ tool schemas on every API call.
    ///
    /// - Parameters:
    ///   - enabledTools: Set of tool names that are enabled.
    ///   - mcpServers: Active MCP server configurations.
    ///   - userMessage: Current user message for relevance-based tool selection.
    @MainActor
    static func llmToolDefinitions(
        for enabledTools: Set<String>,
        mcpServers: [MCPServerAccount] = [],
        userMessage: String = ""
    ) async -> [LLMToolDefinition] {
        // Native tools are always included in full (small fixed set).
        let nativeDefs = toolDefinitions.filter { enabledTools.contains($0.name) }

        // MCP tools: select the most relevant subset to avoid token waste.
        let allMCPDefs = mcpToolDefinitions(from: mcpServers)
            .filter { enabledTools.contains($0.name) }
        let selectedMCPDefs: [ToolDefinition] = if allMCPDefs.count > maxCloudModelMCPTools {
            // Too many MCP tools — select the most relevant using the same
            // semantic + keyword hybrid used for local models.
            await selectRelevantMCPTools(
                userMessage: userMessage,
                allMCPTools: allMCPDefs,
                limit: maxCloudModelMCPTools
            )
        } else {
            // Few enough to include all.
            allMCPDefs
        }

        return (nativeDefs + selectedMCPDefs)
            .map { def in
                LLMToolDefinition(
                    name: def.name,
                    description: def.description,
                    parameters: def.parameters.map { param in
                        LLMToolParameter(
                            name: param.name,
                            type: param.type,
                            description: param.description,
                            required: param.required
                        )
                    },
                    inputExamples: def.inputExamples.map { ex in
                        LLMToolInputExample(
                            description: ex.description,
                            input: ex.input
                        )
                    }
                )
            }
    }
}
