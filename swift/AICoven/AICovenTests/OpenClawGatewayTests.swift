@testable import AICoven
import CryptoKit
import XCTest

/// A Gateway's end of the socket, played by the test: it says what the
/// Gateway sends, and sees what was sent to it.
final class ScriptedGatewaySocket: OpenClawSocket, @unchecked Sendable {
    // Written by the test and read by the connection's tasks, and the
    // other way round: every access is under the lock.
    private let lock = NSLock()
    private var incoming: [String] = []
    private var waiting: CheckedContinuation<String, Error>?
    private var sentFrames: [[String: Any]] = []
    private var sentWatchers: [(count: Int, seen: XCTestExpectation)] = []
    private var closed = false

    /// The Gateway sends a frame.
    func push(_ object: [String: Any]) {
        let text = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        pushText(text)
    }

    func pushText(_ text: String) {
        let reader: CheckedContinuation<String, Error>? = lock.withLock {
            if let waiting {
                self.waiting = nil
                return waiting
            }
            incoming.append(text)
            return nil
        }
        reader?.resume(returning: text)
    }

    /// The frames sent to the Gateway so far.
    var sent: [[String: Any]] {
        lock.withLock { sentFrames }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    /// An expectation met once `count` frames have been sent.
    func expectSent(_ count: Int) -> XCTestExpectation {
        let seen = XCTestExpectation(description: "\(count) frames sent to the Gateway")
        let already = lock.withLock {
            if sentFrames.count >= count { return true }
            sentWatchers.append((count, seen))
            return false
        }
        if already { seen.fulfill() }
        return seen
    }

    func send(_ text: String) async throws {
        let met: [XCTestExpectation] = try lock.withLock {
            guard !closed else { throw OpenClawGatewayError.closed }
            sentFrames.append((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:])
            let met = sentWatchers.filter { $0.count <= sentFrames.count }.map(\.seen)
            sentWatchers.removeAll { $0.count <= sentFrames.count }
            return met
        }
        met.forEach { $0.fulfill() }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let next: Result<String, Error>? = lock.withLock {
                if closed { return .failure(OpenClawGatewayError.closed) }
                if !incoming.isEmpty { return .success(incoming.removeFirst()) }
                waiting = continuation
                return nil
            }
            if let next { continuation.resume(with: next) }
        }
    }

    func close() {
        let reader: CheckedContinuation<String, Error>? = lock.withLock {
            closed = true
            defer { waiting = nil }
            return waiting
        }
        reader?.resume(throwing: OpenClawGatewayError.closed)
    }

    // MARK: - What a Gateway says

    static let challenge: [String: Any] = [
        "type": "event", "event": "connect.challenge",
        "payload": ["nonce": "nonce-1", "ts": 1_791_417_600_000, "capabilities": ["model-catalog-snapshot"]],
    ]

    static func welcome(to id: String, methods: [String] = OpenClawGatewayHello.methodsNeeded, deviceToken: String? = nil) -> [String: Any] {
        var auth: [String: Any] = ["role": "operator", "scopes": OpenClawGatewayConnection.scopes]
        auth["deviceToken"] = deviceToken
        return [
            "type": "res", "id": id, "ok": true,
            "payload": [
                "type": "hello-ok", "protocol": 4,
                "server": ["version": "2026.9.9", "connId": "c1"],
                "features": ["methods": methods, "events": ["chat", "session.approval"], "capabilities": [String]()],
                "auth": auth,
                "policy": ["maxPayload": 26_214_400, "maxBufferedBytes": 52_428_800, "tickIntervalMs": 30000],
            ],
        ]
    }

    /// Plays the Gateway's part of the handshake: the challenge, then the
    /// welcome to whatever connect arrives.
    func welcomeNextConnection(deviceToken: String? = nil, methods: [String] = OpenClawGatewayHello.methodsNeeded, in test: XCTestCase) async {
        push(Self.challenge)
        await test.fulfillment(of: [expectSent(1)], timeout: 10)
        let id = sent.first?["id"] as? String ?? ""
        push(Self.welcome(to: id, methods: methods, deviceToken: deviceToken))
    }
}

/// The connection to an OpenClaw Gateway: the handshake, requests and their
/// answers, and events in order.
final class OpenClawGatewayTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()

    private func connection(_ socket: ScriptedGatewaySocket, token: String? = "TOKEN", isDeviceToken: Bool = false) throws -> OpenClawGatewayConnection {
        try OpenClawGatewayConnection(
            socket: socket,
            identity: OpenClawDeviceIdentity(privateKey: key.rawRepresentation),
            token: token,
            isDeviceToken: isDeviceToken,
            clientVersion: "9.9"
        )
    }

    // MARK: - The handshake

    func testOpening_answersTheChallengeWithWhoThisIsAndASignatureOverIt() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = try connection(socket)
        async let opened = gateway.open()
        await socket.welcomeNextConnection(deviceToken: "DEVICE", in: self)
        let hello = try await opened

        XCTAssertEqual(hello.methods, Set(OpenClawGatewayHello.methodsNeeded))
        XCTAssertEqual(hello.events, ["chat", "session.approval"])
        XCTAssertEqual(hello.scopes, Set(OpenClawGatewayConnection.scopes))
        XCTAssertEqual(hello.maxPayload, 25 * 1024 * 1024, "No more than this app takes, whatever the Gateway does")
        XCTAssertEqual(hello.deviceToken, "DEVICE")
        XCTAssertNil(hello.missing)

        let connect = try XCTUnwrap(socket.sent.first)
        XCTAssertEqual(connect["type"] as? String, "req")
        XCTAssertEqual(connect["method"] as? String, "connect")
        let params = try XCTUnwrap(connect["params"] as? [String: Any])
        XCTAssertEqual(params["minProtocol"] as? Int, 4)
        XCTAssertEqual(params["maxProtocol"] as? Int, 4)
        XCTAssertEqual(params["role"] as? String, "operator")
        XCTAssertEqual(params["scopes"] as? [String], ["operator.read", "operator.write", "operator.approvals"])
        XCTAssertEqual((params["auth"] as? [String: String]), ["token": "TOKEN"])
        XCTAssertEqual((params["client"] as? [String: Any])?["version"] as? String, "9.9")

        // The device is the hash of its public key, and the signature is
        // over this device, what it asks to be, the challenge and the token.
        let device = try XCTUnwrap(params["device"] as? [String: Any])
        let publicKey = key.publicKey.rawRepresentation
        let deviceID = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(device["id"] as? String, deviceID)
        XCTAssertEqual(device["nonce"] as? String, "nonce-1")
        XCTAssertEqual(device["signedAt"] as? Int, 1_791_417_600_000)
        let signed = "v2|\(deviceID)|gateway-client|backend|operator|operator.read,operator.write,operator.approvals|1791417600000|TOKEN|nonce-1"
        let signature = try XCTUnwrap(Self.data(base64URL: device["signature"] as? String ?? ""))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data(signed.utf8)))
        XCTAssertEqual(Self.data(base64URL: device["publicKey"] as? String ?? ""), publicKey)
        await gateway.close()
    }

    func testOpening_withATokenTheGatewayIssuedSaysSoAndWithNoneSendsNone() async throws {
        let withDeviceToken = ScriptedGatewaySocket()
        let first = try connection(withDeviceToken, token: "ISSUED", isDeviceToken: true)
        async let opened = first.open()
        await withDeviceToken.welcomeNextConnection(in: self)
        _ = try await opened
        let auth = (withDeviceToken.sent.first?["params"] as? [String: Any])?["auth"] as? [String: String]
        XCTAssertEqual(auth, ["deviceToken": "ISSUED"])
        await first.close()

        let withNone = ScriptedGatewaySocket()
        let second = try connection(withNone, token: nil)
        async let openedAgain = second.open()
        await withNone.welcomeNextConnection(in: self)
        _ = try await openedAgain
        XCTAssertNil((withNone.sent.first?["params"] as? [String: Any])?["auth"])
        await second.close()
    }

    func testOpening_failsWithWhatTheGatewayRefusedWith() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = try connection(socket)
        async let opened = gateway.open()
        socket.push(ScriptedGatewaySocket.challenge)
        await fulfillment(of: [socket.expectSent(1)], timeout: 10)
        socket.push([
            "type": "res", "id": socket.sent.first?["id"] as? String ?? "", "ok": false,
            "error": ["code": "UNAUTHORIZED", "message": "bad token", "retryable": false, "details": ["code": "AUTH_TOKEN_MISMATCH"]],
        ])

        do {
            _ = try await opened
            XCTFail("A refused connection is not open")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .refused(code: "AUTH_TOKEN_MISMATCH", message: "bad token"))
        }
    }

    func testOpening_failsOnWhatIsNotAGatewayOrSpeaksAnotherVersion() async throws {
        let notAGateway = ScriptedGatewaySocket()
        notAGateway.pushText("<html>hello</html>")
        do {
            _ = try await connection(notAGateway).open()
            XCTFail("Not a Gateway")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .unexpectedReply)
        }

        let older = ScriptedGatewaySocket()
        let gateway = try connection(older)
        async let opened = gateway.open()
        older.push(ScriptedGatewaySocket.challenge)
        await fulfillment(of: [older.expectSent(1)], timeout: 10)
        var welcome = ScriptedGatewaySocket.welcome(to: older.sent.first?["id"] as? String ?? "")
        var payload = try XCTUnwrap(welcome["payload"] as? [String: Any])
        payload["protocol"] = 3
        welcome["payload"] = payload
        older.push(welcome)
        do {
            _ = try await opened
            XCTFail("Another version of the protocol")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .unsupportedProtocol)
        }
    }

    func testAGatewayThatLacksWhatATurnNeeds_saysWhatIsMissing() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = try connection(socket)
        async let opened = gateway.open()
        await socket.welcomeNextConnection(methods: ["chat.send", "sessions.messages.subscribe"], in: self)
        let hello = try await opened

        XCTAssertEqual(hello.missing, "agent.wait")
        await gateway.close()
    }

    // MARK: - Requests and events

    func testARequest_getsItsOwnAnswerAndEventsArriveInOrder() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = try connection(socket)
        async let opened = gateway.open()
        await socket.welcomeNextConnection(in: self)
        _ = try await opened

        async let first = gateway.call("chat.send", ["sessionKey": "s", "message": "Hello"])
        async let second = gateway.call("agent.wait", ["runId": "r"])
        await fulfillment(of: [socket.expectSent(3)], timeout: 10)
        let requests = socket.sent.dropFirst()
        let send = try XCTUnwrap(requests.first { $0["method"] as? String == "chat.send" })
        let wait = try XCTUnwrap(requests.first { $0["method"] as? String == "agent.wait" })
        XCTAssertEqual((send["params"] as? [String: String]), ["sessionKey": "s", "message": "Hello"])
        // Answered out of order, with events in between.
        socket.push(["type": "event", "event": "chat", "seq": 1, "payload": ["state": "delta", "deltaText": "Hi"]])
        socket.push(["type": "res", "id": wait["id"] ?? "", "ok": true, "payload": ["status": "started"]])
        socket.push(["type": "event", "event": "chat", "seq": 2, "payload": ["state": "final", "finalText": "Hi there"]])
        socket.push(["type": "res", "id": send["id"] ?? "", "ok": false, "error": ["code": "UNAVAILABLE", "message": "restarting"]])

        let waited = try await second
        XCTAssertEqual(try JSONSerialization.jsonObject(with: waited) as? [String: String], ["status": "started"])
        do {
            _ = try await first
            XCTFail("A refused request throws")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .refused(code: "UNAVAILABLE", message: "restarting"))
        }
        var states: [String] = []
        for try await event in gateway.events {
            XCTAssertEqual(event.name, "chat")
            try states.append((JSONSerialization.jsonObject(with: event.payload) as? [String: Any])?["state"] as? String ?? "")
            if states.count == 2 { break }
        }
        XCTAssertEqual(states, ["delta", "final"])
        await gateway.close()
        XCTAssertTrue(socket.isClosed)
    }

    func testAnEventNumberSkipped_endsTheConnectionAndWhoeverIsWaiting() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = try connection(socket)
        async let opened = gateway.open()
        await socket.welcomeNextConnection(in: self)
        _ = try await opened

        async let asked = gateway.call("agent.wait", ["runId": "r"])
        await fulfillment(of: [socket.expectSent(2)], timeout: 10)
        socket.push(["type": "event", "event": "chat", "seq": 1, "payload": ["state": "delta"]])
        socket.push(["type": "event", "event": "chat", "seq": 3, "payload": ["state": "delta"]])

        do {
            _ = try await asked
            XCTFail("The connection has ended")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .closed)
        }
        var seen = 0
        do {
            for try await _ in gateway.events {
                seen += 1
            }
            XCTFail("The events end with the connection")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .closed)
        }
        XCTAssertEqual(seen, 1, "What came before the gap is still there")
        XCTAssertTrue(socket.isClosed)
        do {
            _ = try await gateway.call("chat.abort", ["runId": "r"])
            XCTFail("Nothing is sent on an ended connection")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .closed)
        }
    }

    // MARK: - Addresses

    func testAGatewayAddress_isPlainOnlyOnThisMachineAndCarriesNothingElse() {
        for good in ["ws://127.0.0.1:18789", "ws://localhost:18789/", "ws://[::1]:18789", "wss://gateway.example.com", " wss://gateway.example.com:8443 "] {
            XCTAssertNotNil(OpenClawGatewayConnection.address(good), good)
        }
        for bad in [
            "", "ws://gateway.example.com:18789", "http://127.0.0.1:18789", "ws://user:secret@127.0.0.1:18789",
            "wss://gateway.example.com/?token=abc", "wss://gateway.example.com/#x", "wss://gateway.example.com/path", "127.0.0.1:18789",
        ] {
            XCTAssertNil(OpenClawGatewayConnection.address(bad), bad)
        }
    }

    private static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        return Data(base64Encoded: base64)
    }
}
