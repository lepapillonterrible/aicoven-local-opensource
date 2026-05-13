import Foundation

/// Validation helpers for user-supplied thread fields.
enum ThreadInputValidator {
    static let maxTitleLength = 120

    /// Normalize a thread title for single-line display and persistence.
    /// Empty or whitespace-only values resolve to `defaultTitle`.
    static func normalizedTitle(_ title: String?, defaultTitle: String) -> String {
        guard let title else { return defaultTitle }

        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsed.isEmpty else { return defaultTitle }

        if collapsed.count <= maxTitleLength {
            return collapsed
        }

        return String(collapsed.prefix(maxTitleLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
