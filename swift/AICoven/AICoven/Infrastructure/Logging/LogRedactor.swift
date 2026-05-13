import Foundation

/// Redacts high-risk secrets and identifiers before they reach console logs,
/// analytics breadcrumbs, or test reporters.
enum AppLogRedactor {
    private static let redaction = "<redacted>"

    /// Return a copy of `message` with sensitive values replaced by a stable
    /// placeholder. Keep this conservative and deterministic so it is safe to
    /// use from any logging path.
    static func redact(_ message: String) -> String {
        var redacted = message

        let patterns = [
            // Provider/API tokens and bearer credentials.
            #"(?i)(authorization\s*[:=]\s*bearer\s+)[A-Za-z0-9._\-+/=]{8,}"#,
            #"(?i)((api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|secret|password)\s*[:=]\s*)[^\s,;\]\}\)]+"#,
            #"\b(sk|pk|rk|xox[baprs]|gh[pousr])_[A-Za-z0-9_\-]{12,}\b"#,
            #"\bAIza[0-9A-Za-z_\-]{20,}\b"#,

            // Email addresses and long opaque IDs commonly found in auth/log output.
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"(?i)\b(user(uid|id)?|uid|thread(id)?|account(id)?)\s*[:=]\s*['"]?[A-Za-z0-9._\-]{12,}['"]?"#,
            #"\b[A-Fa-f0-9]{32,}\b"#
        ]

        for pattern in patterns {
            redacted = replace(pattern: pattern, in: redacted)
        }

        return redacted
    }

    private static func replace(pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: redaction)
    }
}

/// Error wrapper used by AppErrorReporter after redaction.
struct RedactedLoggedError: LocalizedError, CustomStringConvertible {
    let redactedDescription: String

    var errorDescription: String? { redactedDescription }
    var description: String { redactedDescription }
}
