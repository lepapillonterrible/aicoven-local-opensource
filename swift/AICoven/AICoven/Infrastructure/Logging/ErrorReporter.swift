import Foundation
import os.log

/// Simple error reporting abstraction so services can log failures in a
/// consistent way without depending directly on `print`.
/// Marked Sendable since logging should be safe from any context.
/// All methods are nonisolated to allow calling from any actor context.
protocol ErrorReporter: Sendable {
    nonisolated func log(error: Error, context: String)
    nonisolated func log(message: String, context: String)
}

/// Default implementation that logs to the console using os.log for thread safety.
/// This keeps behavior close to the existing logging while making it easy to
/// swap in a different reporter (e.g. tests, analytics) later.
struct ConsoleErrorReporter: ErrorReporter {
    private let logger = Logger(subsystem: "dev.aicoven.app", category: "errors")

    nonisolated func log(error: Error, context: String) {
        let safeContext = AppLogRedactor.redact(context)
        let safeMessage = AppLogRedactor.redact(error.localizedDescription)
        logger.error("⚠️ [\(safeContext, privacy: .public)] \(safeMessage, privacy: .public)")
    }

    nonisolated func log(message: String, context: String) {
        let safeContext = AppLogRedactor.redact(context)
        let safeMessage = AppLogRedactor.redact(message)
        logger.info("ℹ️ [\(safeContext, privacy: .public)] \(safeMessage, privacy: .public)")
    }
}

/// Global access point for error reporting. Code should prefer calling
/// `AppErrorReporter.log(...)` instead of `print` when dealing with
/// unexpected failures.
///
/// These methods are nonisolated and can be called from any actor context.
/// They use thread-safe os.log internally.
enum AppErrorReporter {
    /// The active reporter. Uses `nonisolated(unsafe)` because swapping only
    /// happens during test setUp/tearDown on the MainActor, before any
    /// concurrent access begins.
    private nonisolated(unsafe) static var reporter: ErrorReporter = ConsoleErrorReporter()

    /// Replace the active reporter. Only call during app setup or test
    /// setUp/tearDown before any concurrent access.
    nonisolated static func use(_ newReporter: some ErrorReporter) {
        reporter = newReporter
    }

    /// Log an error. Safe to call from any actor or thread.
    nonisolated static func log(error: Error, context: String) {
        let redactedError = RedactedLoggedError(redactedDescription: AppLogRedactor.redact(error.localizedDescription))
        reporter.log(error: redactedError, context: AppLogRedactor.redact(context))
    }

    /// Log an informational message. Safe to call from any actor or thread.
    nonisolated static func log(message: String, context: String) {
        reporter.log(message: AppLogRedactor.redact(message), context: AppLogRedactor.redact(context))
    }
}
