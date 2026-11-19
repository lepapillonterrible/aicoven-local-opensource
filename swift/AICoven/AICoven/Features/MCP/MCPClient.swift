import Foundation
import os

/// What can go wrong talking to an MCP server. The texts are shown to the
/// person and given to the model; none carries a token or a server's
/// whole answer.
enum MCPClientError: LocalizedError, Equatable {
    case invalidURL
    /// The server could not be reached, or stopped answering.
    case notReached
    /// It answered with an HTTP failure and nothing that says why.
    case refused(status: Int)
    /// It answered the request with a JSON-RPC error.
    case serverError(code: Int?, message: String)
    /// Its answer is not one this protocol has.
    case invalidResponse(String)
    /// It speaks only versions of the protocol this app does not.
    case unsupportedVersion(supported: [String])
    /// It speaks only the older HTTP+SSE transport.
    case oldTransport
    /// It asked the person for input mid-call, which this app cannot give.
    case needsInput
    /// Its answer is larger than is read.
    case tooLarge
    /// The tool ran and reported an error of its own.
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid MCP server URL"
        case .notReached: "The MCP server could not be reached."
        case let .refused(status) where status == 401 || status == 403:
            "The MCP server refused the connection (HTTP \(status)). Retrying will not help: check this server's token in Settings > Connected Apps > MCP Servers and run Test."
        case let .refused(status): "The MCP server answered with HTTP \(status)."
        case let .serverError(_, message): "MCP server error: \(message)"
        case let .invalidResponse(what): "Invalid response from the MCP server: \(what)"
        case let .unsupportedVersion(supported):
            supported.isEmpty
                ? "This MCP server speaks a version of the protocol this app does not."
                : "This MCP server speaks versions of the protocol this app does not: \(supported.prefix(6).joined(separator: ", "))."
        case .oldTransport: "This MCP server speaks only the older SSE transport, which this app does not speak yet."
        case .needsInput: "The MCP server asked for input this app cannot give."
        case .tooLarge: "The MCP server's answer is too large to read."
        case let .toolFailed(what): what
        }
    }
}

/// Which protocol a server speaks: the current one, where every request
/// says its version and there is no session, or an earlier one, which
/// starts with an `initialize` handshake.
nonisolated enum MCPEra: Equatable {
    case modern
    case legacy
}

/// What is known of each server's protocol, for as long as the app runs:
/// a server is asked which it speaks once, not before every call.
final nonisolated class MCPEraCache: Sendable {
    static let shared = MCPEraCache()

    private let eras = OSAllocatedUnfairLock(initialState: [String: MCPEra]())

    func era(of server: String) -> MCPEra? {
        eras.withLock { $0[server] }
    }

    func note(_ era: MCPEra?, for server: String) {
        eras.withLock { $0[server] = era }
    }
}

/// An MCP (Model Context Protocol) client over Streamable HTTP: it lists a
/// server's tools and calls them.
///
/// It speaks the current revision of the protocol (2026-07-28: no
/// handshake, each request carrying its version, and the method and tool
/// name in headers) and falls back to the earlier ones (2025-11-25 and
/// before: `initialize`, `notifications/initialized`, a session id), as
/// the specification says a client may: a current request first, and
/// `initialize` if the server does not know it. The deprecated HTTP+SSE
/// transport is not spoken.
actor MCPClient {
    /// The current revision, and the earlier ones this client can speak
    /// after an `initialize`, newest first.
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The most bytes of one answer that are read.
    static let largestAnswer = 16 * 1024 * 1024
    /// The most pages of a tool list that are followed.
    static let mostPages = 100

    let server: MCPServerAccount
    let token: String?

    private let session: URLSession
    private let eras: MCPEraCache
    private var era: MCPEra?
    /// What `initialize` settled, for a server of an earlier revision.
    private var legacyVersion: String?
    private var sessionID: String?

    init(server: MCPServerAccount, token: String?, session: URLSession? = nil, eras: MCPEraCache = .shared) {
        self.server = server
        self.token = token
        self.eras = eras
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Tools

    /// The server's tools, every page of them.
    func discoverTools() async throws -> [MCPToolDefinition] {
        var tools: [MCPToolDefinition] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0 ..< Self.mostPages {
            let result = try await request("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            let page = try Self.decode(MCPListToolsResponse.self, from: result)
            tools += page.tools
            // A missing cursor is the end; one already followed would go
            // round for ever.
            guard let next = page.nextCursor, seen.insert(next).inserted else { return tools }
            cursor = next
        }
        return tools
    }

    /// Calls a tool. `tool` is its definition as the server listed it,
    /// where known: the current revision sends the arguments its schema
    /// marks for it as headers too. Throws `toolFailed` with what the tool
    /// said if it ran and reported an error.
    func callTool(name: String, arguments: [String: AnyJSONValue], tool: MCPToolDefinition? = nil) async throws -> [MCPContentItem] {
        let params: [String: Any] = ["name": name, "arguments": arguments.mapValues(Self.plain)]
        let result = try await request("tools/call", params: params, name: name, parameterHeaders: Self.parameterHeaders(for: arguments, schema: tool?.inputSchema))
        let response = try Self.decode(MCPCallToolResponse.self, from: result)
        var content = response.content
        // A tool that answers only with structured content is still read.
        if !content.contains(where: { $0.text?.isEmpty == false }), let structured = response.structuredContent,
           let data = try? JSONSerialization.data(withJSONObject: Self.plain(structured), options: [.fragmentsAllowed, .sortedKeys]) {
            content.append(MCPContentItem(type: "text", text: String(decoding: data, as: UTF8.self)))
        }
        if response.isError == true {
            let said = content.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            throw MCPClientError.toolFailed(said.isEmpty ? "The tool reported an error." : said)
        }
        return content
    }

    /// Ends the session, where the server gave one. Nothing is kept open
    /// otherwise.
    func disconnect() async {
        guard era == .legacy, let sessionID, let url = URL(string: server.serverUrl) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if let legacyVersion {
            request.setValue(legacyVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        authorize(&request)
        self.sessionID = nil
        // A server may refuse to end sessions (405); either way it is over here.
        _ = try? await session.data(for: request)
    }

    // MARK: - Requests

    /// One request and its result, in whichever protocol the server speaks.
    private func request(_ method: String, params: [String: Any], name: String? = nil, parameterHeaders: [String: String] = [:]) async throws -> [String: Any] {
        try await settleEra()
        var reply = try await post(method, params: params, name: name, parameterHeaders: parameterHeaders)
        // The session is gone: a new one is started, once, and the request
        // made again. It was not carried out without its session.
        if era == .legacy, reply.status == 404, sessionID != nil {
            sessionID = nil
            try await initialize()
            reply = try await post(method, params: params, name: name, parameterHeaders: parameterHeaders)
        }
        return try result(of: reply)
    }

    /// Finds out which protocol the server speaks, once per server.
    private func settleEra() async throws {
        guard era == nil else { return }
        switch eras.era(of: server.serverUrl) {
        case .modern:
            era = .modern
        case .legacy:
            try await initialize()
        case nil:
            try await probe()
        }
    }

    /// Asks the server to describe itself, as the current revision has it.
    /// A server that does not know the question is an earlier one.
    private func probe() async throws {
        era = .modern
        do {
            try await discover()
        } catch {
            // Nothing is settled by a probe that failed.
            if era == .modern { era = nil }
            throw error
        }
    }

    private func discover() async throws {
        let reply = try await post("server/discover", params: [:])
        if let result = reply.message?["result"] as? [String: Any], (200 ..< 300).contains(reply.status) {
            let supported = result["supportedVersions"] as? [String] ?? [Self.modernVersion]
            guard supported.contains(Self.modernVersion) else { throw MCPClientError.unsupportedVersion(supported: supported) }
            eras.note(.modern, for: server.serverUrl)
            return
        }
        if let error = reply.error {
            switch error.code {
            case -32022:
                // A current server, of other versions than this one.
                throw MCPClientError.unsupportedVersion(supported: error.supported)
            case -32020, -32021:
                throw MCPClientError.serverError(code: error.code, message: error.message)
            default:
                break
            }
        }
        guard reply.status != 401, reply.status != 403, reply.status < 500 else { throw MCPClientError.refused(status: reply.status) }
        // Anything else (it does not know the method, or wants a session):
        // an earlier server, to be greeted first.
        era = nil
        try await initialize()
    }

    /// The handshake of the earlier revisions.
    private func initialize() async throws {
        era = .legacy
        legacyVersion = nil
        sessionID = nil
        let reply = try await post("initialize", params: [
            "protocolVersion": Self.legacyVersions[0],
            "capabilities": [String: Any](),
            "clientInfo": Self.clientInfo,
        ])
        guard let result = reply.message?["result"] as? [String: Any], (200 ..< 300).contains(reply.status) else {
            era = nil
            if let error = reply.error { throw MCPClientError.serverError(code: error.code, message: error.message) }
            // No answer to `initialize` at this address: the old transport,
            // whose address only takes a GET.
            throw [400, 404, 405].contains(reply.status) ? MCPClientError.oldTransport : MCPClientError.refused(status: reply.status)
        }
        guard let version = result["protocolVersion"] as? String, Self.legacyVersions.contains(version) else {
            era = nil
            throw MCPClientError.unsupportedVersion(supported: [result["protocolVersion"] as? String].compactMap(\.self))
        }
        legacyVersion = version
        sessionID = reply.sessionID
        let acknowledged = try await post("notifications/initialized", params: nil, isNotification: true)
        guard (200 ..< 300).contains(acknowledged.status) else {
            era = nil
            throw MCPClientError.refused(status: acknowledged.status)
        }
        eras.note(.legacy, for: server.serverUrl)
    }

    /// The result in a reply, or what the server said went wrong.
    private func result(of reply: Reply) throws -> [String: Any] {
        if let error = reply.error {
            if error.code == -32022 { throw MCPClientError.unsupportedVersion(supported: error.supported) }
            throw MCPClientError.serverError(code: error.code, message: error.message)
        }
        guard (200 ..< 300).contains(reply.status) else { throw MCPClientError.refused(status: reply.status) }
        guard let result = reply.message?["result"] as? [String: Any] else {
            throw MCPClientError.invalidResponse("no result")
        }
        // The current revision says whether a result is whole. One that
        // asks for input first cannot be answered here.
        switch result["resultType"] as? String {
        case nil, "complete": return result
        case "input_required": throw MCPClientError.needsInput
        case let other?: throw MCPClientError.invalidResponse("result type \(other.prefix(40))")
        }
    }

    // MARK: - The wire

    /// What came back for one POST.
    private struct Reply {
        var status: Int
        /// The JSON-RPC message that answers the request, if one came.
        var message: [String: Any]?
        var sessionID: String?

        var error: (code: Int, message: String, supported: [String])? {
            guard let error = message?["error"] as? [String: Any] else { return nil }
            let said = (error["message"] as? String).map { String($0.prefix(300)) } ?? "The server reported an error."
            let supported = (error["data"] as? [String: Any])?["supported"] as? [String] ?? []
            return (error["code"] as? Int ?? 0, said, supported)
        }
    }

    private func post(
        _ method: String,
        params: [String: Any]?,
        name: String? = nil,
        parameterHeaders: [String: String] = [:],
        isNotification: Bool = false
    ) async throws -> Reply {
        guard let url = URL(string: server.serverUrl), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MCPClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&request)

        let id = UUID().uuidString
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !isNotification { body["id"] = id }
        var params = params
        if era == .modern {
            // Each request says the version it is in, and who asks.
            request.setValue(Self.modernVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if let name {
                request.setValue(Self.headerValue(name), forHTTPHeaderField: "Mcp-Name")
            }
            for (header, value) in parameterHeaders {
                request.setValue(value, forHTTPHeaderField: header)
            }
            var meta = (params?["_meta"] as? [String: Any]) ?? [:]
            meta["io.modelcontextprotocol/protocolVersion"] = Self.modernVersion
            meta["io.modelcontextprotocol/clientInfo"] = Self.clientInfo
            meta["io.modelcontextprotocol/clientCapabilities"] = [String: Any]()
            params = (params ?? [:]).merging(["_meta": meta]) { _, new in new }
        } else if method != "initialize" {
            if let legacyVersion {
                request.setValue(legacyVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            }
            if let sessionID {
                request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }
        }
        if let params { body["params"] = params }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw MCPClientError.invalidResponse("not HTTP") }
            var reply = Reply(status: http.statusCode, sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id"))
            let isStream = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("text/event-stream")
            if isStream, (200 ..< 300).contains(http.statusCode) {
                reply.message = try await Self.answer(to: id, inEventsOf: bytes)
            } else {
                reply.message = try await Self.message(in: bytes)
            }
            return reply
        } catch let error as MCPClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw MCPClientError.notReached
        }
    }

    private func authorize(_ request: inout URLRequest) {
        guard let token, !token.isEmpty else { return }
        switch server.authType {
        case .bearer: request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey: request.setValue(token, forHTTPHeaderField: "X-Api-Key")
        case .none: break
        }
    }

    /// A plain JSON answer: the one JSON-RPC message in the body, or nil
    /// for no body (a notification taken) or one that is not a message.
    private static func message(in bytes: URLSession.AsyncBytes) async throws -> [String: Any]? {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= largestAnswer else { throw MCPClientError.tooLarge }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// An answer as a stream of events: the message that answers request
    /// `id`. What the server sends before it (progress, log lines) is
    /// passed over, and reading stops at the answer.
    private static func answer(to id: String, inEventsOf bytes: URLSession.AsyncBytes) async throws -> [String: Any]? {
        var reader = MCPEventReader()
        var read = 0
        for try await byte in bytes {
            read += 1
            guard read <= largestAnswer else { throw MCPClientError.tooLarge }
            if let event = reader.take(byte), let message = answer(to: id, in: event) { return message }
        }
        return reader.finish().flatMap { answer(to: id, in: $0) }
    }

    /// The event's message, if it is the answer to request `id`.
    static func answer(to id: String, in event: String) -> [String: Any]? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(event.utf8))) as? [String: Any],
              message["id"] as? String == id, message["result"] != nil || message["error"] != nil else { return nil }
        return message
    }

    private static func decode<Value: Decodable>(_: Value.Type, from result: [String: Any]) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: result))
        } catch {
            throw MCPClientError.invalidResponse("not what was asked for")
        }
    }

    // MARK: - What is sent

    /// A JSON value as the system's JSON writer takes it, all the way down.
    static func plain(_ value: AnyJSONValue) -> Any {
        switch value {
        case let .string(text): text
        case let .int(number): number
        case let .double(number): number
        case let .bool(flag): flag
        case let .dictionary(members): members.mapValues(plain)
        case let .array(elements): elements.map(plain)
        case .null: NSNull()
        }
    }

    /// Who asks, as the server is told.
    static var clientInfo: [String: Any] {
        ["name": "AICoven Local", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"]
    }

    /// A header's value for a name or an argument: as it is where it is
    /// plain ASCII, else (or if it reads as the wrapped form itself)
    /// wrapped as `=?base64?…?=`, as the current revision has it.
    static func headerValue(_ value: String) -> String {
        let isPlain = value.unicodeScalars.allSatisfy { (0x20 ... 0x7E).contains($0.value) }
            && value == value.trimmingCharacters(in: .whitespaces)
            && !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        return isPlain ? value : "=?base64?\(Data(value.utf8).base64EncodedString())?="
    }

    /// The headers the current revision wants for a call's arguments: for
    /// each property the tool's schema marks with `x-mcp-header`, the
    /// argument given for it, where it is text, a number or true or false.
    static func parameterHeaders(for arguments: [String: AnyJSONValue], schema: [String: AnyJSONValue]?) -> [String: String] {
        guard case let .dictionary(properties)? = schema?["properties"] else { return [:] }
        var headers: [String: String] = [:]
        for (property, described) in properties {
            guard case let .dictionary(description) = described, case let .string(header)? = description["x-mcp-header"],
                  !header.isEmpty, header.unicodeScalars.allSatisfy({ CharacterSet.mcpHeaderToken.contains($0) }),
                  let argument = arguments[property] else { continue }
            let value: String
            switch argument {
            case let .string(text): value = text
            case let .int(number): value = String(number)
            case let .double(number): value = String(number)
            case let .bool(flag): value = flag ? "true" : "false"
            case .dictionary, .array, .null: continue
            }
            headers["Mcp-Param-\(header)"] = headerValue(value)
        }
        return headers
    }
}

private extension CharacterSet {
    /// The characters an HTTP header's name is made of.
    static let mcpHeaderToken = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
}

/// Reads a stream of server-sent events a byte at a time and gives each
/// event's data as it ends: its `data:` lines joined by new lines. Comment
/// lines and other fields are passed over.
nonisolated struct MCPEventReader {
    private var line: [UInt8] = []
    private var data: [String] = []

    /// Takes the next byte; returns an event's data if the byte ends one.
    mutating func take(_ byte: UInt8) -> String? {
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        // An empty line ends the event.
        guard !line.isEmpty else { return finish() }
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix("data:") {
            let value = text.dropFirst(5)
            data.append(String(value.hasPrefix(" ") ? value.dropFirst() : value))
        }
        return nil
    }

    /// What was read of an event the stream ended in, if anything.
    mutating func finish() -> String? {
        if !line.isEmpty {
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("data:") {
                let value = text.dropFirst(5)
                data.append(String(value.hasPrefix(" ") ? value.dropFirst() : value))
            }
            line.removeAll()
        }
        guard !data.isEmpty else { return nil }
        defer { data.removeAll() }
        return data.joined(separator: "\n")
    }
}

// MARK: - MCP Models

/// A tool as a server lists it: what is kept of it.
struct MCPToolDefinition: Codable, Equatable, Identifiable {
    let name: String
    let description: String?
    let inputSchema: [String: AnyJSONValue]
    /// Whether the server marks the tool as one that changes nothing
    /// (`annotations.readOnlyHint`). Only true counts: a tool not marked
    /// is taken for one that changes things.
    let readOnlyHint: Bool

    var id: String {
        name
    }

    nonisolated init(name: String, description: String?, inputSchema: [String: AnyJSONValue], readOnlyHint: Bool = false) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
    }

    /// From a server's list (the mark under `annotations`) or from what
    /// this app kept of one (the mark beside the name). A tool listed
    /// without a schema takes no arguments.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = (try? container.decodeIfPresent([String: AnyJSONValue].self, forKey: .inputSchema)) ?? ["type": "object"]
        let annotated = (try? container.decodeIfPresent([String: AnyJSONValue].self, forKey: .annotations))?["readOnlyHint"]
        let kept = try? container.decodeIfPresent(Bool.self, forKey: .readOnlyHint)
        readOnlyHint = kept ?? (annotated == .bool(true))
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encode(readOnlyHint, forKey: .readOnlyHint)
    }

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, annotations, readOnlyHint
    }
}

/// One page of a server's tools. A tool that cannot be read (it has no
/// name) is left out, and the rest are still taken.
struct MCPListToolsResponse: Decodable {
    let tools: [MCPToolDefinition]
    let nextCursor: String?

    private struct Listed: Decodable {
        let tool: MCPToolDefinition?

        nonisolated init(from decoder: Decoder) throws {
            tool = try? MCPToolDefinition(from: decoder)
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decode([Listed].self, forKey: .tools).compactMap(\.tool)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }

    enum CodingKeys: String, CodingKey {
        case tools, nextCursor
    }
}

/// A piece of what a tool answered. Only text is read; of anything else
/// its kind is kept, so it can be said that it was there.
struct MCPContentItem: Decodable, Equatable {
    let type: String
    let text: String?

    nonisolated init(type: String, text: String?) {
        self.type = type
        self.text = text
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
        text = try? container.decodeIfPresent(String.self, forKey: .text)
    }

    /// What the model is given of it.
    nonisolated var shown: String {
        if let text, type == "text" || !text.isEmpty { return text }
        return "[\(type) content, not shown]"
    }

    enum CodingKeys: String, CodingKey {
        case type, text
    }
}

struct MCPCallToolResponse: Decodable {
    let content: [MCPContentItem]
    let isError: Bool?
    let structuredContent: AnyJSONValue?

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? container.decodeIfPresent([MCPContentItem].self, forKey: .content)) ?? []
        isError = try? container.decodeIfPresent(Bool.self, forKey: .isError)
        structuredContent = try? container.decodeIfPresent(AnyJSONValue.self, forKey: .structuredContent)
    }

    enum CodingKeys: String, CodingKey {
        case content, isError, structuredContent
    }
}
