import Foundation

/// Service for validating tool arguments.
/// Ensures required fields are present and of correct types.
enum ToolValidationService {

    /// Validates required string arguments.
    /// - Returns: ToolExecutionResult with error if validation fails, nil otherwise.
    static func validateRequiredString(
        args: [String: AnyJSONValue],
        key: String,
        tool: String
    ) -> ToolExecutionResult? {
        // Check presence
        guard let valueWrapper = args[key] else {
            return .validationError(
                tool: tool,
                message: "Missing required argument: '\(key)'",
                field: key,
                suggestion: "Please provide the '\(key)' argument."
            )
        }

        // Check type and content
        guard let stringValue = valueWrapper.value as? String, !stringValue.isEmpty else {
            return .validationError(
                tool: tool,
                message: "Argument '\(key)' must be a non-empty string.",
                field: key,
                suggestion: "Ensure '\(key)' is a string value."
            )
        }

        return nil
    }

    /// Validates required boolean arguments.
    static func validateRequiredBool(
        args: [String: AnyJSONValue],
        key: String,
        tool: String
    ) -> ToolExecutionResult? {
        guard let valueWrapper = args[key], let _ = valueWrapper.value as? Bool else {
            return .validationError(
                tool: tool,
                message: "Missing or invalid boolean argument: '\(key)'",
                field: key
            )
        }
        return nil
    }
}
