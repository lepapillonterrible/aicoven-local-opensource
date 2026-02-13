import Foundation
import SwiftUI

/// Protocol used by chat/agents for tool operations so we can inject mocks
/// in tests without depending directly on the ToolService actor.
protocol ChatToolService {
    func webSearch(query: String, maxResults: Int) async throws -> [ToolService.WebSearchResult]
    func webBrowse(url: URL, maxLength: Int) async throws -> ToolService.WebBrowseResult
    nonisolated func currentTime(timezone: TimeZone) -> ToolService.TimeInfo
}

extension ChatToolService {
    /// Default maxLength for webBrowse so callers don't need to specify it.
    func webBrowse(url: URL) async throws -> ToolService.WebBrowseResult {
        try await webBrowse(url: url, maxLength: 5000)
    }
}

extension ToolService: ChatToolService {}

/// Unified tool layer that exposes provider-agnostic capabilities to higher
/// level services (agents, chat):
/// - Timezone-aware current time
/// - Web search (stubbed for now)
/// - Image generation
/// - File generation with download links
/// - Image analysis (vision)
/// - File analysis (summaries / QA)
///
/// This service relies **only** on the user's configured LLM provider keys.
actor ToolService {
    static let shared = ToolService(environment: ToolEnvironment.make())

    private let environment: ToolEnvironment

    init(environment: ToolEnvironment) {
        self.environment = environment
    }

    // MARK: - Time

    struct TimeInfo {
        let utcISO8601: String
        let timezoneIdentifier: String
        let localISO8601: String
    }

    // Returns the current time in UTC and the user's local timezone.
    //
    // Marked `nonisolated` because it does not touch any actor state and can
    // be safely called without hopping onto the ToolService actor.
    // Implementation moved up to satisfy ChatToolService; kept here for docs.

    // MARK: - Image generation

    struct GeneratedImage {
        let id: String
        let url: URL
    }

    /// Provider-agnostic entry point for image generation. For now this
    /// delegates to the OpenAI client when available and otherwise throws.
    func generateImage(prompt: String) async throws -> GeneratedImage {
        // Prefer OpenAI if available; other providers can be wired in later.
        guard let caps = environment.capabilities.first(where: { $0.providerID == "openai" }),
              let client = environment.clients["openai"]
        else {
            throw NSError(
                domain: "ToolService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Image generation is not available – no suitable provider configured."]
            )
        }

        // We do not yet have a dedicated image endpoint on LLMClient, so for
        // now we ask the chat model for an HTML <img> tag with a data URL and
        // decode it locally. This is intentionally simple and can be replaced
        // with a first-class images API later.
        let systemPrompt = "You are an image generator helper. When asked to generate an image, you must respond with a single data URL in an <img src=\"...\"> tag, no other text."
        let messages = [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: "Generate an image for: \(prompt)")
        ]
        let options = ChatOptions(temperature: 0.8, maxTokens: nil, stream: false)
        let response = try await client.completeChat(
            messages: messages,
            model: caps.chatModel ?? "gpt-4o",
            options: options
        )
        let html = response.message.content

        // Very small heuristic to pull out a data URL if present.
        guard let range = html.range(of: "data:image"),
              let endQuote = html[range.lowerBound...].firstIndex(of: "\"") ?? html[range.lowerBound...].firstIndex(of: "'")
        else {
            throw NSError(
                domain: "ToolService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Image generation did not return a data URL."]
            )
        }
        let urlString = String(html[range.lowerBound ..< endQuote])
        guard let dataURL = URL(string: urlString) else {
            throw NSError(
                domain: "ToolService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid image data URL returned by model."]
            )
        }

        // Persist the image to disk so the UI can display/download it.
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let imagesDir = baseDir.appendingPathComponent("GeneratedImages", isDirectory: true)
        do {
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        } catch {
            AppErrorReporter.log(error: error, context: "ToolService.generateImage.createDirectory")
        }

        let id = UUID().uuidString
        let fileURL = imagesDir.appendingPathComponent("\(id).png")

        if let data = Data(base64Encoded: dataURL.lastPathComponent) {
            try data.write(to: fileURL)
        }

        return GeneratedImage(id: id, url: fileURL)
    }

    // MARK: - File generation

    struct GeneratedFile {
        let id: String
        let url: URL
        let mimeType: String
    }

    /// Stores arbitrary text content as a file on disk and returns a download
    /// URL. This does not require any external API.
    func generateFile(name: String, mimeType: String, contents: Data) throws -> GeneratedFile {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let filesDir = baseDir.appendingPathComponent("GeneratedFiles", isDirectory: true)
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let fileURL = filesDir.appendingPathComponent(name.isEmpty ? id : name)
        try contents.write(to: fileURL)

        return GeneratedFile(id: id, url: fileURL, mimeType: mimeType)
    }

    // MARK: - Image / file analysis stubs

    // These analysis helpers are intentionally lightweight – they assume that
    // some other part of the app manages attachments and can provide raw
    // bytes for a given attachment identifier. Hooking them into the existing
    // UploadService/attachments pipeline will be done at a higher layer.

    struct AnalysisResult {
        let textSummary: String
    }

    func analyzeImage(data: Data, hints: String? = nil) async throws -> AnalysisResult {
        guard let caps = environment.capabilities.first(where: { $0.visionModel != nil }),
              let client = environment.clients[caps.providerID],
              let model = caps.visionModel ?? caps.chatModel
        else {
            throw NSError(
                domain: "ToolService",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "No vision-capable model configured."]
            )
        }

        let base64 = data.base64EncodedString()
        let prompt = "You are an image analysis helper. The user has provided a PNG image as base64. \(hints ?? "Describe the image in detail.") Base64: \(base64)"
        let messages = [LLMMessage(role: .user, content: prompt)]
        let options = ChatOptions(temperature: 0.2, maxTokens: nil, stream: false)
        let response = try await client.completeChat(messages: messages, model: model, options: options)
        return AnalysisResult(textSummary: response.message.content)
    }

    /// High-level helper that decides whether to treat the attachment as an
    /// image or text file based on its MIME type and passes appropriate data
    /// into the lower-level analysis helpers.
    func analyzeAttachment(_ attachment: FileAttachmentDetail, hints: String? = nil) async throws -> AnalysisResult {
        if let mime = attachment.mimeType, mime.hasPrefix("image/"), let url = attachment.url {
            let data = try Data(contentsOf: url)
            return try await analyzeImage(data: data, hints: hints)
        }

        // Fallback: treat as a text-like file if we can read UTF-8; otherwise
        // ask the model to reason about the filename only.
        if let url = attachment.url {
            let data = try Data(contentsOf: url)
            if let text = String(data: data, encoding: .utf8) {
                return try await analyzeFile(text: text, hints: hints)
            }
        }

        let name = attachment.name
        let syntheticText = "The user provided a file named '\(name)'. Provide suggestions for how they might use or interpret this file, given only the filename."
        return try await analyzeFile(text: syntheticText, hints: hints)
    }

    func analyzeFile(text: String, hints: String? = nil) async throws -> AnalysisResult {
        // Use the best available chat model.
        guard let caps = environment.capabilities.sorted(by: { ($0.chatModel ?? "") < ($1.chatModel ?? "") }).last,
              let chatModel = caps.chatModel,
              let client = environment.clients[caps.providerID]
        else {
            throw NSError(
                domain: "ToolService",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "No chat-capable provider configured for file analysis."]
            )
        }

        let instruction = hints ?? "Summarize the attached file and highlight the most important details."
        let messages = [
            LLMMessage(role: .system, content: "You analyze documents for the user."),
            LLMMessage(role: .user, content: instruction + "\n\n---\n\n" + text)
        ]
        let options = ChatOptions(temperature: 0.2, maxTokens: nil, stream: false)
        let response = try await client.completeChat(messages: messages, model: chatModel, options: options)
        return AnalysisResult(textSummary: response.message.content)
    }

    // MARK: - Web search (placeholder)

    struct WebSearchResult {
        let title: String
        let url: URL
        let snippet: String
    }

    /// Allow ToolService to be used wherever ChatToolService is expected.
    nonisolated func currentTime(timezone: TimeZone = .current) -> TimeInfo {
        // implementation unchanged; moved below to satisfy protocol
        let now = Date()
        let utcFormatter = ISO8601DateFormatter()
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let localFormatter = ISO8601DateFormatter()
        localFormatter.timeZone = timezone

        return TimeInfo(
            utcISO8601: utcFormatter.string(from: now),
            timezoneIdentifier: timezone.identifier,
            localISO8601: localFormatter.string(from: now)
        )
    }

    /// Web search implemented by scraping DuckDuckGo's HTML search page (no
    /// API key required). The Instant Answer JSON API (`api.duckduckgo.com`)
    /// only returns factoid cards and is empty for most real queries, so we
    /// use the HTML endpoint which returns full web results.
    func webSearch(query: String, maxResults: Int = 5) async throws -> [WebSearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // ── Primary: DuckDuckGo HTML search ──────────────────────────────
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        // Use a desktop user-agent so DDG returns full results.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw NSError(
                domain: "ToolService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Web search HTTP \(http.statusCode): \(body)"]
            )
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "ToolService",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode search results as UTF-8"]
            )
        }

        let results = Self.parseDDGHTML(html, maxResults: maxResults)
        if !results.isEmpty { return results }

        // ── Fallback: Instant Answer API for factoid queries ─────────────
        return try await webSearchInstantAnswer(query: query, maxResults: maxResults)
    }

    /// Parse DuckDuckGo HTML search results page.
    /// Each organic result lives in a `<div class="result ...">` block with
    /// an `<a class="result__a" href="...">title</a>` and a
    /// `<a class="result__snippet">snippet</a>`.
    private static func parseDDGHTML(_ html: String, maxResults: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        let nsHTML = html as NSString

        // Match result blocks: <a class="result__a" href="URL">TITLE</a>
        // DDG sometimes URL-encodes the href via a redirect; we extract from
        // the `uddg=` parameter or use the href directly.
        let linkPattern = #"<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]+class="result__snippet"[^>]*>(.*?)</a>"#

        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }

        let linkMatches = linkRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
        let snippetMatches = snippetRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

        for (i, match) in linkMatches.enumerated() where results.count < maxResults {
            guard match.numberOfRanges >= 3 else { continue }
            var rawHref = nsHTML.substring(with: match.range(at: 1))
            let rawTitle = nsHTML.substring(with: match.range(at: 2))

            // DDG wraps URLs in a redirect: //duckduckgo.com/l/?uddg=ENCODED_URL&...
            // Extract the actual URL from the uddg parameter.
            if rawHref.contains("uddg="),
               let comps = URLComponents(string: rawHref.hasPrefix("//") ? "https:" + rawHref : rawHref),
               let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
                rawHref = uddg
            }

            guard let url = URL(string: rawHref), url.scheme != nil else { continue }

            let title = Self.stripHTMLTags(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            // Grab the corresponding snippet if available.
            var snippet = ""
            if i < snippetMatches.count, snippetMatches[i].numberOfRanges >= 2 {
                snippet = Self.stripHTMLTags(nsHTML.substring(with: snippetMatches[i].range(at: 1)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            results.append(WebSearchResult(title: title, url: url, snippet: snippet.isEmpty ? title : snippet))
        }

        return results
    }

    /// Simple HTML tag stripper (inline, no dependencies).
    private static func stripHTMLTags(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return input }
        let ns = input as NSString
        var result = regex.stringByReplacingMatches(in: input, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "")
        // Decode common entities
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        return result
    }

    /// Fallback: DuckDuckGo Instant Answer API for factoid/direct-answer queries.
    private func webSearchInstantAnswer(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        let url = components.url!
        let (data, _) = try await URLSession.shared.data(from: url)

        struct DDGTopic: Decodable {
            let FirstURL: String?
            let Text: String?
            let topics: [DDGTopic]?
            private enum CodingKeys: String, CodingKey {
                case FirstURL, Text
                case topics = "Topics"
            }
        }
        struct DDGResponse: Decodable {
            let RelatedTopics: [DDGTopic]
            let AbstractText: String?
            let AbstractURL: String?
            let Answer: String?
        }

        guard let decoded = try? JSONDecoder().decode(DDGResponse.self, from: data) else { return [] }

        var results: [WebSearchResult] = []
        if let answer = decoded.Answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallbackURL = URL(string: decoded.AbstractURL ?? "https://duckduckgo.com/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")!
            results.append(WebSearchResult(title: "Answer: \(answer)", url: fallbackURL, snippet: answer))
        }

        func flatten(_ topic: DDGTopic) -> [DDGTopic] {
            if let nested = topic.topics, !nested.isEmpty { return nested.flatMap(flatten) }
            return [topic]
        }
        for t in decoded.RelatedTopics.flatMap(flatten) {
            guard results.count < maxResults,
                  let urlString = t.FirstURL, let url = URL(string: urlString),
                  let text = t.Text, !text.isEmpty else { continue }
            results.append(WebSearchResult(title: text, url: url, snippet: text))
        }
        return results
    }

    // MARK: - Web Browse

    struct WebBrowseResult {
        let url: URL
        let title: String?
        let content: String
        let contentLength: Int
        let truncated: Bool
    }

    /// Fetch a URL and extract its text content.
    /// - Parameters:
    ///   - url: The URL to fetch.
    ///   - maxLength: Maximum content length to return.
    /// - Returns: WebBrowseResult with extracted content.
    func webBrowse(url: URL, maxLength: Int = 5000) async throws -> WebBrowseResult {
        // Validate URL scheme
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw NSError(
                domain: "ToolService",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "Only HTTP and HTTPS URLs are supported."]
            )
        }

        // Create request with a reasonable user agent
        var request = URLRequest(url: url)
        request.setValue("AICoven/1.0 (Local AI Assistant)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        // Download the full body in one efficient call
        let maxDownloadSize = 10 * 1024 * 1024 // 10 MB
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ToolService",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response from server."]
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "ToolService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP error \(httpResponse.statusCode) fetching URL."]
            )
        }

        // Truncate if the response exceeds size limit
        let usableData = data.count > maxDownloadSize ? data.prefix(maxDownloadSize) : data

        // Decode content as text
        guard let html = String(data: usableData, encoding: .utf8) ?? String(data: usableData, encoding: .isoLatin1) else {
            throw NSError(
                domain: "ToolService",
                code: -32,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode page content as text."]
            )
        }

        // Extract title
        let title = extractTitle(from: html)

        // Extract text content (strip HTML tags)
        var textContent = stripHTML(html)

        // Clean up whitespace
        textContent = textContent
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        // Truncate if necessary
        let truncated = textContent.count > maxLength
        if truncated {
            textContent = String(textContent.prefix(maxLength)) + "\n... [content truncated]"
        }

        return WebBrowseResult(
            url: url,
            title: title,
            content: textContent,
            contentLength: textContent.count,
            truncated: truncated
        )
    }

    /// Extract the page title from HTML.
    private func extractTitle(from html: String) -> String? {
        // Simple regex to find <title>...</title>
        let pattern = "<title[^>]*>(.*?)</title>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }

        let nsHTML = html as NSString
        if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length)),
           match.numberOfRanges >= 2 {
            let titleRange = match.range(at: 1)
            let title = nsHTML.substring(with: titleRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Decode HTML entities
            return decodeHTMLEntities(title)
        }

        return nil
    }

    /// Strip HTML tags from content.
    private func stripHTML(_ html: String) -> String {
        var result = html

        // Remove script and style blocks
        let blockPatterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<noscript[^>]*>[\\s\\S]*?</noscript>",
            "<nav[^>]*>[\\s\\S]*?</nav>",
            "<header[^>]*>[\\s\\S]*?</header>",
            "<footer[^>]*>[\\s\\S]*?</footer>"
        ]

        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
            }
        }

        // Replace block elements with newlines
        let blockElements = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "<br>", "<br/>", "<br />"]
        for element in blockElements {
            result = result.replacingOccurrences(of: element, with: "\n", options: .caseInsensitive)
        }

        // Remove all remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }

        // Decode HTML entities
        result = decodeHTMLEntities(result)

        return result
    }

    /// Decode common HTML entities.
    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
            ("&copy;", "©"),
            ("&reg;", "®"),
            ("&trade;", "™")
        ]

        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }

        // Handle numeric entities like &#8217;
        // Process matches in reverse order to avoid offset calculation issues
        // when mixing Swift String (grapheme clusters) with NSString (UTF-16 units).
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            var nsResult = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsResult.length))

            // Reverse iteration: later matches are replaced first, so their
            // ranges remain valid since we haven't modified earlier parts.
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let codeRange = match.range(at: 1)
                let codeString = nsResult.substring(with: codeRange)

                if let code = Int(codeString),
                   let scalar = Unicode.Scalar(code) {
                    let replacement = String(Character(scalar))
                    // Use NSString API consistently for replacement
                    nsResult = nsResult.replacingCharacters(in: match.range, with: replacement) as NSString
                }
            }
            result = nsResult as String
        }

        return result
    }
}
