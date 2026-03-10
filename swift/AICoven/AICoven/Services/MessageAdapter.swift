import Foundation

/// Converts API models (ChatMessage/ChatResponse) into EnhancedChatMessage for UI
enum MessageAdapter {
    /// Strip internal TOOL_CALL / <thought> markup from message content so the
    /// user only sees the final natural-language answer. The backend still
    /// stores full content (including TOOL_CALL blocks) for traceability.
    static func sanitizeContent(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        // Patterns for tool calls, thoughts, scratchpad, memory proposals,
        // and reasoning tags emitted by local models (e.g. Qwen3's <think>).
        let patterns = [
            #"\[TOOL_CALL:[\s\S]*?\[/TOOL_CALL\]"#,
            #"<TOOL_CALL>[\s\S]*?</TOOL_CALL>"#,
            #"<\s*thought\s*>[\s\S]*?</\s*thought\s*>"#,
            #"<\s*think\s*>[\s\S]*?</\s*think\s*>"#,
            #"<\s*scratchpad\s*>[\s\S]*?</\s*scratchpad\s*>"#,
            #"\[MEMORY_WRITE:[\s\S]*?\[/MEMORY_WRITE\]"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex ..< result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        // Handle unclosed <think> tags (model started reasoning but response was cut off)
        if let thinkStart = result.range(of: "<think>", options: .caseInsensitive) {
            result = String(result[..<thinkStart.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitize content for display in the chat UI. This applies the core
    /// TOOL_CALL/<thought> stripping and additionally removes known
    /// checklist-style boilerplate instructions that some models echo from the
    /// system prompt (e.g. "Do not make up facts", "Do not roleplay").
    static func sanitizeContentForDisplay(_ text: String) -> String {
        let stripped = sanitizeContent(text)
        guard !stripped.isEmpty else { return stripped }

        var lines = stripped.components(separatedBy: .newlines)
        // Drop leading boilerplate instruction lines that match our known
        // response-checklist phrases.
        while let first = lines.first, isBoilerplateInstructionLine(first) {
            lines.removeFirst()
        }
        // Drop leading empty lines after removing boilerplate.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heuristic detection for checklist-style instruction lines that should not
    /// appear in user-facing answers.
    private static func isBoilerplateInstructionLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        // Known instruction phrases that should not appear in user-visible answers
        let snippets = [
            "if you cannot fulfill the request",
            "if you have enough information to fully answer",
            "if the answer is complex, break it down",
            "if you cannot answer, explain why",
            "do not make up facts",
            "do not use external knowledge",
            "do not roleplay",
            "do not use markdown",
            "do not make a tool call unless absolutely necessary",
            "do not add any extra conversational filler",
            "do not apologize",
            "if the request is a non-english language, respond in that language",
            "simply respond"
        ]
        return snippets.contains { lower.contains($0) }
    }

    static func toEnhanced(from chatMessage: ChatMessage, response: ChatResponse?) -> EnhancedChatMessage {
        // Extract basic fields
        let id = chatMessage.id
        let threadId = chatMessage.threadId
        let role = chatMessage.role
        let content = sanitizeContentForDisplay(chatMessage.content)

        // Pull metadata values safely
        let meta = chatMessage.metadata ?? [:]

        // Tokens: prefer persisted usage on the message, fall back to the
        // immediate ChatResponse (non-streaming path).
        let tokens = chatMessage.tokenUsage?.totalTokens ?? response?.tokenUsage?.totalTokens

        // Agent role name: prefer the persisted role_name in metadata (so
        // history loads show the correct agent), falling back to the
        // ChatResponse role for freshly-sent messages.
        let agentRole = (meta["role_name"]?.value as? String) ?? response?.role

        // Extract provider and model from metadata, falling back to the
        // ChatResponse. The model here is the *actual* model used for this
        // reply (after any provider fallback), not just the role default.
        let provider = (meta["provider_used"]?.value as? String) ?? response?.provider
        let model = (meta["model"]?.value as? String) ?? response?.model

        // Tool calls - try metadata first (for loaded messages), then response (for fresh sends)
        let toolCalls: [ToolCallDetail]? = {
            // Try parsing from message metadata (stored by backend)
            if let metaToolCalls = meta["tool_calls"]?.value as? [[String: Any]] {
                return parseToolCallsFromMetadata(metaToolCalls, messageId: id)
            }
            // Fallback to response if available
            guard let calls = response?.toolCalls, !calls.isEmpty else { return nil }
            return calls.enumerated().map { idx, call in
                // Convert args to AnyJSONValue
                let convertedArgs = call.args.reduce(into: [String: AnyJSONValue]()) { acc, kv in
                    acc[kv.key] = AnyJSONValue(kv.value.value)
                }

                // Parse status from API
                let status: ToolCallDetail.Status = if let statusStr = call.status?.lowercased() {
                    ToolCallDetail.Status(rawValue: statusStr) ?? .completed
                } else {
                    call.result != nil ? .completed : .pending
                }

                return ToolCallDetail(
                    id: "\(id)-tool-\(idx)",
                    name: call.name,
                    args: convertedArgs,
                    result: call.result, // Already AnyJSONValue from API
                    error: call.error,
                    status: status
                )
            }
        }()

        // Thoughts - try metadata first, then response
        let thoughts: [String]? = {
            if let metaThoughts = meta["thoughts"]?.value as? [String] {
                return metaThoughts.isEmpty ? nil : metaThoughts
            }
            return response?.thoughts
        }()

        // Attachments (IDs live in metadata.file_attachment_ids)
        let attachments: [FileAttachmentDetail]? = {
            guard let ids = meta["file_attachment_ids"]?.value as? [String], !ids.isEmpty else { return nil }
            // We only have IDs at this point; fill minimal info so UI can render
            return ids.map { FileAttachmentDetail(id: $0, name: $0, mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil) }
        }()

        // Generated files (from backend metadata.generated_files)
        let generatedFiles: [GeneratedFile]? = {
            guard let rawList = meta["generated_files"]?.value as? [[String: Any]], !rawList.isEmpty else {
                return nil
            }
            let mapped: [GeneratedFile] = rawList.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else {
                    return nil
                }
                let urlString = dict["url"] as? String
                let url = urlString.flatMap { URL(string: $0) }
                return GeneratedFile(id: id, name: name, url: url)
            }
            return mapped.isEmpty ? nil : mapped
        }()

        return EnhancedChatMessage(
            id: id,
            threadId: threadId,
            role: role,
            content: content,
            agentRole: agentRole,
            model: model,
            provider: provider,
            tokens: tokens,
            cost: nil,
            thoughts: thoughts,
            toolCalls: toolCalls,
            attachments: attachments,
            images: nil,
            generatedFiles: generatedFiles,
            createdAt: chatMessage.createdAt
        )
    }

    /// Helper to parse tool calls from message metadata
    private static func parseToolCallsFromMetadata(_ metaToolCalls: [[String: Any]], messageId: String) -> [ToolCallDetail]? {
        let parsed = metaToolCalls.enumerated().compactMap { idx, dict -> ToolCallDetail? in
            guard let name = dict["name"] as? String else { return nil }

            // Parse args
            let args: [String: AnyJSONValue] = if let argsDict = dict["args"] as? [String: Any] {
                argsDict.reduce(into: [:]) { acc, kv in
                    acc[kv.key] = AnyJSONValue(kv.value)
                }
            } else {
                [:]
            }

            // Parse result
            let result: AnyJSONValue? = dict["result"].map { AnyJSONValue($0) }

            // Parse error and status
            let error = dict["error"] as? String
            let statusStr = dict["status"] as? String
            let status: ToolCallDetail.Status = {
                if let statusLower = statusStr?.lowercased() {
                    return ToolCallDetail.Status(rawValue: statusLower) ?? .completed
                }
                return result != nil ? .completed : .pending
            }()

            return ToolCallDetail(
                id: "\(messageId)-tool-\(idx)",
                name: name,
                args: args,
                result: result,
                error: error,
                status: status
            )
        }
        return parsed.isEmpty ? nil : parsed
    }
}
