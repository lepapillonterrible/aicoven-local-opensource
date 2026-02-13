import Foundation

// MARK: - Parsed Tool Call

/// Represents a parsed tool call from LLM output, regardless of format.
/// Supports JSON, angle-bracket, and square-bracket formats.
struct ParsedToolCall: Codable, Equatable {
    let name: String
    let args: [String: AnyJSONValue]
    let reason: String?

    init(name: String, args: [String: AnyJSONValue], reason: String? = nil) {
        self.name = name
        self.args = args
        self.reason = reason
    }
}

// MARK: - Parsed Thought

/// Represents a <thought> block extracted from LLM output.
struct ParsedThought: Equatable {
    let content: String
}

// MARK: - Parsed Scratchpad Task

/// Represents a task from a <scratchpad> block.
struct ParsedScratchpadTask: Equatable {
    let id: String
    let title: String
    let completed: Bool
}

// MARK: - Parsed Memory Proposal

/// Represents a [MEMORY_WRITE:...] block for proposing memory storage.
struct ParsedMemoryProposal: Equatable {
    let content: String
    let scope: String // "user" or "thread"
    let category: String?
}

// MARK: - Parse Result

/// Aggregated result of parsing LLM output for tool calls, thoughts, scratchpad, and memory proposals.
struct ToolCallParseResult {
    let toolCalls: [ParsedToolCall]
    let thoughts: [ParsedThought]
    let scratchpadTasks: [ParsedScratchpadTask]
    let memoryProposals: [ParsedMemoryProposal]
    /// The original text with tool/thought/scratchpad/memory blocks removed.
    let strippedText: String
}

// MARK: - ToolCallParser

/// Parses tool calls, thoughts, and scratchpad from LLM output.
///
/// Supports three tool call formats:
/// 1. JSON: `{"tool": "...", "input": {...}, "reason": "..."}`
/// 2. Angle-bracket: `<TOOL_CALL>tool.name {...}</TOOL_CALL>`
/// 3. Square-bracket: `[TOOL_CALL: name=tool.name] {...} [/TOOL_CALL]`
enum ToolCallParser {

    // MARK: - Main Parse Method

    /// Parse all tool calls, thoughts, scratchpad tasks, and memory proposals from LLM output.
    /// Returns the parse result including stripped text for user display.
    static func parse(_ text: String) -> ToolCallParseResult {
        var toolCalls: [ParsedToolCall] = []
        var thoughts: [ParsedThought] = []
        var scratchpadTasks: [ParsedScratchpadTask] = []
        var memoryProposals: [ParsedMemoryProposal] = []

        // Parse tool calls from all formats
        toolCalls.append(contentsOf: parseJSONToolCalls(text))
        toolCalls.append(contentsOf: parseAngleBracketToolCalls(text))
        toolCalls.append(contentsOf: parseSquareBracketToolCalls(text))

        // Parse thoughts
        thoughts = parseThoughts(text)

        // Parse scratchpad tasks
        scratchpadTasks = parseScratchpadTasks(text)

        // Parse memory proposals
        memoryProposals = parseMemoryProposals(text)

        // Strip all markup from the text for user display
        let strippedText = stripAllMarkup(text)

        return ToolCallParseResult(
            toolCalls: toolCalls,
            thoughts: thoughts,
            scratchpadTasks: scratchpadTasks,
            memoryProposals: memoryProposals,
            strippedText: strippedText
        )
    }

    // MARK: - JSON Format Parsing

    /// Parse JSON format tool calls: `{"tool": "...", "input": {...}, "reason": "..."}`
    /// This format is used by ChatService's existing ChatToolInvocation.
    static func parseJSONToolCalls(_ text: String) -> [ParsedToolCall] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fast path: entire string is a JSON object starting with {"tool"
        if trimmed.hasPrefix("{\"tool\"") || trimmed.hasPrefix("{ \"tool\"") {
            if let call = parseJSONObject(trimmed) {
                return [call]
            }
        }

        // Look for JSON objects containing "tool" key anywhere in the text
        var results: [ParsedToolCall] = []

        // Find all potential JSON objects starting with {"tool"
        let pattern = "\\{\\s*\"tool\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return results
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let startIndex = text.index(text.startIndex, offsetBy: match.range.location)
            if let call = extractAndParseJSONObject(from: text, startingAt: startIndex) {
                results.append(call)
            }
        }

        return results
    }

    /// Extract a balanced JSON object from text and parse it as a tool call.
    /// Properly handles braces inside JSON strings and escaped quotes.
    private static func extractAndParseJSONObject(from text: String, startingAt startIndex: String.Index) -> ParsedToolCall? {
        var depth = 0
        var endIndex: String.Index?
        var idx = startIndex
        var insideString = false
        var previousChar: Character? = nil

        while idx < text.endIndex {
            let ch = text[idx]

            // Handle string boundaries (accounting for escaped quotes)
            if ch == "\"" {
                // Check if this quote is escaped (preceded by backslash)
                // Also need to check if the backslash itself is escaped (\\")
                var isEscaped = false
                if previousChar == "\\" {
                    // Count consecutive backslashes before this quote
                    var backslashCount = 0
                    var checkIdx = idx
                    while checkIdx > startIndex {
                        text.formIndex(before: &checkIdx)
                        if text[checkIdx] == "\\" {
                            backslashCount += 1
                        } else {
                            break
                        }
                    }
                    // Quote is escaped if preceded by odd number of backslashes
                    isEscaped = backslashCount % 2 == 1
                }

                if !isEscaped {
                    insideString.toggle()
                }
            }

            // Only count braces when not inside a string
            if !insideString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = idx
                        break
                    }
                }
            }

            previousChar = ch
            text.formIndex(after: &idx)
        }

        guard let end = endIndex else { return nil }
        let jsonString = String(text[startIndex ... end])
        return parseJSONObject(jsonString)
    }

    /// Parse a JSON string into a ParsedToolCall.
    private static func parseJSONObject(_ jsonString: String) -> ParsedToolCall? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        // Try to decode as a flexible structure
        struct FlexibleToolCall: Decodable {
            let tool: String
            let input: AnyJSONValue?
            let args: [String: AnyJSONValue]?
            let reason: String?
        }

        guard let decoded = try? JSONDecoder().decode(FlexibleToolCall.self, from: data) else {
            return nil
        }

        // Normalize args: prefer explicit 'args', fall back to 'input' as dict
        var normalizedArgs: [String: AnyJSONValue] = [:]

        if let args = decoded.args {
            normalizedArgs = args
        } else if let input = decoded.input {
            // Input can be a string or a dict
            // When decoded via AnyJSONValue, nested dicts are [String: AnyJSONValue]
            if let dict = input.value as? [String: AnyJSONValue] {
                normalizedArgs = dict
            } else if let dict = input.value as? [String: Any] {
                for (key, value) in dict {
                    normalizedArgs[key] = AnyJSONValue(value)
                }
            } else if let str = input.value as? String {
                // Common patterns: "query", "input", "q"
                normalizedArgs["input"] = AnyJSONValue(str)
            }
        }

        return ParsedToolCall(name: decoded.tool, args: normalizedArgs, reason: decoded.reason)
    }

    // MARK: - Angle-Bracket Format Parsing

    /// Parse angle-bracket format: `<TOOL_CALL>tool.name {...}</TOOL_CALL>`
    static func parseAngleBracketToolCalls(_ text: String) -> [ParsedToolCall] {
        var results: [ParsedToolCall] = []

        // Pattern: <TOOL_CALL>tool.name {JSON}</TOOL_CALL>
        // Allow optional whitespace around tags
        let pattern = "<\\s*TOOL_CALL\\s*>\\s*([\\w\\.\\-]+)\\s*(\\{.*?\\})\\s*<\\s*/\\s*TOOL_CALL\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return results
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }

            let nameRange = match.range(at: 1)
            let bodyRange = match.range(at: 2)

            let name = nsText.substring(with: nameRange)
            let body = nsText.substring(with: bodyRange)

            if let args = parseJSONBody(body) {
                results.append(ParsedToolCall(name: name, args: args, reason: nil))
            }
        }

        // Fallback: try to find tool names followed by JSON without closing tag
        // (handles malformed output from some models)
        if results.isEmpty, text.contains("<TOOL_CALL>") {
            let fallbackPattern = "<\\s*TOOL_CALL\\s*>\\s*([\\w\\.\\-]+)\\s*(\\{[^<]*\\})"
            if let fallbackRegex = try? NSRegularExpression(pattern: fallbackPattern, options: [.dotMatchesLineSeparators]) {
                let fallbackMatches = fallbackRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

                for match in fallbackMatches {
                    guard match.numberOfRanges >= 3 else { continue }

                    let nameRange = match.range(at: 1)
                    let bodyRange = match.range(at: 2)

                    let name = nsText.substring(with: nameRange)
                    let body = nsText.substring(with: bodyRange)

                    if let args = parseJSONBody(body) {
                        results.append(ParsedToolCall(name: name, args: args, reason: nil))
                    }
                }
            }
        }

        return results
    }

    // MARK: - Square-Bracket Format Parsing

    /// Parse square-bracket format: `[TOOL_CALL: name=tool.name] {...} [/TOOL_CALL]`
    static func parseSquareBracketToolCalls(_ text: String) -> [ParsedToolCall] {
        var results: [ParsedToolCall] = []

        // Pattern: [TOOL_CALL: name=...] or [TOOL_CALL: tool.name] followed by JSON and [/TOOL_CALL]
        let pattern = "\\[TOOL_CALL:\\s*(?:name=)?([^\\]]+)\\](.*?)\\[/TOOL_CALL\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return results
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }

            let nameRange = match.range(at: 1)
            let bodyRange = match.range(at: 2)

            let name = nsText.substring(with: nameRange).trimmingCharacters(in: .whitespaces)
            let body = nsText.substring(with: bodyRange).trimmingCharacters(in: .whitespacesAndNewlines)

            if let args = parseJSONBody(body) {
                results.append(ParsedToolCall(name: name, args: args, reason: nil))
            }
        }

        return results
    }

    // MARK: - Thought Parsing

    /// Parse <thought> blocks from LLM output.
    static func parseThoughts(_ text: String) -> [ParsedThought] {
        var results: [ParsedThought] = []

        // Pattern: <thought>...</thought> with optional whitespace
        let pattern = "<\\s*thought\\s*>(.*?)<\\s*/\\s*thought\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return results
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let contentRange = match.range(at: 1)
            let content = nsText.substring(with: contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                results.append(ParsedThought(content: content))
            }
        }

        return results
    }

    // MARK: - Scratchpad Parsing

    /// Parse <scratchpad> blocks for task lists.
    static func parseScratchpadTasks(_ text: String) -> [ParsedScratchpadTask] {
        var results: [ParsedScratchpadTask] = []

        // Find all scratchpad blocks
        let pattern = "<\\s*scratchpad\\s*>(.*?)<\\s*/\\s*scratchpad\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return results
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        guard let lastMatch = matches.last, lastMatch.numberOfRanges >= 2 else {
            return results
        }

        // Use the last scratchpad block (most recent state)
        let contentRange = lastMatch.range(at: 1)
        let scratchpadContent = nsText.substring(with: contentRange)

        // Parse task lines: "- [ ] Task" or "- [x] Task"
        let taskPattern = "-\\s*\\[([ xX])\\]\\s*(.+?)(?=\\n-|\\n</|$)"
        guard let taskRegex = try? NSRegularExpression(pattern: taskPattern, options: [.dotMatchesLineSeparators]) else {
            return results
        }

        let nsScratchpad = scratchpadContent as NSString
        let taskMatches = taskRegex.matches(in: scratchpadContent, options: [], range: NSRange(location: 0, length: nsScratchpad.length))

        for (idx, match) in taskMatches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }

            let checkboxRange = match.range(at: 1)
            let titleRange = match.range(at: 2)

            let checkbox = nsScratchpad.substring(with: checkboxRange)
            let title = nsScratchpad.substring(with: titleRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first ?? ""

            let completed = checkbox.lowercased() == "x"

            results.append(ParsedScratchpadTask(
                id: "task-\(idx + 1)",
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                completed: completed
            ))
        }

        return results
    }

    // MARK: - Memory Proposal Parsing

    /// Parse [MEMORY_WRITE:...] blocks for memory proposals.
    static func parseMemoryProposals(_ text: String) -> [ParsedMemoryProposal] {
        var results: [ParsedMemoryProposal] = []

        // Pattern: [MEMORY_WRITE: scope=user|thread] content [/MEMORY_WRITE]
        // Also supports: [MEMORY_WRITE: scope=user, category=preference] for optional category
        let pattern = "\\[MEMORY_WRITE:\\s*scope=(\\w+)(?:,\\s*category=(\\w+))?\\](.*?)\\[/MEMORY_WRITE\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return results
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }

            let scopeRange = match.range(at: 1)
            let categoryRange = match.range(at: 2)
            let contentRange = match.range(at: 3)

            let scope = nsText.substring(with: scopeRange).lowercased()
            let category: String? = categoryRange.location != NSNotFound
                ? nsText.substring(with: categoryRange)
                : nil
            let content = nsText.substring(with: contentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !content.isEmpty {
                results.append(ParsedMemoryProposal(
                    content: content,
                    scope: scope,
                    category: category
                ))
            }
        }

        return results
    }

    // MARK: - Stripping Markup

    /// Remove all tool call, thought, scratchpad, and memory markup from text.
    static func stripAllMarkup(_ text: String) -> String {
        var result = text

        // Strip square-bracket tool calls: [TOOL_CALL: ...] ... [/TOOL_CALL]
        if let regex = try? NSRegularExpression(pattern: "\\[TOOL_CALL:.*?\\[/TOOL_CALL\\]", options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }

        // Strip angle-bracket tool calls: <TOOL_CALL>...</TOOL_CALL>
        if let regex = try? NSRegularExpression(pattern: "<\\s*TOOL_CALL\\s*>.*?<\\s*/\\s*TOOL_CALL\\s*>", options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }

        // Strip stray opening/closing TOOL_CALL tags
        if let regex = try? NSRegularExpression(pattern: "<\\s*/\\s*TOOL_CALL\\s*>\\s*", options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: "<\\s*TOOL_CALL\\s*>\\s*", options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }

        // Strip thought blocks: <thought>...</thought>
        if let regex = try? NSRegularExpression(pattern: "<\\s*thought\\s*>.*?<\\s*/\\s*thought\\s*>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }

        // Strip scratchpad blocks: <scratchpad>...</scratchpad>
        if let regex = try? NSRegularExpression(pattern: "<\\s*scratchpad\\s*>.*?<\\s*/\\s*scratchpad\\s*>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }

        // Strip memory write blocks: [MEMORY_WRITE:...]...[/MEMORY_WRITE]
        if let regex = try? NSRegularExpression(pattern: "\\[MEMORY_WRITE:.*?\\[/MEMORY_WRITE\\]", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }

        // Clean up multiple newlines
        if let regex = try? NSRegularExpression(pattern: "\\n{3,}", options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "\n\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Parse a JSON body string into args dictionary.
    private static func parseJSONBody(_ body: String) -> [String: AnyJSONValue]? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }

        guard let dict = try? JSONDecoder().decode([String: AnyJSONValue].self, from: data) else {
            return nil
        }

        return dict
    }
}
