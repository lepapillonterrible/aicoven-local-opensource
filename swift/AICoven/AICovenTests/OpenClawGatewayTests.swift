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

    func testOpening_takesNoChallengeOrWelcomeThatIsNotWellFormed() async throws {
        // A challenge whose timestamp is not a whole number, or not a number.
        for timestamp in [-0.5 as Any, true as Any, -1 as Any, "now" as Any] {
            let socket = ScriptedGatewaySocket()
            socket.push(["type": "event", "event": "connect.challenge", "payload": ["nonce": "n", "ts": timestamp]])
            do {
                _ = try await connection(socket).open()
                XCTFail("Not a challenge: \(timestamp)")
            } catch {
                XCTAssertEqual(error as? OpenClawGatewayError, .unexpectedReply, "\(timestamp)")
            }
            XCTAssertTrue(socket.sent.isEmpty, "Nothing is signed for a challenge that is not one")
        }

        /// Answers to the connect that are neither a welcome nor a refusal.
        func answer(_ change: (inout [String: Any]) -> Void) async throws -> Error? {
            let socket = ScriptedGatewaySocket()
            let gateway = try connection(socket)
            async let opened = gateway.open()
            socket.push(ScriptedGatewaySocket.challenge)
            await fulfillment(of: [socket.expectSent(1)], timeout: 10)
            var welcome = ScriptedGatewaySocket.welcome(to: socket.sent.first?["id"] as? String ?? "")
            change(&welcome)
            socket.push(welcome)
            do {
                _ = try await opened
                return nil
            } catch {
                return error
            }
        }
        func payload(_ welcome: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            var payload = welcome["payload"] as? [String: Any] ?? [:]
            change(&payload)
            welcome["payload"] = payload
        }
        let noVerdict = try await answer { $0["ok"] = nil }
        XCTAssertEqual(noVerdict as? OpenClawGatewayError, .unexpectedReply)
        let refusalWithNoReason = try await answer { $0["ok"] = false }
        XCTAssertEqual(refusalWithNoReason as? OpenClawGatewayError, .unexpectedReply)
        let noMethods = try await answer { payload(&$0) { $0["features"] = ["events": ["chat"]] } }
        XCTAssertEqual(noMethods as? OpenClawGatewayError, .unexpectedReply, "Protocol 4, but not a welcome")
        let noLimit = try await answer { payload(&$0) { $0["policy"] = ["maxPayload": 0] } }
        XCTAssertEqual(noLimit as? OpenClawGatewayError, .unexpectedReply)
        let fractionalVersion = try await answer { payload(&$0) { $0["protocol"] = 4.5 } }
        XCTAssertEqual(fractionalVersion as? OpenClawGatewayError, .unexpectedReply)
        let newerVersion = try await answer { payload(&$0) { $0["protocol"] = 5 } }
        XCTAssertEqual(newerVersion as? OpenClawGatewayError, .unsupportedProtocol)
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

    func testTheLargestEventNumber_endsTheConnectionAtTheNextEventAndDoesNotCrash() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = try connection(socket)
        async let opened = gateway.open()
        await socket.welcomeNextConnection(in: self)
        _ = try await opened

        socket.push(["type": "event", "event": "chat", "seq": Int.max, "payload": ["state": "delta"]])
        socket.push(["type": "event", "event": "chat", "seq": 1, "payload": ["state": "delta"]])

        var seen = 0
        do {
            for try await _ in gateway.events {
                seen += 1
            }
            XCTFail("The events end with the connection")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .closed)
        }
        XCTAssertEqual(seen, 1)
    }

    func testARequestLargerThanTheGatewayTakes_isNotSent() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = try connection(socket)
        async let opened = gateway.open()
        socket.push(ScriptedGatewaySocket.challenge)
        await fulfillment(of: [socket.expectSent(1)], timeout: 10)
        var welcome = ScriptedGatewaySocket.welcome(to: socket.sent.first?["id"] as? String ?? "")
        var payload = try XCTUnwrap(welcome["payload"] as? [String: Any])
        payload["policy"] = ["maxPayload": 200]
        welcome["payload"] = payload
        socket.push(welcome)
        let hello = try await opened
        XCTAssertEqual(hello.maxPayload, 200)

        do {
            _ = try await gateway.call("chat.send", ["message": String(repeating: "a", count: 300)])
            XCTFail("Larger than the Gateway takes")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .tooLarge)
        }
        XCTAssertEqual(socket.sent.count, 1, "Only the connect was sent")
        await gateway.close()
    }

    // MARK: - A connection for one piece of work

    func testAGatewayThatSaysNothing_isGivenUpOn() async throws {
        let address = try XCTUnwrap(OpenClawGatewayConnection.address("ws://127.0.0.1:18789"))
        let silent = ScriptedGatewaySocket()

        do {
            _ = try await OpenClawGateway.hello(at: address, token: "T", timeout: .milliseconds(50), over: { _ in silent })
            XCTFail("Nothing answered")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .closed)
        }
        XCTAssertTrue(silent.isClosed)
    }

    func testTheConnectionsOwnToken_isShownThoughTheGatewayIssuedOneAndATokenIssuedSinceIsNotForgotten() async throws {
        let address = try XCTUnwrap(OpenClawGatewayConnection.address("ws://127.0.0.1:\(Int.random(in: 20000 ... 60000))"))
        let tokenKey = "openclaw-gateway-device-token.\(address.absoluteString)"
        addTeardownBlock { KeychainHelper.delete(key: tokenKey) }
        try KeychainHelper.save(key: tokenKey, value: "ISSUED")

        let own = ScriptedGatewaySocket()
        async let withOwn = OpenClawGateway.hello(at: address, token: "MINE", over: { _ in own })
        await own.welcomeNextConnection(in: self)
        _ = try await withOwn
        XCTAssertEqual((own.sent.first?["params"] as? [String: Any])?["auth"] as? [String: String], ["token": "MINE"])
        XCTAssertEqual(KeychainHelper.load(key: tokenKey), "ISSUED")

        // The issued token is refused, but by then a newer connection has
        // been issued another: that one stays.
        let refused = ScriptedGatewaySocket()
        let retried = ScriptedGatewaySocket()
        let sockets = Sockets([refused, retried])
        async let again = OpenClawGateway.hello(at: address, token: nil, over: { _ in sockets.next() })
        refused.push(ScriptedGatewaySocket.challenge)
        await fulfillment(of: [refused.expectSent(1)], timeout: 10)
        try KeychainHelper.save(key: tokenKey, value: "NEWER")
        refused.push([
            "type": "res", "id": refused.sent.first?["id"] as? String ?? "", "ok": false,
            "error": ["code": "UNAUTHORIZED", "message": "token mismatch", "details": ["code": "AUTH_DEVICE_TOKEN_MISMATCH"]],
        ])
        await retried.welcomeNextConnection(in: self)
        _ = try await again
        XCTAssertEqual(KeychainHelper.load(key: tokenKey), "NEWER")
    }

    func testATokenTheGatewayIssues_isKeptAndShownNextTimeAndForgottenWhenItIsNoLongerTaken() async throws {
        let address = try XCTUnwrap(OpenClawGatewayConnection.address("ws://127.0.0.1:\(Int.random(in: 20000 ... 60000))"))
        let tokenKey = "openclaw-gateway-device-token.\(address.absoluteString)"
        addTeardownBlock { KeychainHelper.delete(key: tokenKey) }

        // The first connection has no token; the Gateway issues one.
        let first = ScriptedGatewaySocket()
        async let opened = OpenClawGateway.hello(at: address, token: nil, over: { _ in first })
        await first.welcomeNextConnection(deviceToken: "ISSUED", in: self)
        let hello = try await opened
        XCTAssertNil(hello.missing)
        XCTAssertNil((first.sent.first?["params"] as? [String: Any])?["auth"])
        XCTAssertTrue(first.isClosed, "The connection is closed once it has answered")
        XCTAssertEqual(KeychainHelper.load(key: tokenKey), "ISSUED")

        // The next shows it. The Gateway no longer takes it, so it is
        // forgotten and the connection made once more without it.
        let refused = ScriptedGatewaySocket()
        let retried = ScriptedGatewaySocket()
        let sockets = Sockets([refused, retried])
        async let again = OpenClawGateway.hello(at: address, token: nil, over: { _ in sockets.next() })
        refused.push(ScriptedGatewaySocket.challenge)
        await fulfillment(of: [refused.expectSent(1)], timeout: 10)
        XCTAssertEqual((refused.sent.first?["params"] as? [String: Any])?["auth"] as? [String: String], ["deviceToken": "ISSUED"])
        refused.push([
            "type": "res", "id": refused.sent.first?["id"] as? String ?? "", "ok": false,
            "error": ["code": "UNAUTHORIZED", "message": "token mismatch", "details": ["code": "AUTH_DEVICE_TOKEN_MISMATCH"]],
        ])
        await retried.welcomeNextConnection(in: self)
        _ = try await again
        XCTAssertNil((retried.sent.first?["params"] as? [String: Any])?["auth"])
        XCTAssertNil(KeychainHelper.load(key: tokenKey))

        // A connection with its own token shows that, and no issued one.
        let own = ScriptedGatewaySocket()
        async let withOwn = OpenClawGateway.hello(at: address, token: "MINE", over: { _ in own })
        await own.welcomeNextConnection(in: self)
        _ = try await withOwn
        XCTAssertEqual((own.sent.first?["params"] as? [String: Any])?["auth"] as? [String: String], ["token": "MINE"])
    }

    // MARK: - The stored connection

    func testAnOpenClawConnection_keepsItsGatewayAddressAndIsTestedAtItsGateway() async throws {
        let defaults = UserDefaults.standard
        let keys = ["provider_accounts.v1", "hermes_model_connections_converted.v1", "openclaw_base_url"].map(UserScope.scopedKey)
        let saved = keys.map { defaults.object(forKey: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        defaults.removeObject(forKey: keys[0])
        defaults.set(true, forKey: keys[1])
        let service = ProviderAccountService.shared
        let asked = AskedGateways()
        await service.askGateways { address, token in
            await asked.note(address, token)
            return await asked.hello
        }
        addTeardownBlock {
            await service.askGateways { try await OpenClawGateway.hello(at: $0, token: $1) }
        }

        let account = try await service.createOpenClawAccount(
            displayName: "My OpenClaw", baseURL: "http://127.0.0.1:1", apiKey: "TOKEN", defaultModel: nil, gatewayURL: "ws://127.0.0.1:18789"
        )
        addTeardownBlock { try? await service.deleteProviderAccount(id: account.id) }
        let stored = try await service.gatewayAddress(forAccount: account.id)
        XCTAssertEqual(stored, "ws://127.0.0.1:18789")

        // Tested at the Gateway, with the connection's token; the server
        // address answering or not does not decide it.
        let models = try await service.testConnection(accountId: account.id)
        XCTAssertEqual(models, 0)
        let calls = await asked.calls
        XCTAssertEqual(calls.map(\.address), ["ws://127.0.0.1:18789"])
        XCTAssertEqual(calls.map(\.token), ["TOKEN"])
        let healthy = try await service.loadProviderAccounts().first { $0.id == account.id }
        XCTAssertEqual(healthy?.status, "healthy")
        let kept = try await service.gatewayAddress(forAccount: account.id)
        XCTAssertEqual(kept, "ws://127.0.0.1:18789", "Recording the outcome keeps the Gateway address")

        // A Gateway that lacks what a turn needs fails the test, saying what.
        await asked.offer(methods: ["chat.send"])
        do {
            _ = try await service.testConnection(accountId: account.id)
            XCTFail("A Gateway a turn cannot run on does not pass")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .notSupported("sessions.messages.subscribe"))
        }
        let unhealthy = try await service.loadProviderAccounts().first { $0.id == account.id }
        XCTAssertEqual(unhealthy?.status, "unhealthy")

        // Renaming keeps the Gateway; an empty address takes it off.
        try await service.updateProviderAccount(id: account.id, displayName: "Renamed")
        let afterRename = try await service.gatewayAddress(forAccount: account.id)
        XCTAssertEqual(afterRename, "ws://127.0.0.1:18789")
        try await service.updateProviderAccount(id: account.id, gatewayURL: "")
        let afterClear = try await service.gatewayAddress(forAccount: account.id)
        XCTAssertNil(afterClear)
    }

    func testAConnectionStoredBeforeGateways_stillLoadsAndHasNone() throws {
        let before = Data(#"[{"id":"a","provider":"openclaw","displayName":"OpenClaw","scopes":["chat"],"baseURL":"http://localhost:3000","status":"healthy","createdAt":0}]"#.utf8)
        let accounts = try JSONDecoder().decode([LocalProviderAccount].self, from: before)
        XCTAssertEqual(accounts.first?.baseURL, "http://localhost:3000")
        XCTAssertNil(accounts.first?.gatewayURL)
    }

    @MainActor
    func testTheGatewayFieldSavesAnAddressAGatewayMayBeReachedAtOrNone() {
        XCTAssertEqual(OpenClawGatewayField.addressToSave("  "), "")
        XCTAssertEqual(OpenClawGatewayField.addressToSave(" ws://127.0.0.1:18789 "), "ws://127.0.0.1:18789")
        XCTAssertNil(OpenClawGatewayField.addressToSave("ws://gateway.example.com:18789"))
        XCTAssertNil(OpenClawGatewayField.addressToSave("http://127.0.0.1:18789"))
    }

    // MARK: - Addresses

    func testAGatewayAddress_isPlainOnlyOnThisMachineAndCarriesNothingElse() {
        for good in ["ws://127.0.0.1:18789", "ws://localhost:18789/", "ws://[::1]:18789", "wss://gateway.example.com", " wss://gateway.example.com:8443 "] {
            XCTAssertNotNil(OpenClawGatewayConnection.address(good), good)
        }
        XCTAssertEqual(OpenClawGatewayConnection.address("ws://localhost:18789/")?.absoluteString, "ws://localhost:18789", "A lone trailing slash is dropped")
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

/// Hands out sockets in turn, to a connection that is made more than once.
private final class Sockets: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [ScriptedGatewaySocket]

    init(_ sockets: [ScriptedGatewaySocket]) {
        left = sockets
    }

    func next() -> ScriptedGatewaySocket {
        lock.withLock { left.isEmpty ? ScriptedGatewaySocket() : left.removeFirst() }
    }
}

/// The Gateways a test's connections were tested at, and what they offer.
private actor AskedGateways {
    private(set) var calls: [(address: String, token: String?)] = []
    private var methods = OpenClawGatewayHello.methodsNeeded

    var hello: OpenClawGatewayHello {
        OpenClawGatewayHello(
            methods: Set(methods), events: ["chat", "session.approval"],
            scopes: Set(OpenClawGatewayConnection.scopes), maxPayload: 1024, deviceToken: nil
        )
    }

    func note(_ address: URL, _ token: String?) {
        calls.append((address.absoluteString, token))
    }

    func offer(methods: [String]) {
        self.methods = methods
    }
}
