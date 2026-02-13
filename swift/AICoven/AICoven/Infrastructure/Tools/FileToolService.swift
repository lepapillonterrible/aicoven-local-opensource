import Foundation

/// Provides local file system operations for the agent.
/// Security model: Operations are restricted via a blocklist of sensitive
/// system and user directories. This prevents access to credentials, keys,
/// and system files while allowing access to typical user workspace folders
/// like ~/Documents, ~/Desktop, and project directories.
actor FileToolService {

    /// Shared singleton instance.
    static let shared = FileToolService()

    /// System directories that are always blocked from access.
    private let blockedSystemPaths: [String] = [
        "/System",
        "/Library",
        "/usr",
        "/bin",
        "/sbin",
        "/private",
        "/etc",
        "/var",
        "/.Trash"
    ]

    /// Sensitive user directories that are blocked from access.
    /// These paths are relative to the user's home directory.
    private let blockedUserPaths: [String] = [
        ".ssh", // SSH keys and config
        ".gnupg", // GPG keys
        ".aws", // AWS credentials
        ".azure", // Azure credentials
        ".gcloud", // Google Cloud credentials
        ".config/gcloud", // Google Cloud config
        ".kube", // Kubernetes config and tokens
        ".docker", // Docker config and credentials
        ".npm", // NPM tokens
        ".netrc", // Network credentials
        ".git-credentials", // Git credentials
        ".gitconfig", // Git config (may contain tokens)
        "Library", // macOS user Library (Keychains, etc.)
        ".Trash", // User trash
        ".local/share/keyrings", // Linux keyrings
        ".password-store", // Pass password manager
        ".gnome-keyring", // GNOME keyring
        // Browser profiles (may contain saved passwords, cookies, tokens)
        "Library/Application Support/Google/Chrome",
        "Library/Application Support/Firefox",
        "Library/Application Support/Microsoft Edge",
        "Library/Safari",
        ".config/google-chrome",
        ".mozilla/firefox",
        ".config/chromium",
        // Other sensitive locations
        ".env", // Environment files often contain secrets
        ".envrc", // direnv files
        ".secrets"
    ]

    /// Maximum file size to read (10MB).
    private let maxReadSize: Int = 10 * 1024 * 1024

    /// Maximum file size to write (5MB).
    private let maxWriteSize: Int = 5 * 1024 * 1024

    // MARK: - Read File

    /// Read the contents of a file at the given path.
    /// - Parameters:
    ///   - path: Absolute or relative path to the file.
    ///   - workingDir: Optional working directory for relative paths.
    /// - Returns: ToolResult with file content or error.
    func readFile(path: String, workingDir: String? = nil) async -> ToolExecutionResult {
        let resolvedPath = resolvePath(path, workingDir: workingDir)

        // Check folder authorization
        if let denied = await checkFolderAuthorization(resolvedPath, tool: "file.read") {
            return denied
        }

        // Check if path is blocked
        if isPathBlocked(resolvedPath) {
            return .permissionDenied(
                tool: "file.read",
                message: "Access to system directories is not allowed: \(resolvedPath)",
                helpfulInstructions: "File operations are restricted to user directories like ~/Documents, ~/Desktop, or project folders."
            )
        }

        let fileManager = FileManager.default

        // Check if file exists
        guard fileManager.fileExists(atPath: resolvedPath) else {
            return .error(
                tool: "file.read",
                message: "File not found: \(resolvedPath)",
                errorType: "file_not_found",
                isRetryable: false
            )
        }

        // Check if it's a directory
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return .validationError(
                tool: "file.read",
                message: "Path is a directory, not a file: \(resolvedPath)",
                field: "path",
                suggestion: "Use file.list to list directory contents, or specify a file path."
            )
        }

        // Check file size
        do {
            let attributes = try fileManager.attributesOfItem(atPath: resolvedPath)
            if let fileSize = attributes[.size] as? Int, fileSize > maxReadSize {
                return .error(
                    tool: "file.read",
                    message: "File too large (\(fileSize) bytes). Maximum size is \(maxReadSize) bytes.",
                    errorType: "file_too_large"
                )
            }
        } catch {
            // Continue anyway, we'll get an error when reading if there's a problem
        }

        // Read the file
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))

            // Try to decode as UTF-8 text
            if let content = String(data: data, encoding: .utf8) {
                let contextBlock = "[File contents: \(resolvedPath)]\n\(content)"
                return .success(
                    tool: "file.read",
                    result: [
                        "path": AnyJSONValue(resolvedPath),
                        "content": AnyJSONValue(content),
                        "size_bytes": AnyJSONValue(data.count),
                        "encoding": AnyJSONValue("utf-8")
                    ],
                    contextBlock: contextBlock
                )
            } else {
                // Binary file
                return .success(
                    tool: "file.read",
                    result: [
                        "path": AnyJSONValue(resolvedPath),
                        "content": AnyJSONValue("[Binary file, \(data.count) bytes - cannot display as text]"),
                        "size_bytes": AnyJSONValue(data.count),
                        "is_binary": AnyJSONValue(true)
                    ],
                    contextBlock: "[Binary file: \(resolvedPath)] - \(data.count) bytes"
                )
            }
        } catch {
            return .error(
                tool: "file.read",
                message: "Failed to read file: \(error.localizedDescription)",
                errorType: "read_error"
            )
        }
    }

    // MARK: - Write File

    /// Write content to a file at the given path.
    /// - Parameters:
    ///   - path: Absolute or relative path to the file.
    ///   - content: Text content to write.
    ///   - workingDir: Optional working directory for relative paths.
    ///   - createDirectories: Whether to create parent directories if they don't exist.
    /// - Returns: ToolResult indicating success or error.
    func writeFile(
        path: String,
        content: String,
        workingDir: String? = nil,
        createDirectories: Bool = true
    ) async -> ToolExecutionResult {
        let resolvedPath = resolvePath(path, workingDir: workingDir)

        // Check folder authorization
        if let denied = await checkFolderAuthorization(resolvedPath, tool: "file.write") {
            return denied
        }

        // Check if path is blocked
        if isPathBlocked(resolvedPath) {
            return .permissionDenied(
                tool: "file.write",
                message: "Writing to system directories is not allowed: \(resolvedPath)",
                helpfulInstructions: "File operations are restricted to user directories like ~/Documents, ~/Desktop, or project folders."
            )
        }

        // Check content size
        let data = content.data(using: .utf8) ?? Data()
        if data.count > maxWriteSize {
            return .error(
                tool: "file.write",
                message: "Content too large (\(data.count) bytes). Maximum size is \(maxWriteSize) bytes.",
                errorType: "content_too_large"
            )
        }

        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: resolvedPath)

        // Create parent directories if needed
        if createDirectories {
            let parentDir = url.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                return .error(
                    tool: "file.write",
                    message: "Failed to create parent directories: \(error.localizedDescription)",
                    errorType: "directory_error"
                )
            }
        }

        // Write the file
        do {
            try data.write(to: url)
            return .success(
                tool: "file.write",
                result: [
                    "path": AnyJSONValue(resolvedPath),
                    "size_bytes": AnyJSONValue(data.count),
                    "message": AnyJSONValue("File written successfully")
                ],
                contextBlock: "[File written: \(resolvedPath)] - \(data.count) bytes"
            )
        } catch {
            return .error(
                tool: "file.write",
                message: "Failed to write file: \(error.localizedDescription)",
                errorType: "write_error"
            )
        }
    }

    // MARK: - List Files

    /// List files and directories at the given path.
    /// - Parameters:
    ///   - path: Absolute or relative path to list.
    ///   - workingDir: Optional working directory for relative paths.
    ///   - recursive: Whether to list recursively (limited depth).
    ///   - maxItems: Maximum number of items to return.
    /// - Returns: ToolResult with file listing or error.
    func listFiles(
        path: String,
        workingDir: String? = nil,
        recursive: Bool = false,
        maxItems: Int = 100
    ) async -> ToolExecutionResult {
        let resolvedPath = resolvePath(path, workingDir: workingDir)

        // Check folder authorization
        if let denied = await checkFolderAuthorization(resolvedPath, tool: "file.list") {
            return denied
        }

        // Check if path is blocked
        if isPathBlocked(resolvedPath) {
            return .permissionDenied(
                tool: "file.list",
                message: "Access to system directories is not allowed: \(resolvedPath)",
                helpfulInstructions: "File operations are restricted to user directories like ~/Documents, ~/Desktop, or project folders."
            )
        }

        let fileManager = FileManager.default

        // Check if path exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            return .error(
                tool: "file.list",
                message: "Path not found: \(resolvedPath)",
                errorType: "path_not_found"
            )
        }

        guard isDirectory.boolValue else {
            return .validationError(
                tool: "file.list",
                message: "Path is a file, not a directory: \(resolvedPath)",
                field: "path",
                suggestion: "Use file.read to read file contents."
            )
        }

        // List directory contents
        do {
            let url = URL(fileURLWithPath: resolvedPath)
            var items: [[String: AnyJSONValue]] = []

            if recursive {
                // Recursive listing with limited depth
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                var count = 0
                while let itemURL = enumerator?.nextObject() as? URL, count < maxItems {
                    if let item = fileInfoDict(for: itemURL, relativeTo: url) {
                        items.append(item)
                        count += 1
                    }
                    // Limit recursion depth to 3 levels
                    if let level = enumerator?.level, level > 3 {
                        enumerator?.skipDescendants()
                    }
                }
            } else {
                // Non-recursive listing
                let contents = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                for itemURL in contents.prefix(maxItems) {
                    if let item = fileInfoDict(for: itemURL, relativeTo: url) {
                        items.append(item)
                    }
                }
            }

            // Build context block
            let fileList = items.map { item -> String in
                let name = (item["name"]?.value as? String) ?? "?"
                let isDir = (item["is_directory"]?.value as? Bool) ?? false
                let size = item["size_bytes"]?.value as? Int
                if isDir {
                    return "  📁 \(name)/"
                } else if let size {
                    return "  📄 \(name) (\(formatFileSize(size)))"
                } else {
                    return "  📄 \(name)"
                }
            }.joined(separator: "\n")

            let contextBlock = "[Directory listing: \(resolvedPath)]\n\(fileList)"

            return .success(
                tool: "file.list",
                result: [
                    "path": AnyJSONValue(resolvedPath),
                    "items": AnyJSONValue(items.map { dict in
                        Dictionary(uniqueKeysWithValues: dict.map { ($0.key, $0.value.value) })
                    }),
                    "count": AnyJSONValue(items.count),
                    "truncated": AnyJSONValue(items.count >= maxItems)
                ],
                contextBlock: contextBlock
            )
        } catch {
            return .error(
                tool: "file.list",
                message: "Failed to list directory: \(error.localizedDescription)",
                errorType: "list_error"
            )
        }
    }

    // MARK: - Helpers

    /// Resolve a path, expanding ~ and handling relative paths.
    private func resolvePath(_ path: String, workingDir: String?) -> String {
        var resolved = path

        // Expand tilde
        if resolved.hasPrefix("~") {
            resolved = (resolved as NSString).expandingTildeInPath
        }

        // Handle relative paths
        if !resolved.hasPrefix("/") {
            if let workingDir {
                let base = (workingDir as NSString).expandingTildeInPath
                resolved = (base as NSString).appendingPathComponent(resolved)
            } else {
                // Default to current working directory
                resolved = FileManager.default.currentDirectoryPath + "/" + resolved
            }
        }

        // Normalize the path
        let standardPath = (resolved as NSString).standardizingPath

        // Resolve symlinks to ensure we check the actual destination
        let url = URL(fileURLWithPath: standardPath)
        return url.resolvingSymlinksInPath().path
    }

    /// Check if a path is in a blocked directory (system or sensitive user location).
    private func isPathBlocked(_ path: String) -> Bool {
        // Check system paths
        for blockedPath in blockedSystemPaths {
            if isPathUnderBlockedDir(path, blockedDir: blockedPath) {
                return true
            }
        }

        // Check sensitive user paths (relative to home directory)
        #if os(macOS)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        #else
        let homeDir = NSHomeDirectory()
        #endif
        for blockedPath in blockedUserPaths {
            let fullBlockedPath = (homeDir as NSString).appendingPathComponent(blockedPath)
            if isPathUnderBlockedDir(path, blockedDir: fullBlockedPath) {
                return true
            }
        }

        // Also block any path component that looks like a secrets file
        let sensitivePatterns = [".env", ".secrets", "credentials", "secret", ".pem", ".key"]
        let pathComponents = path.lowercased().split(separator: "/")
        for component in pathComponents {
            for pattern in sensitivePatterns {
                if component.hasPrefix(pattern) || component.hasSuffix(pattern) {
                    // Allow if it's clearly part of a project (e.g., .env.example, secrets.md)
                    let componentStr = String(component)
                    if componentStr.hasSuffix(".example") ||
                        componentStr.hasSuffix(".sample") ||
                        componentStr.hasSuffix(".template") ||
                        componentStr.hasSuffix(".md") ||
                        componentStr.hasSuffix(".txt") {
                        continue
                    }
                    return true
                }
            }
        }

        return false
    }

    /// Check if a path is under a blocked directory, enforcing path component boundaries.
    /// This prevents `/usr-local` from matching `/usr` blocklist entry.
    private func isPathUnderBlockedDir(_ path: String, blockedDir: String) -> Bool {
        // Exact match (the path IS the blocked directory)
        if path == blockedDir {
            return true
        }
        // Path is inside the blocked directory (must have a / separator after the blocked dir)
        if path.hasPrefix(blockedDir + "/") {
            return true
        }
        return false
    }

    /// Create a dictionary of file info for a URL.
    private func fileInfoDict(for url: URL, relativeTo baseURL: URL) -> [String: AnyJSONValue]? {
        let fileManager = FileManager.default

        do {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])

            let relativePath = url.path.replacingOccurrences(of: baseURL.path + "/", with: "")

            var info: [String: AnyJSONValue] = [
                "name": AnyJSONValue(url.lastPathComponent),
                "path": AnyJSONValue(relativePath),
                "is_directory": AnyJSONValue(resourceValues.isDirectory ?? false)
            ]

            if let size = resourceValues.fileSize, !(resourceValues.isDirectory ?? false) {
                info["size_bytes"] = AnyJSONValue(size)
            }

            if let modDate = resourceValues.contentModificationDate {
                let formatter = ISO8601DateFormatter()
                info["modified_at"] = AnyJSONValue(formatter.string(from: modDate))
            }

            return info
        } catch {
            return nil
        }
    }

    /// Format file size for display.
    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }

    // MARK: - Folder Authorization

    /// Check whether the resolved path is under a user-authorized folder.
    /// Returns a denial result if not authorized, nil if OK.
    private func checkFolderAuthorization(_ resolvedPath: String, tool: String) async -> ToolExecutionResult? {
        let accessible = await MainActor.run {
            FileAccessManager.shared.isPathAccessible(resolvedPath)
        }

        if !accessible {
            // Post notification for auto-prompt
            await MainActor.run {
                NotificationCenter.default.post(
                    name: FileAccessManager.requestFolderAccessNotification,
                    object: nil,
                    userInfo: ["path": resolvedPath, "tool": tool]
                )
            }

            return .error(
                tool: tool,
                message: "Access to '\(resolvedPath)' has not been granted. Please add this folder in Settings > File Access, or grant access when prompted.",
                errorType: "folder_not_authorized",
                isRetryable: true
            )
        }

        return nil
    }
}
