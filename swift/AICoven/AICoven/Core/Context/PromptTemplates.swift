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
            example: #"{"tool": "web_search", "input": {"query": "latest Swift concurrency features"}, "reason": "Need to find current documentation"}"#
        ),
        ToolDefinition(
            name: "web_browse",
            description: "Read the content of a specific webpage URL.",
            parameters: [
                ToolParameter(name: "url", type: "string", description: "The URL to visit", required: true)
            ],
            example: #"{"tool": "web_browse", "input": {"url": "https://example.com"}, "reason": "Read page content"}"#
        ),
        ToolDefinition(
            name: "current_time",
            description: "Get the current date and time. Optionally specify a timezone identifier (e.g. 'Europe/London', 'America/New_York', 'Asia/Tokyo') to get the time in that timezone.",
            parameters: [
                ToolParameter(name: "timezone", type: "string", description: "IANA timezone identifier, e.g. 'Europe/London'. Defaults to the user's local timezone if omitted.", required: false)
            ],
            example: #"{"tool": "current_time", "input": {"timezone": "Europe/London"}, "reason": "Need to know current time in London"}"#
        ),
        
        // File tools
        ToolDefinition(
            name: "file.read",
            description: "Read the contents of a local file.",
            parameters: [
                ToolParameter(name: "path", type: "string", description: "Absolute path to the file", required: true)
            ],
            example: #"{"tool": "file.read", "input": {"path": "/Users/me/document.txt"}, "reason": "Need to read file contents"}"#
        ),
        ToolDefinition(
            name: "file.write",
            description: "Write content to a local file. Creates the file if it doesn't exist.",
            parameters: [
                ToolParameter(name: "path", type: "string", description: "Absolute path for the file", required: true),
                ToolParameter(name: "content", type: "string", description: "Content to write", required: true)
            ],
            example: #"{"tool": "file.write", "input": {"path": "/Users/me/output.txt", "content": "Hello World"}, "reason": "Save results to file"}"#
        ),
        ToolDefinition(
            name: "file.list",
            description: "List files and directories at a given path.",
            parameters: [
                ToolParameter(name: "path", type: "string", description: "Directory path to list", required: true),
                ToolParameter(name: "recursive", type: "boolean", description: "Whether to list recursively", required: false)
            ],
            example: #"{"tool": "file.list", "input": {"path": "/Users/me/Documents", "recursive": false}, "reason": "Explore directory"}"#
        ),
        
        // Shell tools
        ToolDefinition(
            name: "shell.execute",
            description: "Execute a shell command on the local system. Requires user approval for safety.",
            parameters: [
                ToolParameter(name: "command", type: "string", description: "Shell command to execute", required: true)
            ],
            example: #"{"tool": "shell.execute", "input": {"command": "ls -la"}, "reason": "List directory with details"}"#
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
            example: #"{"tool": "github.readFile", "input": {"owner": "user", "repo": "project", "path": "README.md"}, "reason": "Read documentation"}"#
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

    When you need information you don't have (current time, file contents, web data), you MUST respond with ONLY a JSON object. Do NOT write any other text before or after the JSON.

    JSON FORMAT:
    {"tool": "tool_name", "input": {"param": "value"}, "reason": "brief reason"}

    EXAMPLES OF CORRECT BEHAVIOR:

    User: What time is it in London?
    Correct response: {"tool": "current_time", "input": {"timezone": "Europe/London"}, "reason": "Get London time"}

    User: List files in /Users/me/Documents
    Correct response: {"tool": "file.list", "input": {"path": "/Users/me/Documents"}, "reason": "List directory contents"}

    User: Read the file at /Users/me/readme.txt
    Correct response: {"tool": "file.read", "input": {"path": "/Users/me/readme.txt"}, "reason": "Read file contents"}

    User: Search the web for Swift concurrency
    Correct response: {"tool": "web_search", "input": {"query": "Swift concurrency"}, "reason": "Search for information"}

    User: What is 2+2?
    Correct response: 2+2 = 4 (no tool needed, answer directly)

    RULES:
    - If the user asks about time, dates, or schedules → use current_time tool
    - If the user mentions a file path or directory → use file.read or file.list tool
    - If the user asks to search or look up something online → use web_search tool
    - Call ONE tool at a time, wait for the result
    - After receiving a tool result, answer the user's question using that data
    """
    
    /// Generate a lean system prompt for MLX models with only essential sections.
    static func generateMLXAgentPrompt(enabledTools: Set<String>) -> String {
        var sections: [String] = []
        
        // Brief role description
        sections.append("You are a helpful AI assistant running locally. You have tools to help you answer questions that need real-time or external data.")
        
        // Tool documentation — only enabled tools
        let enabledDefs = toolDefinitions.filter { enabledTools.contains($0.name) }
        if !enabledDefs.isEmpty {
            sections.append(generateToolDocumentation(for: enabledDefs))
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
    ///   - includeThoughtBlocks: Whether to include thought block instructions.
    ///   - includeScratchpad: Whether to include scratchpad instructions.
    ///   - includeMemoryWrite: Whether to include memory write instructions.
    /// - Returns: Complete system prompt string.
    static func generateAgentPrompt(
        enabledTools: Set<String>,
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
            let enabledDefs = toolDefinitions.filter { enabledTools.contains($0.name) }
            if !enabledDefs.isEmpty {
                sections.append(generateToolDocumentation(for: enabledDefs))
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
    private static func generateToolDocumentation(for tools: [ToolDefinition]) -> String {
        var lines: [String] = ["AVAILABLE TOOLS:"]
        
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
    static let allTools: Set<String> = {
        basicChatTools
            .union(fileTools)
            .union(shellTools)
            .union(githubTools)
            .union(googleDriveTools)
    }()
}

// MARK: - Supporting Types

/// Definition of a tool including its parameters and usage example.
/// Conforms to Sendable since all properties are value types.
struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [ToolParameter]
    let example: String
}

/// Parameter definition for a tool.
/// Conforms to Sendable since all properties are value types.
struct ToolParameter: Sendable {
    let name: String
    let type: String
    let description: String
    let required: Bool
}
