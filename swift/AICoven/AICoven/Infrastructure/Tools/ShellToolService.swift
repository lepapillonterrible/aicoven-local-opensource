import Foundation

/// Pending shell command approval request.
/// Note: The continuation is managed internally by ShellApprovalManager to prevent
/// accidental double-resume from UI handlers.
struct ShellApprovalRequest: Identifiable {
    let id: UUID
    let command: String
    let workingDir: String?
    let riskLevel: ShellCommandRiskLevel
    let metadata: [String: String]
}

/// User's decision on a shell command approval request.
enum ShellApprovalDecision {
    case approve
    case approveAlways(pattern: String)
    case deny(reason: String)
}

/// Provides shell command execution for the agent with safety controls.
/// Commands require user approval unless they match auto-approve patterns.
actor ShellToolService {

    /// Shared singleton instance.
    static let shared = ShellToolService()

    /// Commands that are always blocked regardless of approval.
    private let blockedPatterns: [String] = [
        "rm -rf /",
        "rm -rf ~",
        "rm -rf /*",
        "sudo rm -rf",
        "mkfs",
        "dd if=",
        ":(){:|:&};:", // Fork bomb
        "chmod 777 /",
        "> /dev/sda",
        "mv /* ",
        ":(){ :|:& };:"
    ]

    /// Maximum command execution timeout in seconds.
    private let defaultTimeoutSeconds: Int = 60

    /// Maximum output size in bytes.
    private let maxOutputSize: Int = 10 * 1024 * 1024 // 10MB

    // MARK: - Execute Command

    /// Execute a shell command with safety controls.
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - workingDir: Optional working directory.
    ///   - env: Optional environment variables.
    ///   - timeoutSeconds: Execution timeout.
    ///   - metadata: Additional metadata for the approval UI.
    /// - Returns: ToolResult with command output or error.
    func execute(
        command: String,
        workingDir: String? = nil,
        env: [String: String]? = nil,
        timeoutSeconds: Int? = nil,
        metadata: [String: String] = [:]
    ) async -> ToolExecutionResult {
        let timeout = timeoutSeconds ?? defaultTimeoutSeconds

        guard let normalizedWorkingDir = normalizeWorkingDirectory(workingDir), !normalizedWorkingDir.isEmpty else {
            return await .permissionDenied(
                tool: "shell.execute",
                message: "Shell commands must include an explicit working directory.",
                helpfulInstructions: "Choose a user-authorized project folder and retry with workingDir set."
            )
        }

        let directoryAccessible = await MainActor.run {
            FileAccessManager.shared.isPathAccessible(normalizedWorkingDir)
        }
        guard directoryAccessible else {
            return await .permissionDenied(
                tool: "shell.execute",
                message: "Shell working directory '\(normalizedWorkingDir)' is not authorized.",
                helpfulInstructions: "Grant access in Settings > File Access before running shell commands there."
            )
        }

        // Check if command is blocked
        if isCommandBlocked(command) {
            return await .permissionDenied(
                tool: "shell.execute",
                message: "This command is blocked for safety reasons: \(command)",
                helpfulInstructions: "Commands that could cause system damage are not allowed. Try a safer alternative."
            )
        }

        // Assess risk level
        let riskLevel = ShellCommandRiskLevel.assess(command: command)

        // Request approval via ShellApprovalManager (single source of truth).
        // The manager auto-approves low-risk commands matching known patterns,
        // and always prompts for medium/high risk commands.
        let decision = await requestApproval(
            command: command,
            workingDir: normalizedWorkingDir,
            riskLevel: riskLevel,
            metadata: metadata
        )

        switch decision {
        case .approve, .approveAlways:
            break // Continue to execution
        case let .deny(reason):
            return await .denied(tool: "shell.execute", reason: reason)
        }

        // Execute the command
        return await executeCommand(
            command: command,
            workingDir: normalizedWorkingDir,
            env: env,
            timeoutSeconds: timeout
        )
    }

    // MARK: - Private Methods

    /// Check if a command matches a blocked pattern.
    private func isCommandBlocked(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        for pattern in blockedPatterns {
            if lowercased.contains(pattern.lowercased()) {
                return true
            }
        }
        return false
    }

    /// Normalize and resolve the shell working directory before authorization.
    private func normalizeWorkingDirectory(_ workingDir: String?) -> String? {
        guard let workingDir, !workingDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let expanded = (workingDir as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Request user approval for a command.
    private func requestApproval(
        command: String,
        workingDir: String?,
        riskLevel: ShellCommandRiskLevel,
        metadata: [String: String]
    ) async -> ShellApprovalDecision {
        // Use the ShellApprovalManager actor
        await ShellApprovalManager.shared.requestApproval(
            command: command,
            directory: workingDir ?? "current directory",
            riskLevel: riskLevel
        )
    }

    /// Execute the actual command using Process.
    private func executeCommand(
        command: String,
        workingDir: String?,
        env: [String: String]?,
        timeoutSeconds: Int
    ) async -> ToolExecutionResult {
        #if os(macOS)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Use zsh as the default shell on macOS
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set working directory
        if let workingDir {
            let expandedPath = (workingDir as NSString).expandingTildeInPath
            process.currentDirectoryURL = URL(fileURLWithPath: expandedPath)
        }

        // Set environment variables
        var environment = ProcessInfo.processInfo.environment
        if let env {
            for (key, value) in env {
                environment[key] = value
            }
        }
        process.environment = environment

        let startTime = Date()

        // Use async-safe termination handler instead of blocking waitUntilExit()
        // This prevents hanging the actor if the child process ignores SIGTERM.
        // IMPORTANT: The termination handler is set BEFORE process.run() so that
        // fast-exiting commands are always caught by the handler.
        let result: Result<Bool, Error> = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Bool, Error>, Never>) in
            var hasResumed = false
            let lock = NSLock()

            // Set up termination handler BEFORE starting the process
            process.terminationHandler = { (_: Process) in
                lock.lock()
                defer { lock.unlock() }
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: .success(false))
                }
            }

            // Start the process
            do {
                try process.run()
            } catch {
                lock.lock()
                defer { lock.unlock() }
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: .failure(error))
                }
                return
            }

            // Set up timeout task with SIGTERM then SIGKILL fallback
            Task {
                do {
                    // Wait for the timeout period
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)

                    // If process is still running, try graceful termination first
                    if process.isRunning {
                        process.terminate() // SIGTERM

                        // Give the process 2 seconds to respond to SIGTERM
                        try await Task.sleep(nanoseconds: 2_000_000_000)

                        // If still running, force kill with SIGKILL
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }

                    // Resume with timeout flag if we haven't already
                    lock.lock()
                    defer { lock.unlock() }
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: .success(true))
                    }
                } catch {
                    // Task was cancelled (process completed before timeout)
                    // Do nothing - termination handler will resume
                }
            }
        }

        // Handle launch failure
        switch result {
        case let .failure(error):
            return await .error(
                tool: "shell.execute",
                message: "Failed to start command: \(error.localizedDescription)",
                errorType: "execution_failed"
            )
        case .success:
            break
        }

        let didTimeout: Bool = if case let .success(timedOut) = result {
            timedOut
        } else {
            false // unreachable due to early return above, but satisfies the compiler
        }

        let executionTime = Date().timeIntervalSince(startTime)
        let exitCode = process.terminationStatus

        // Check if timed out
        if didTimeout {
            return await .timeout(tool: "shell.execute", timeoutSeconds: timeoutSeconds)
        }

        // Read output
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        var stdout = if stdoutData.count > maxOutputSize {
            String(decoding: stdoutData.prefix(maxOutputSize), as: UTF8.self) + "\n... [output truncated]"
        } else {
            String(decoding: stdoutData, as: UTF8.self)
        }

        var stderr = if stderrData.count > maxOutputSize {
            String(decoding: stderrData.prefix(maxOutputSize), as: UTF8.self) + "\n... [output truncated]"
        } else {
            String(decoding: stderrData, as: UTF8.self)
        }

        // Build context block
        var contextLines: [String] = []
        contextLines.append("[Shell command executed]")
        contextLines.append("$ \(command)")
        if !stdout.isEmpty {
            contextLines.append("stdout:")
            contextLines.append(stdout)
        }
        if !stderr.isEmpty {
            contextLines.append("stderr:")
            contextLines.append(stderr)
        }
        contextLines.append("exit_code: \(exitCode)")
        contextLines.append("execution_time: \(String(format: "%.2f", executionTime))s")

        let contextBlock = contextLines.joined(separator: "\n")

        if exitCode == 0 {
            return await .success(
                tool: "shell.execute",
                result: [
                    "exit_code": AnyJSONValue(Int(exitCode)),
                    "stdout": AnyJSONValue(stdout),
                    "stderr": AnyJSONValue(stderr),
                    "execution_time_ms": AnyJSONValue(Int(executionTime * 1000))
                ],
                contextBlock: contextBlock
            )
        } else {
            // Non-zero exit code is an error
            return ToolExecutionResult(
                tool: "shell.execute",
                status: "error",
                result: [
                    "exit_code": AnyJSONValue(Int(exitCode)),
                    "stdout": AnyJSONValue(stdout),
                    "stderr": AnyJSONValue(stderr),
                    "execution_time_ms": AnyJSONValue(Int(executionTime * 1000))
                ],
                error: "Command exited with code \(exitCode)",
                errorType: "execution_failed",
                contextBlock: contextBlock
            )
        }
        #else
        // Shell execution is not available on iOS
        return await .error(
            tool: "shell.execute",
            message: "Shell command execution is only available on macOS.",
            errorType: "platform_unsupported"
        )
        #endif
    }

    init() {}
}
