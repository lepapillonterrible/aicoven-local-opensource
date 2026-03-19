import Foundation

/// Resolves composite user intents into ordered sequences of tool
/// invocations for local models that cannot orchestrate multi-step
/// workflows themselves.
///
/// Cloud models handle chaining natively via the tool loop; this is
/// the local-model equivalent, using deterministic pattern matching
/// to construct the chain before the model is ever called.
///
/// Usage (in ChatService pre-execution block):
/// ```swift
/// if let chain = ToolChainResolver.resolve(
///     userMessage: message,
///     enabledTools: toolConfig.enabledTools,
///     mcpServers: toolConfig.mcpServers
/// ) {
///     // Execute each invocation sequentially, accumulating results.
/// }
/// ```
enum ToolChainResolver {
    /// Attempt to resolve the user message into an ordered chain of
    /// tool invocations. Returns `nil` if the message doesn't match
    /// any known composite intent pattern.
    ///
    /// - Parameters:
    ///   - userMessage: The user's natural language message.
    ///   - enabledTools: Set of tool names currently enabled.
    ///   - mcpServers: Active MCP server configurations (for MCP tool chains).
    /// - Returns: An ordered array of `ChatToolInvocation` to execute
    ///   sequentially, or `nil` if no multi-step pattern matches.
    static func resolve(
        userMessage: String,
        enabledTools: Set<String>,
        mcpServers: [MCPServerAccount] = []
    ) -> [ChatToolInvocation]? {
        let lower = userMessage.lowercased()

        // Try each pattern resolver in priority order.
        // Return the first chain that matches and has all required tools enabled.
        for resolver in patternResolvers {
            if let chain = resolver(lower, userMessage, enabledTools, mcpServers),
               !chain.isEmpty {
                return chain
            }
        }
        return nil
    }

    // MARK: - Pattern Resolvers

    /// Ordered list of pattern resolvers. Each returns a chain or nil.
    private static let patternResolvers: [
        (_ lower: String, _ original: String, _ enabled: Set<String>, _ mcpServers: [MCPServerAccount]) -> [ChatToolInvocation]?
    ] = [
        resolveSearchAndSummarize,
        resolveReadFileAndExplain,
        resolveMultiTimezone,
        resolveListAndRead,
        resolveSearchAndRead,
    ]

    // MARK: - "Search for X and summarize/explain"

    /// Detects: "search for X and summarize", "look up X and explain"
    /// Chain: [web_search(X)] → model summarizes
    private static func resolveSearchAndSummarize(
        _ lower: String,
        _ original: String,
        _ enabled: Set<String>,
        _: [MCPServerAccount]
    ) -> [ChatToolInvocation]? {
        guard enabled.contains("web_search") else { return nil }

        // Match patterns like "search for ... and summarize/explain/tell me"
        let patterns: [(trigger: String, continuation: [String])] = [
            ("search for ", ["and summarize", "and explain", "and tell me", "then summarize", "then explain"]),
            ("look up ", ["and summarize", "and explain", "and tell me", "then summarize", "then explain"]),
            ("find out about ", ["and summarize", "and explain", "and tell me"]),
        ]

        for pattern in patterns {
            guard let triggerRange = original.range(of: pattern.trigger, options: .caseInsensitive) else { continue }
            guard pattern.continuation.contains(where: { original.range(of: $0, options: .caseInsensitive) != nil }) else { continue }

            // Extract the query between trigger and continuation keyword
            let afterTrigger = String(original[triggerRange.upperBound...])
            let query = extractBeforeContinuation(
                afterTrigger,
                continuations: pattern.continuation
            )

            guard !query.isEmpty else { continue }

            return [
                ChatToolInvocation(
                    tool: "web_search",
                    input: AnyJSONValue(["query": AnyJSONValue(query)]),
                    reason: "Search step of search-and-summarize chain"
                ),
            ]
        }

        return nil
    }

    // MARK: - "Read this file and explain it"

    /// Detects: "read /path/to/file and explain", "show me the file at X and summarize"
    /// Chain: [file.read(path)] → model explains
    private static func resolveReadFileAndExplain(
        _ lower: String,
        _ original: String,
        _ enabled: Set<String>,
        _: [MCPServerAccount]
    ) -> [ChatToolInvocation]? {
        guard enabled.contains("file.read") else { return nil }

        let triggers = [
            "read ", "show ", "open ", "cat ", "display ",
        ]
        let continuations = [
            "and explain", "and summarize", "and tell me",
            "then explain", "then summarize", "and describe",
        ]

        guard triggers.contains(where: { lower.contains($0) }),
              continuations.contains(where: { lower.contains($0) })
        else { return nil }

        // Extract the file path from the message.
        guard let path = ChatService.extractFilePath(from: original) else { return nil }

        return [
            ChatToolInvocation(
                tool: "file.read",
                input: AnyJSONValue(["path": AnyJSONValue(path)]),
                reason: "Read step of read-and-explain chain"
            ),
        ]
    }

    // MARK: - "What time is it in X and Y"

    /// Detects: "what time is it in Tokyo and London"
    /// Chain: [current_time(tz: Tokyo), current_time(tz: London)]
    private static func resolveMultiTimezone(
        _ lower: String,
        _: String,
        _ enabled: Set<String>,
        _: [MCPServerAccount]
    ) -> [ChatToolInvocation]? {
        guard enabled.contains("current_time") else { return nil }

        // Must contain a time-related trigger
        let timeTriggers = ["what time", "time is it in", "current time in"]
        guard timeTriggers.contains(where: { lower.contains($0) }) else { return nil }

        // Must contain "and" connecting two locations
        guard lower.contains(" and ") else { return nil }

        // Extract locations around "and"
        // e.g. "what time is it in tokyo and london"
        let locations = extractLocationsAroundAnd(lower)
        guard locations.count >= 2 else { return nil }

        // Map locations to timezone identifiers
        return locations.prefix(3).compactMap { location -> ChatToolInvocation? in
            let tz = ChatService.extractTimezoneFromMessage(location)
            return ChatToolInvocation(
                tool: "current_time",
                input: AnyJSONValue(["timezone": AnyJSONValue(tz)]),
                reason: "Timezone query for '\(location)'"
            )
        }
    }

    // MARK: - "List files in X and read Y"

    /// Detects: "list files in /project and read the README"
    /// Chain: [file.list(path)] → (model sees listing, but we
    /// also pre-read a likely file if mentioned)
    private static func resolveListAndRead(
        _ lower: String,
        _ original: String,
        _ enabled: Set<String>,
        _: [MCPServerAccount]
    ) -> [ChatToolInvocation]? {
        guard enabled.contains("file.list"), enabled.contains("file.read") else { return nil }

        let listTriggers = ["list files", "list the files", "show directory", "ls "]
        let readContinuations = ["and read", "and show", "and open", "then read", "then show"]

        guard listTriggers.contains(where: { lower.contains($0) }),
              readContinuations.contains(where: { lower.contains($0) })
        else { return nil }

        guard let dirPath = ChatService.extractFilePath(from: original) else { return nil }

        var chain: [ChatToolInvocation] = [
            ChatToolInvocation(
                tool: "file.list",
                input: AnyJSONValue(["path": AnyJSONValue(dirPath)]),
                reason: "List step of list-and-read chain"
            ),
        ]

        // If a specific filename is mentioned after "and read", construct
        // a file.read call with the combined path. Use the original-case
        // message for extraction so filenames preserve their casing.
        if let readTarget = extractAfterContinuation(original.lowercased(), continuations: readContinuations) {
            // Strip common articles ("the", "a", "an") that precede the filename.
            let stripped = readTarget
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^(the|a|an)\\s+", with: "", options: .regularExpression)
            // Re-extract the original-case filename from the message.
            let filename: String = if let originalRange = original.range(of: stripped, options: .caseInsensitive) {
                String(original[originalRange])
            } else {
                stripped
            }
            if !filename.isEmpty {
                let fullPath = dirPath.hasSuffix("/") ? dirPath + filename : dirPath + "/" + filename
                chain.append(ChatToolInvocation(
                    tool: "file.read",
                    input: AnyJSONValue(["path": AnyJSONValue(fullPath)]),
                    reason: "Read step of list-and-read chain"
                ))
            }
        }

        return chain.count >= 2 ? chain : nil
    }

    // MARK: - "Search GitHub for X and read the file"

    /// Detects: "search GitHub for X and read it"
    /// Chain: [github.searchCode(query)] → result provides file to read
    private static func resolveSearchAndRead(
        _ lower: String,
        _ original: String,
        _ enabled: Set<String>,
        _: [MCPServerAccount]
    ) -> [ChatToolInvocation]? {
        guard enabled.contains("github.searchCode") else { return nil }

        let triggers = ["search github for ", "search github "]
        let continuations = ["and read", "and show", "and open", "then read"]

        guard triggers.contains(where: { lower.contains($0) }),
              continuations.contains(where: { lower.contains($0) })
        else { return nil }

        // Extract the search query between trigger and continuation
        for trigger in triggers {
            guard let triggerRange = original.range(of: trigger, options: .caseInsensitive) else { continue }
            let afterTrigger = String(original[triggerRange.upperBound...])
            let query = extractBeforeContinuation(afterTrigger, continuations: continuations)
            guard !query.isEmpty else { continue }

            return [
                ChatToolInvocation(
                    tool: "github.searchCode",
                    input: AnyJSONValue(["query": AnyJSONValue(query)]),
                    reason: "Search step of GitHub search-and-read chain"
                ),
            ]
        }

        return nil
    }

    // MARK: - Text Extraction Helpers

    /// Extract text before the first continuation keyword.
    private static func extractBeforeContinuation(
        _ text: String,
        continuations: [String]
    ) -> String {
        var earliest = text.endIndex
        for cont in continuations {
            if let range = text.range(of: cont, options: .caseInsensitive),
               range.lowerBound < earliest {
                earliest = range.lowerBound
            }
        }
        return String(text[text.startIndex ..< earliest])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract text after the first continuation keyword.
    private static func extractAfterContinuation(
        _ text: String,
        continuations: [String]
    ) -> String? {
        for cont in continuations {
            if let range = text.range(of: cont) {
                let after = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return after.isEmpty ? nil : after
            }
        }
        return nil
    }

    /// Extract location names around "and" in a time query.
    /// "what time is it in tokyo and london" → ["tokyo", "london"]
    private static func extractLocationsAroundAnd(_ lower: String) -> [String] {
        // Find the relevant suffix after "in "
        guard let inRange = lower.range(of: " in ") else { return [] }
        let locationPart = String(lower[inRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Split on " and "
        return locationPart.components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
