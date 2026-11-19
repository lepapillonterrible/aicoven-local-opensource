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
        do {
            return try await listedTools()
        } catch let error as MCPClientError {
            throw withoutToken(error)
        }
    }

    private func listedTools() async throws -> [MCPToolDefinition] {
        var tools: [MCPToolDefinition] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0 ..< Self.mostPages {
            let result = try await request("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            let page = try Self.decode(MCPListToolsResponse.self, from: result)
            tools += page.tools
            // A missing cursor is the end.
            guard let next = page.nextCursor else { return tools }
            // One already followed would go round for ever: what was read
            // is then not the whole list, and is not given as one.
            guard seen.insert(next).inserted else { throw MCPClientError.invalidResponse("the tool list repeats") }
            cursor = next
        }
        throw MCPClientError.invalidResponse("the tool list does not end")
    }

    /// Calls a tool. `tool` is its definition as the server listed it,
    /// where known: the current revision sends the arguments its schema
    /// marks for it as headers too. Throws `toolFailed` with what the tool
    /// said if it ran and reported an error.
    func callTool(name: String, arguments: [String: AnyJSONValue], tool: MCPToolDefinition? = nil) async throws -> [MCPContentItem] {
        do {
            return try await called(name, arguments: arguments, tool: tool)
        } catch let error as MCPClientError {
            throw withoutToken(error)
        }
    }

    private func called(_ name: String, arguments: [String: AnyJSONValue], tool: MCPToolDefinition?) async throws -> [MCPContentItem] {
        let params: [String: Any] = ["name": name, "arguments": arguments.mapValues(Self.plain)]
        let result = try await request("tools/call", params: params, name: name, parameterHeaders: Self.parameterHeaders(for: arguments, schema: tool?.inputSchema))
        let response = try Self.decode(MCPCallToolResponse.self, from: result)
        // Nothing of what a server answers is given on with this
        // connection's token in it: not a piece's text, nor its kind.
        var content = response.content.map { MCPContentItem(type: withoutToken($0.type), text: $0.text.map(withoutToken)) }
        // A tool that answers only with structured content is still read.
        if !content.contains(where: { $0.text?.isEmpty == false }), let structured = response.structuredContent,
           let data = try? JSONSerialization.data(withJSONObject: Self.plain(structured), options: [.fragmentsAllowed, .sortedKeys]) {
            content.append(MCPContentItem(type: "text", text: withoutToken(String(decoding: data, as: UTF8.self))))
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
        await endSession()
    }

    /// Tells the server its session is over, if it gave one, and forgets
    /// it. A server may refuse to end sessions (405); either way it is
    /// over here.
    private func endSession() async {
        guard let sessionID, let url = URL(string: server.serverUrl) else { return }
        self.sessionID = nil
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if let legacyVersion {
            request.setValue(legacyVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        authorize(&request)
        _ = try? await session.data(for: request)
    }

    // MARK: - Requests

    /// How a request is put: as the current revision has it, as the
    /// greeting of an earlier one, or as what follows that greeting.
    private enum Form {
        case modern
        case greeting
        case legacy
    }

    /// One request and its result, in whichever protocol the server speaks.
    private func request(_ method: String, params: [String: Any], name: String? = nil, parameterHeaders: [String: String] = [:]) async throws -> [String: Any] {
        let era = try await settledEra()
        let form: Form = era == .modern ? .modern : .legacy
        var reply = try await post(method, params: params, as: form, name: name, parameterHeaders: parameterHeaders)
        // The session is gone: a new one is started, once, and the request
        // made again. It was not carried out without its session.
        if era == .legacy, reply.status == 404, sessionID != nil {
            sessionID = nil
            // Nothing is settled again until the new greeting is answered.
            self.era = nil
            try await initialize()
            self.era = .legacy
            reply = try await post(method, params: params, as: .legacy, name: name, parameterHeaders: parameterHeaders)
        }
        return try result(of: reply)
    }

    /// Which protocol the server speaks, found out once per server. Set
    /// only once it is known: a probe or a greeting that fails leaves
    /// nothing settled, here or in the cache.
    private func settledEra() async throws -> MCPEra {
        if let era { return era }
        switch eras.era(of: server.serverUrl) {
        case .modern:
            break
        case .legacy:
            try await initialize()
        case nil:
            try await probe()
        }
        let settled: MCPEra = legacyVersion == nil ? .modern : .legacy
        era = settled
        eras.note(settled, for: server.serverUrl)
        return settled
    }

    /// Asks the server to describe itself, as the current revision has it.
    /// A server that does not know the question is an earlier one, and is
    /// greeted.
    private func probe() async throws {
        let reply = try await post("server/discover", params: [:], as: .modern)
        // A refusal is a refusal, whatever it says of itself.
        guard reply.status != 401, reply.status != 403, reply.status < 500 else { throw MCPClientError.refused(status: reply.status) }
        if (200 ..< 300).contains(reply.status), reply.error == nil, reply.message?["result"] != nil {
            let result = try result(of: reply)
            let supported = result["supportedVersions"] as? [String] ?? [Self.modernVersion]
            guard supported.contains(Self.modernVersion) else { throw MCPClientError.unsupportedVersion(supported: supported) }
            return
        }
        if let error = reply.error {
            switch error.code {
            case -32022:
                // A current server, of other versions than this one.
                throw MCPClientError.unsupportedVersion(supported: error.supported)
            case -32020, -32021:
                throw MCPClientError.serverError(code: error.code, message: withoutToken(error.message))
            default:
                break
            }
        }
        // Anything else (it does not know the method, or wants a session):
        // an earlier server, to be greeted first.
        try await initialize()
    }

    /// The handshake of the earlier revisions. On success the version and
    /// the session (if the server gives one) are kept; on any failure
    /// neither is, and a session the server did give is ended.
    private func initialize() async throws {
        legacyVersion = nil
        sessionID = nil
        let reply = try await post("initialize", params: [
            "protocolVersion": Self.legacyVersions[0],
            "capabilities": [String: Any](),
            "clientInfo": Self.clientInfo,
        ], as: .greeting)
        guard let result = reply.message?["result"] as? [String: Any], (200 ..< 300).contains(reply.status) else {
            if let error = reply.error { throw MCPClientError.serverError(code: error.code, message: withoutToken(error.message)) }
            // No answer to `initialize` at this address: the old transport,
            // whose address only takes a GET.
            throw [400, 404, 405].contains(reply.status) ? MCPClientError.oldTransport : MCPClientError.refused(status: reply.status)
        }
        sessionID = reply.sessionID
        do {
            try Self.requireWhole(result)
            guard let version = result["protocolVersion"] as? String, Self.legacyVersions.contains(version) else {
                throw MCPClientError.unsupportedVersion(supported: [result["protocolVersion"] as? String].compactMap(\.self))
            }
            legacyVersion = version
            let acknowledged = try await post("notifications/initialized", params: nil, as: .legacy, isNotification: true)
            guard (200 ..< 300).contains(acknowledged.status) else { throw MCPClientError.refused(status: acknowledged.status) }
        } catch {
            await endSession()
            legacyVersion = nil
            throw error
        }
    }

    /// The result in a reply, or what the server said went wrong.
    private func result(of reply: Reply) throws -> [String: Any] {
        if let error = reply.error {
            if error.code == -32022 { throw MCPClientError.unsupportedVersion(supported: error.supported) }
            throw MCPClientError.serverError(code: error.code, message: withoutToken(error.message))
        }
        guard (200 ..< 300).contains(reply.status) else { throw MCPClientError.refused(status: reply.status) }
        guard let result = reply.message?["result"] as? [String: Any] else {
            throw MCPClientError.invalidResponse("no result")
        }
        try Self.requireWhole(result)
        return result
    }

    /// The current revision says whether a result is whole; an earlier
    /// server says nothing, which is whole. One that asks for input first
    /// cannot be answered here; anything else it might say is not a
    /// result this protocol has.
    private static func requireWhole(_ result: [String: Any]) throws {
        guard let type = result["resultType"] else { return }
        switch type as? String {
        case "complete": return
        case "input_required": throw MCPClientError.needsInput
        case let other?: throw MCPClientError.invalidResponse("result type \(other.prefix(40))")
        case nil: throw MCPClientError.invalidResponse("result type")
        }
    }

    /// `text` without this connection's token, should a server say it back.
    private func withoutToken(_ text: String) -> String {
        guard let token, token.count >= 8 else { return text }
        return text.replacingOccurrences(of: token, with: "[token]")
    }

    /// An error without the token in anything it quotes of the server.
    private func withoutToken(_ error: MCPClientError) -> MCPClientError {
        switch error {
        case let .serverError(code, message): .serverError(code: code, message: withoutToken(message))
        case let .invalidResponse(what): .invalidResponse(withoutToken(what))
        case let .unsupportedVersion(supported): .unsupportedVersion(supported: supported.map(withoutToken))
        case let .toolFailed(what): .toolFailed(withoutToken(what))
        case .invalidURL, .notReached, .refused, .oldTransport, .needsInput, .tooLarge: error
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
        as form: Form,
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
        switch form {
        case .modern:
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
        case .greeting:
            break
        case .legacy:
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

/// A tool as this app keeps it, of what a server listed.
struct MCPToolDefinition: Codable, Equatable, Identifiable {
    let name: String
    let description: String?
    let inputSchema: [String: AnyJSONValue]
    /// Whether the server marks the tool as one that changes nothing
    /// (`annotations.readOnlyHint` in its list). Only true counts: a tool
    /// not marked is taken for one that changes things.
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

    /// As the app stored it. One stored before the mark was kept reads as
    /// not marked. (A server's list is read by `MCPListToolsResponse`,
    /// where the mark is under `annotations`.)
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decode([String: AnyJSONValue].self, forKey: .inputSchema)
        readOnlyHint = try container.decodeIfPresent(Bool.self, forKey: .readOnlyHint) ?? false
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encode(readOnlyHint, forKey: .readOnlyHint)
    }

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, readOnlyHint
    }
}

/// One page of a server's tools, as the server sends it. A tool with no
/// name is left out, and the rest are still taken. A tool listed with no
/// input schema, or one that is not an object, is kept with the schema of
/// an object that says nothing more. Whether a tool only reads is what
/// its `annotations.readOnlyHint` says, and nothing else.
struct MCPListToolsResponse: Decodable {
    let tools: [MCPToolDefinition]
    let nextCursor: String?

    private struct Listed: Decodable {
        let tool: MCPToolDefinition?

        enum CodingKeys: String, CodingKey {
            case name, description, inputSchema, annotations
        }

        nonisolated init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                  let name = try? container.decode(String.self, forKey: .name) else {
                tool = nil
                return
            }
            let annotations = try? container.decodeIfPresent([String: AnyJSONValue].self, forKey: .annotations)
            tool = MCPToolDefinition(
                name: name,
                description: try? container.decodeIfPresent(String.self, forKey: .description),
                inputSchema: (try? container.decodeIfPresent([String: AnyJSONValue].self, forKey: .inputSchema)) ?? ["type": "object"],
                readOnlyHint: annotations?["readOnlyHint"] == .bool(true)
            )
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
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
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

/// What a tool answered. A result that is not what the protocol has is
/// not read as an empty one: its `content` must be a list of typed pieces
/// (it may be left out only where there is structured content instead),
/// and `isError`, where given, true or false.
struct MCPCallToolResponse: Decodable {
    let content: [MCPContentItem]
    let isError: Bool?
    let structuredContent: AnyJSONValue?

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let structured = container.contains(.structuredContent) ? try container.decode(AnyJSONValue.self, forKey: .structuredContent) : nil
        structuredContent = structured == .null ? nil : structured
        if container.contains(.content) || structuredContent == nil {
            content = try container.decode([MCPContentItem].self, forKey: .content)
        } else {
            content = []
        }
        isError = container.contains(.isError) ? try container.decode(Bool.self, forKey: .isError) : nil
    }

    enum CodingKeys: String, CodingKey {
        case content, isError, structuredContent
    }
}
