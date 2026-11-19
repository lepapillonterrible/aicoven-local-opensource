import CryptoKit
import Foundation

/// A socket of text frames to an OpenClaw Gateway. The real one is a web
/// socket; tests script one.
protocol OpenClawSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

nonisolated enum OpenClawGatewayError: LocalizedError, Equatable {
    /// Not `ws://` on this machine or `wss://` elsewhere, or it carries a
    /// name, password, query or fragment.
    case invalidAddress
    /// The Gateway did not open with its challenge, or answered the
    /// connect with something that is not its welcome.
    case unexpectedReply
    /// The Gateway speaks another version of its protocol.
    case unsupportedProtocol
    /// The Gateway refused a request: its code and message.
    case refused(code: String, message: String)
    /// The connection ended before the answer came.
    case closed
    /// A frame larger than the Gateway takes, or than this app sends or
    /// takes.
    case tooLarge
    /// The Gateway has no such method, or did not grant the scope it needs.
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a Gateway address that starts with ws:// on this device, or wss:// anywhere else, with no name, password, path or query in it."
        case .unexpectedReply: "The address did not answer as an OpenClaw Gateway."
        case .unsupportedProtocol: "This OpenClaw Gateway speaks a version of its protocol AICoven does not."
        case let .refused(code, message): message.isEmpty ? "The OpenClaw Gateway refused: \(code)." : "The OpenClaw Gateway refused: \(message)"
        case .closed: "The connection to the OpenClaw Gateway closed."
        case .tooLarge: "A message to or from the OpenClaw Gateway was too large."
        case let .notSupported(what): "This OpenClaw Gateway does not offer \(what)."
        }
    }
}

/// This device as an OpenClaw Gateway knows it: a signing key made here and
/// kept in the Keychain. The Gateway is shown its public half, and a
/// signature over each connection's challenge.
nonisolated struct OpenClawDeviceIdentity {
    /// Lowercase hex of the SHA-256 of the public key.
    let deviceID: String
    /// The public key, base64url without padding.
    let publicKey: String
    private let privateKey: Data

    init(privateKey: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let publicKeyData = key.publicKey.rawRepresentation
        deviceID = SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined()
        publicKey = Self.base64URL(publicKeyData)
        self.privateKey = privateKey
    }

    /// The signature over a payload, base64url without padding.
    func signature(for payload: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try Self.base64URL(key.signature(for: Data(payload.utf8)))
    }

    private static let keychainKey = "openclaw-gateway-device-identity.ed25519-v1"

    /// The current account's identity on this device, made the first time
    /// it is asked for.
    static func loadOrCreate() throws -> OpenClawDeviceIdentity {
        if let stored = KeychainHelper.load(key: keychainKey), let key = Data(base64Encoded: stored) {
            return try OpenClawDeviceIdentity(privateKey: key)
        }
        let key = Curve25519.Signing.PrivateKey().rawRepresentation
        try KeychainHelper.save(key: keychainKey, value: key.base64EncodedString())
        return try OpenClawDeviceIdentity(privateKey: key)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What a Gateway said of itself when it welcomed the connection.
nonisolated struct OpenClawGatewayHello: Equatable {
    let methods: Set<String>
    let events: Set<String>
    let scopes: Set<String>
    /// The largest frame the Gateway takes.
    let maxPayload: Int
    /// A token the Gateway issued this device, to connect with next time
    /// where the connection has no token of its own.
    let deviceToken: String?

    /// What a turn needs of a Gateway, and the first thing it lacks.
    static let methodsNeeded = ["chat.send", "sessions.messages.subscribe", "agent.wait", "chat.history", "chat.abort", "approval.resolve"]
    static let eventsNeeded = ["chat", "session.approval"]
    static let scopesNeeded = ["operator.write", "operator.approvals"]

    var missing: String? {
        if let method = Self.methodsNeeded.first(where: { !methods.contains($0) }) { return method }
        if let event = Self.eventsNeeded.first(where: { !events.contains($0) }) { return "\(event) events" }
        if let scope = Self.scopesNeeded.first(where: { !scopes.contains($0) }) { return "the \(scope) scope" }
        return nil
    }
}

/// One event a Gateway sent: its name and its payload, as JSON.
nonisolated struct OpenClawGatewayEvent: Equatable {
    let name: String
    let payload: Data
}

/// One connection to an OpenClaw Gateway, speaking protocol 4: the Gateway
/// opens with a challenge, this side answers with who it is and a signature
/// over the challenge, and the Gateway welcomes it with what it offers.
/// After that, requests get their answers by id, and events arrive in the
/// order the Gateway numbered them.
actor OpenClawGatewayConnection {
    static let protocolVersion = 4
    static let scopes = ["operator.read", "operator.write", "operator.approvals"]
    /// The largest frame sent before the Gateway has said what it takes,
    /// and the most this app sends or keeps whatever the Gateway takes.
    static let firstFrameLimit = 64 * 1024
    static let frameLimit = 25 * 1024 * 1024

    private let socket: OpenClawSocket
    private let identity: OpenClawDeviceIdentity
    private let token: String?
    private let isDeviceToken: Bool
    private let clientVersion: String

    private var nextID = 0
    private var waiting: [String: CheckedContinuation<Data, Error>] = [:]
    private var maxPayload = OpenClawGatewayConnection.firstFrameLimit
    private var lastSequence: Int?
    private var reading: Task<Void, Never>?
    private var ended: Error?
    private let eventsIn: AsyncThrowingStream<OpenClawGatewayEvent, Error>.Continuation

    /// The Gateway's events, in order, from the welcome on. Ends, throwing,
    /// when the connection does.
    nonisolated let events: AsyncThrowingStream<OpenClawGatewayEvent, Error>

    /// `token` is the connection's own token, or one the Gateway issued
    /// this device; `isDeviceToken` says which.
    init(socket: OpenClawSocket, identity: OpenClawDeviceIdentity, token: String?, isDeviceToken: Bool = false, clientVersion: String = "1") {
        self.socket = socket
        self.identity = identity
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.isDeviceToken = isDeviceToken
        self.clientVersion = clientVersion
        (events, eventsIn) = AsyncThrowingStream<OpenClawGatewayEvent, Error>.makeStream()
    }

    /// The address a Gateway may be reached at, from what was typed, or nil:
    /// `ws://` on this machine only, `wss://` anywhere, and nothing in it
    /// that could carry a secret (a name, a password, a query, a fragment)
    /// and no path. A lone trailing slash is dropped.
    static func address(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let isThisMachine = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "wss" || (scheme == "ws" && isThisMachine) else { return nil }
        components.path = ""
        return components.url
    }

    // MARK: - Opening

    /// Completes the handshake, and starts reading. Throws what the Gateway
    /// refused with, if it refused.
    func open() async throws -> OpenClawGatewayHello {
        let challenge = try await frame(socket.receive())
        guard challenge["type"] as? String == "event", challenge["event"] as? String == "connect.challenge",
              let payload = challenge["payload"] as? [String: Any],
              let nonce = payload["nonce"] as? String, !nonce.isEmpty,
              let timestamp = Self.integer(payload["ts"]), timestamp >= 0 else {
            throw OpenClawGatewayError.unexpectedReply
        }
        // What is signed names this device, what it asks to be, the
        // challenge, and the token it shows, so none can be swapped.
        let signed = [
            "v2", identity.deviceID, "gateway-client", "backend", "operator",
            Self.scopes.joined(separator: ","), String(timestamp), token ?? "", nonce,
        ].joined(separator: "|")
        var params: [String: Any] = try [
            "minProtocol": Self.protocolVersion,
            "maxProtocol": Self.protocolVersion,
            "client": ["id": "gateway-client", "displayName": "AICoven Local", "version": clientVersion, "platform": "macos", "mode": "backend"],
            "role": "operator",
            "scopes": Self.scopes,
            "caps": ["session-scoped-events", "chat-only-assistant-text", "approvals", "exec-approvals", "plugin-approvals"],
            "commands": [String](),
            "permissions": [String: Any](),
            "device": [
                "id": identity.deviceID,
                "publicKey": identity.publicKey,
                "signature": identity.signature(for: signed),
                "signedAt": timestamp,
                "nonce": nonce,
            ],
        ]
        if let token {
            params["auth"] = [isDeviceToken ? "deviceToken" : "token": token]
        }
        let id = newID()
        try await send(["type": "req", "id": id, "method": "connect", "params": params])
        let answer = try await frame(socket.receive())
        guard answer["type"] as? String == "res", answer["id"] as? String == id, let accepted = answer["ok"] as? Bool else {
            throw OpenClawGatewayError.unexpectedReply
        }
        // A refusal is one only if it says what it refused with.
        guard accepted else {
            guard answer["error"] is [String: Any] else { throw OpenClawGatewayError.unexpectedReply }
            throw Self.refusal(in: answer)
        }
        guard let welcome = answer["payload"] as? [String: Any], welcome["type"] as? String == "hello-ok",
              let version = Self.integer(welcome["protocol"]) else {
            throw OpenClawGatewayError.unexpectedReply
        }
        guard version == Self.protocolVersion else { throw OpenClawGatewayError.unsupportedProtocol }
        guard let features = welcome["features"] as? [String: Any],
              let methods = features["methods"] as? [String], let events = features["events"] as? [String],
              let auth = welcome["auth"] as? [String: Any], let scopes = auth["scopes"] as? [String],
              let limit = Self.integer((welcome["policy"] as? [String: Any])?["maxPayload"]), limit > 0 else {
            throw OpenClawGatewayError.unexpectedReply
        }
        maxPayload = min(limit, Self.frameLimit)
        let hello = OpenClawGatewayHello(
            methods: Set(methods),
            events: Set(events),
            scopes: Set(scopes),
            maxPayload: maxPayload,
            deviceToken: (auth["deviceToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
        reading = Task { await self.read() }
        return hello
    }

    // MARK: - Requests

    /// Sends a request and waits for its answer: the answer's payload, as
    /// JSON. Throws what the Gateway refused with, or `closed` if the
    /// connection ended first.
    nonisolated func call(_ method: String, _ params: [String: Any]) async throws -> Data {
        try await call(method, paramsJSON: JSONSerialization.data(withJSONObject: params))
    }

    private func call(_ method: String, paramsJSON: Data) async throws -> Data {
        if let ended { throw ended }
        let id = newID()
        let params = try JSONSerialization.jsonObject(with: paramsJSON)
        let text = try Self.text(["type": "req", "id": id, "method": method, "params": params], limit: maxPayload)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            Task {
                do {
                    try await socket.send(text)
                } catch {
                    self.fail(id, with: error)
                }
            }
        }
    }

    func close() {
        end(with: OpenClawGatewayError.closed)
    }

    // MARK: - Private

    private func newID() -> String {
        nextID += 1
        return "aicoven-\(nextID)"
    }

    private func fail(_ id: String, with error: Error) {
        waiting.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func send(_ object: [String: Any]) async throws {
        try await socket.send(Self.text(object, limit: maxPayload))
    }

    private static func text(_ object: [String: Any], limit: Int) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else { throw OpenClawGatewayError.tooLarge }
        return text
    }

    private func frame(_ text: String) throws -> [String: Any] {
        guard text.utf8.count <= Self.frameLimit else { throw OpenClawGatewayError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw OpenClawGatewayError.unexpectedReply
        }
        return object
    }

    /// A whole number as JSON gave it: not a fraction, and not true or
    /// false, which read as numbers too.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

    private static func refusal(in answer: [String: Any]) -> OpenClawGatewayError {
        let error = answer["error"] as? [String: Any]
        let detail = (error?["details"] as? [String: Any])?["code"] as? String
        return .refused(code: detail ?? error?["code"] as? String ?? "UNKNOWN", message: String((error?["message"] as? String ?? "").prefix(500)))
    }

    /// Reads frames until the connection ends: answers go to whoever asked,
    /// events to `events`, in the order the Gateway numbered them.
    private func read() async {
        do {
            while !Task.isCancelled {
                let object = try await frame(socket.receive())
                switch object["type"] as? String {
                case "res":
                    guard let id = object["id"] as? String, let continuation = waiting.removeValue(forKey: id) else { continue }
                    if object["ok"] as? Bool == true {
                        let payload = object["payload"] ?? [String: Any]()
                        continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))
                    } else {
                        continuation.resume(throwing: Self.refusal(in: object))
                    }
                case "event":
                    guard let name = object["event"] as? String else { continue }
                    if let sequence = Self.integer(object["seq"]) {
                        // A number skipped is an event lost: what follows
                        // cannot be trusted to be the whole of it.
                        if let lastSequence, lastSequence == .max || sequence != lastSequence + 1 { throw OpenClawGatewayError.closed }
                        lastSequence = sequence
                    }
                    let payload = object["payload"] ?? [String: Any]()
                    eventsIn.yield(OpenClawGatewayEvent(name: name, payload: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)))
                default:
                    continue
                }
            }
        } catch {
            end(with: error)
        }
    }

    private func end(with error: Error) {
        guard ended == nil else { return }
        ended = error
        reading?.cancel()
        socket.close()
        eventsIn.finish(throwing: error)
        let asked = waiting
        waiting = [:]
        for continuation in asked.values {
            continuation.resume(throwing: OpenClawGatewayError.closed)
        }
    }
}

/// Reaching a Gateway for one piece of work: a connection is opened for it
/// and closed after it, as the cloud app does.
nonisolated enum OpenClawGateway {
    /// How long a Gateway has to complete the handshake.
    static let handshakeTimeout: Duration = .seconds(10)

    /// Connects, completes the handshake and closes: what the Gateway
    /// offers. `token` is the connection's own; with none, a token the
    /// Gateway issued this device earlier is shown, if there is one.
    static func hello(
        at address: URL,
        token: String?,
        timeout: Duration = handshakeTimeout,
        over socket: @Sendable (URL) -> OpenClawSocket = { OpenClawWebSocket(url: $0) }
    ) async throws -> OpenClawGatewayHello {
        let connection = try await open(address, token: token, timeout: timeout, over: socket)
        await connection.gateway.close()
        return connection.hello
    }

    /// An open connection and what the Gateway said of itself. A token the
    /// Gateway issues this device is kept for next time; one it no longer
    /// takes is forgotten, and the connection tried once more without it.
    static func open(
        _ address: URL,
        token: String?,
        timeout: Duration = handshakeTimeout,
        over socket: @Sendable (URL) -> OpenClawSocket = { OpenClawWebSocket(url: $0) }
    ) async throws -> (gateway: OpenClawGatewayConnection, hello: OpenClawGatewayHello) {
        // The Keychain is the current account's. The handshake waits, and
        // the account can change while it does: what is kept or forgotten
        // afterwards is the account's this began for, or nothing.
        let account = UserScope.currentUserID
        let identity = try OpenClawDeviceIdentity.loadOrCreate()
        let own = token.flatMap { $0.isEmpty ? nil : $0 }
        let issued = own == nil ? KeychainHelper.load(key: deviceTokenKey(for: address)) : nil
        do {
            return try await open(
                address, identity: identity, token: own ?? issued, isDeviceToken: own == nil && issued != nil,
                account: account, timeout: timeout, over: socket
            )
        } catch OpenClawGatewayError.refused(code: "AUTH_DEVICE_TOKEN_MISMATCH", _) where issued != nil {
            // Forgotten only if it is still the one that was refused: a
            // newer connection can have been issued another since.
            if UserScope.currentUserID == account, KeychainHelper.load(key: deviceTokenKey(for: address)) == issued {
                KeychainHelper.delete(key: deviceTokenKey(for: address))
            }
            return try await open(address, identity: identity, token: nil, isDeviceToken: false, account: account, timeout: timeout, over: socket)
        }
    }

    private static func open(
        _ address: URL,
        identity: OpenClawDeviceIdentity,
        token: String?,
        isDeviceToken: Bool,
        account: String,
        timeout: Duration,
        over socket: (URL) -> OpenClawSocket
    ) async throws -> (gateway: OpenClawGatewayConnection, hello: OpenClawGatewayHello) {
        let transport = socket(address)
        let gateway = OpenClawGatewayConnection(
            socket: transport,
            identity: identity,
            token: token,
            isDeviceToken: isDeviceToken,
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        )
        // An address that takes the connection and says nothing would hold
        // this for ever: closing the socket ends the wait.
        let givingUp = Task {
            try await Task.sleep(for: timeout)
            transport.close()
        }
        defer { givingUp.cancel() }
        do {
            let hello = try await gateway.open()
            if let issued = hello.deviceToken, UserScope.currentUserID == account {
                do {
                    try KeychainHelper.save(key: deviceTokenKey(for: address), value: issued)
                } catch {
                    // The connection stands; the next one will have no
                    // issued token to show.
                    AppErrorReporter.log(error: error, context: "OpenClawGateway.keepDeviceToken")
                }
            }
            return (gateway, hello)
        } catch {
            await gateway.close()
            throw error
        }
    }

    private static func deviceTokenKey(for address: URL) -> String {
        "openclaw-gateway-device-token.\(address.absoluteString)"
    }
}

/// A web socket to a Gateway. Unchecked as sendable because its one
/// property, the system's web socket task, is safe to use from any thread
/// and is not declared so.
final nonisolated class OpenClawWebSocket: OpenClawSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = OpenClawGatewayConnection.frameLimit
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw OpenClawGatewayError.unexpectedReply
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
