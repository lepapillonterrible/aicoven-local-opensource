import Foundation

// MARK: - Tool Execution Result

/// Standardized result from tool execution, matching the backend schema.
/// Can represent success, errors, or in-progress states.
/// Named ToolExecutionResult to avoid conflict with ToolResult in ChatMessageModels.
/// Conforms to Sendable since all properties are value types or Sendable enums.
struct ToolExecutionResult: Codable, Sendable {
    /// The tool that was executed
    let tool: String
    /// Status of the execution: "ok", "error", "denied", "timeout"
    let status: String
    /// Structured result data on success
    let result: [String: AnyJSONValue]?
    /// Error message on failure
    let error: String?
    /// Human-readable error type for categorization
    let errorType: String?
    /// Context block to feed back into the LLM context sandwich
    let contextBlock: String?
    /// Whether the agent can retry with different parameters
    let isRetryable: Bool
    /// Helpful instructions for the user (e.g., how to enable a tool)
    let helpfulInstructions: String?
    /// The specific field that caused an error (for validation errors)
    let field: String?
    /// Suggested fix for validation errors
    let suggestion: String?

    init(
        tool: String,
        status: String,
        result: [String: AnyJSONValue]? = nil,
        error: String? = nil,
        errorType: String? = nil,
        contextBlock: String? = nil,
        isRetryable: Bool = false,
        helpfulInstructions: String? = nil,
        field: String? = nil,
        suggestion: String? = nil
    ) {
        self.tool = tool
        self.status = status
        self.result = result
        self.error = error
        self.errorType = errorType
        self.contextBlock = contextBlock
        self.isRetryable = isRetryable
        self.helpfulInstructions = helpfulInstructions
        self.field = field
        self.suggestion = suggestion
    }

    // MARK: - Convenience Initializers

    /// Create a successful result with optional context block for the LLM.
    static func success(
        tool: String,
        result: [String: AnyJSONValue] = [:],
        contextBlock: String? = nil
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            tool: tool,
            status: "ok",
            result: result,
            contextBlock: contextBlock
        )
    }

    /// Create an error result.
    static func error(
        tool: String,
        message: String,
        errorType: String = "execution_failed",
        isRetryable: Bool = false,
        helpfulInstructions: String? = nil
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            tool: tool,
            status: "error",
            error: message,
            errorType: errorType,
            isRetryable: isRetryable,
            helpfulInstructions: helpfulInstructions
        )
    }

    /// Create a validation error result (agent can fix parameters).
    static func validationError(
        tool: String,
        message: String,
        field: String? = nil,
        suggestion: String? = nil
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            tool: tool,
            status: "error",
            error: message,
            errorType: "invalid_parameters",
            isRetryable: true,
            field: field,
            suggestion: suggestion
        )
    }

    /// Create a permission denied result.
    static func permissionDenied(
        tool: String,
        message: String,
        helpfulInstructions: String? = nil
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            tool: tool,
            status: "denied",
            error: message,
            errorType: "permission_denied",
            isRetryable: false,
            helpfulInstructions: helpfulInstructions
        )
    }

    /// Create a denied result (user declined approval).
    static func denied(tool: String, reason: String = "User denied execution") -> ToolExecutionResult {
        ToolExecutionResult(
            tool: tool,
            status: "denied",
            error: reason,
            errorType: "user_denied"
        )
    }

    /// Create a timeout result.
    static func timeout(tool: String, timeoutSeconds: Int) -> ToolExecutionResult {
        ToolExecutionResult(
            tool: tool,
            status: "timeout",
            error: "Tool execution timed out after \(timeoutSeconds) seconds",
            errorType: "timeout",
            isRetryable: true
        )
    }
}

// MARK: - Tool Error Types

/// Error types for tool execution, matching backend categorization.
/// Conforms to Sendable since it's a simple enum with Sendable raw values.
enum ToolErrorType: String, Codable, Sendable {
    /// Invalid or malformed parameters - agent can retry with different args
    case invalidParameters = "invalid_parameters"
    /// Tool not enabled or not allowed for this role
    case permissionDenied = "permission_denied"
    /// Tool execution failed (network, provider error, etc.)
    case executionFailed = "execution_failed"
    /// User denied the operation (e.g., shell command approval)
    case userDenied = "user_denied"
    /// Operation timed out
    case timeout
    /// Unknown or unexpected error
    case unknown
}

// MARK: - Tool Execution Error

/// Error thrown during tool execution with structured information.
/// Conforms to Sendable since all properties are Sendable value types.
struct ToolExecutionError: Error, LocalizedError, Sendable {
    let type: ToolErrorType
    let message: String
    let tool: String?
    let field: String?
    let suggestion: String?
    let helpfulInstructions: String?
    let isRetryable: Bool

    init(
        type: ToolErrorType,
        message: String,
        tool: String? = nil,
        field: String? = nil,
        suggestion: String? = nil,
        helpfulInstructions: String? = nil,
        isRetryable: Bool? = nil
    ) {
        self.type = type
        self.message = message
        self.tool = tool
        self.field = field
        self.suggestion = suggestion
        self.helpfulInstructions = helpfulInstructions
        // Default retryability based on error type
        self.isRetryable = isRetryable ?? (type == .invalidParameters || type == .timeout)
    }

    var errorDescription: String? {
        message
    }

    /// Convert to a ToolExecutionResult for returning to the agent.
    func toResult() -> ToolExecutionResult {
        let status = switch type {
        case .permissionDenied, .userDenied:
            "denied"
        case .timeout:
            "timeout"
        default:
            "error"
        }

        return ToolExecutionResult(
            tool: tool ?? "unknown",
            status: status,
            error: message,
            errorType: type.rawValue,
            isRetryable: isRetryable,
            helpfulInstructions: helpfulInstructions,
            field: field,
            suggestion: suggestion
        )
    }
}

// MARK: - Shell Command Risk Level

/// Risk level for shell commands, used for approval UI.
/// Conforms to Sendable since it's a simple enum with Sendable raw values.
enum ShellCommandRiskLevel: String, Codable, Sendable {
    /// Read-only operations (ls, cat, git status)
    case low
    /// Write operations (npm install, git commit)
    case medium
    /// Dangerous operations (rm -rf, sudo, system modifications)
    case high

    /// Determine risk level from a shell command string.
    static func assess(command: String) -> ShellCommandRiskLevel {
        let lowercased = command.lowercased()

        // High-risk patterns
        let highRiskPatterns = [
            "rm -rf /",
            "rm -rf ~",
            "sudo ",
            "mkfs",
            "dd if=",
            ":(){:|:&};:", // Fork bomb
            "chmod 777 /",
            "> /dev/sda",
            "mv /* ",
            "rm -rf *"
        ]

        for pattern in highRiskPatterns {
            if lowercased.contains(pattern) {
                return .high
            }
        }

        // Medium-risk: write operations
        let mediumRiskPatterns = [
            "rm ",
            "mv ",
            "cp ",
            "chmod ",
            "chown ",
            "git commit",
            "git push",
            "git merge",
            "npm install",
            "npm run",
            "yarn ",
            "pip install",
            "brew install",
            "make ",
            "touch ",
            "mkdir ",
            "echo ",
            "> ", // Redirect (can overwrite files)
            ">> "
        ]

        for pattern in mediumRiskPatterns {
            if lowercased.contains(pattern) {
                return .medium
            }
        }

        // Default to low risk for read-only operations
        return .low
    }
}
