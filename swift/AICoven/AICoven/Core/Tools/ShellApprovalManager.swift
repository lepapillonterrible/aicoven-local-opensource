import Foundation
import SwiftUI
internal import Combine

/// Actor responsible for managing shell command approvals.
/// It bridges the gap between the background ShellToolService and the UI.
@MainActor
class ShellApprovalManager: ObservableObject {
    static let shared = ShellApprovalManager()

    // MARK: - Published State

    /// The current approval request specific to an agent/thread.
    /// In a multi-window app, we might need a more complex mapping (e.g., [ThreadID: Request]),
    /// but for now we assume a single active focus or modal overlay.
    @Published var currentRequest: ShellApprovalRequest?

    /// Whether an approval is currently pending.
    var isApprovalPending: Bool {
        currentRequest != nil
    }

    // MARK: - Internal State

    /// Pending continuations keyed by request ID.
    /// Stored separately from ShellApprovalRequest to prevent UI handlers from
    /// accidentally resuming the continuation directly (which would cause a crash
    /// if handleDecision is also called).
    private var pendingContinuations: [UUID: CheckedContinuation<ShellApprovalDecision, Never>] = [:]

    /// Built-in patterns that are always auto-approved (read-only operations).
    /// These are not persisted — they are always present.
    private let builtInAutoApprovePatterns: [String] = [
        "^ls\\b",
        "^cat\\b",
        "^head\\b",
        "^tail\\b",
        "^wc\\b",
        "^grep\\b",
        "^find\\b",
        "^pwd$",
        "^whoami$",
        "^date$",
        "^echo\\b",
        "^git status",
        "^git log",
        "^git diff",
        "^git branch",
        "^git remote -v",
        "^which\\b",
        "^type\\b",
        "^file\\b",
        "^stat\\b",
        "^du\\b",
        "^df\\b"
    ]

    /// Persistence key for user-added "always allow" patterns.
    private let autoApproveKey = "ShellAutoApprovePatterns"

    /// User-added auto-approve patterns (persisted to UserDefaults).
    private var userAutoApprovePatterns: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: autoApproveKey) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoApproveKey)
        }
    }

    /// All active auto-approve patterns (built-in + user-added).
    private var allAutoApprovePatterns: [String] {
        builtInAutoApprovePatterns + userAutoApprovePatterns
    }

    private init() {}

    // MARK: - Public API

    /// Request approval for a shell command.
    /// This method suspends until the user makes a decision via the approval UI.
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - directory: The directory it will run in.
    ///   - riskLevel: The assessed risk level.
    /// - Returns: The user's decision (approve or deny).
    func requestApproval(
        command: String,
        directory: String,
        riskLevel: ShellCommandRiskLevel
    ) async -> ShellApprovalDecision {

        // 1. Check auto-approve patterns first (only for low-risk commands).
        // Medium/high risk commands always require explicit approval, even if
        // they match a pattern (e.g., "echo test > file" matches ^echo\b but
        // the redirect makes it medium risk).
        if riskLevel == .low, isAutoApproved(command) {
            return .approve
        }

        // 2. Create a continuation to bridge async -> callback
        return await withCheckedContinuation { continuation in
            // Create the request object (continuation stored separately for safety)
            let requestId = UUID()
            let request = ShellApprovalRequest(
                id: requestId,
                command: command,
                workingDir: directory,
                riskLevel: riskLevel,
                metadata: [:]
            )

            // Store continuation separately to prevent accidental double-resume
            self.pendingContinuations[requestId] = continuation

            // Update state to trigger UI
            self.currentRequest = request
        }
    }

    /// Handle the user's decision from the UI.
    func handleDecision(_ decision: ShellApprovalDecision) {
        guard let request = currentRequest else { return }

        // If "always allow" was selected, save the pattern
        if case let .approveAlways(pattern) = decision {
            addAutoApprovePattern(pattern)
        }

        // Clear the request first to prevent duplicate calls
        currentRequest = nil

        // Resume the continuation (remove from dictionary to ensure single-resume)
        if let continuation = pendingContinuations.removeValue(forKey: request.id) {
            continuation.resume(returning: decision)
        }
    }

    // MARK: - Auto-Approve Logic

    private func isAutoApproved(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in allAutoApprovePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
                return true
            }
        }
        return false
    }

    private func addAutoApprovePattern(_ pattern: String) {
        var current = userAutoApprovePatterns
        // Don't add if it already exists in built-in or user patterns
        if !builtInAutoApprovePatterns.contains(pattern), !current.contains(pattern) {
            current.append(pattern)
            userAutoApprovePatterns = current
        }
    }

    /// Get all auto-approve patterns (built-in + user-added).
    func getAutoApprovePatterns() -> [String] {
        allAutoApprovePatterns
    }

    /// Remove a user-added auto-approve pattern.
    func removeAutoApprovePattern(_ pattern: String) {
        var current = userAutoApprovePatterns
        current.removeAll { $0 == pattern }
        userAutoApprovePatterns = current
    }
}

// Note: ShellApprovalRequest and ShellApprovalDecision are defined in ShellToolService.swift
