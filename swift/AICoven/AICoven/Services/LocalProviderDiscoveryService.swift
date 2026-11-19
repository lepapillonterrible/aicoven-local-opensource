import Foundation

/// A server found by `LocalProviderDiscoveryService`.
nonisolated struct DetectedLocalProvider: Identifiable, Hashable {
    let id: String
    /// The provider it is added as: "openai_compatible" or "ollama".
    let provider: String
    let displayName: String
    let baseURL: String
    let port: Int
    /// The model ids the server listed. Empty when it listed none, or
    /// answered in a shape this app does not read.
    let models: [String]
    /// True when a server answered but refused the request without a key.
    let requiresKey: Bool
}

/// What probing one address found. Telling "refused" from "nothing there"
/// lets Detect show a running server that wants a key.
nonisolated enum LocalProviderProbeOutcome: Equatable {
    case success(Data)
    case unauthorized
    case unavailable
}

/// The network seam, so discovery is tested without real sockets.
nonisolated protocol LocalProviderProbeTransport: Sendable {
    /// Never throws: a server that isn't running is an ordinary outcome.
    func probe(url: URL, bearerToken: String?, timeout: TimeInterval) async -> LocalProviderProbeOutcome
}

nonisolated extension URLSession: LocalProviderProbeTransport {
    /// Streams the response, so a reply of any size is not buffered. A
    /// typed address can point anywhere, and a local server can misbehave,
    /// so the body is capped.
    func probe(url: URL, bearerToken: String?, timeout: TimeInterval) async -> LocalProviderProbeOutcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (stream, response) = try await bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
            guard (200 ..< 300).contains(http.statusCode) else { return .unavailable }
            guard let data = try await LocalProviderDiscoveryService.collect(
                stream,
                limit: LocalProviderDiscoveryService.maxProbeResponseBytes
            ) else {
                return .unavailable
            }
            return .success(data)
        } catch {
            return .unavailable
        }
    }
}

/// Finds servers that speak the OpenAI chat API on this Mac: it asks the
/// usual port of each tool it knows for its model list, and checks an
/// address the person types. It never scans ports.
nonisolated struct LocalProviderDiscoveryService {
    /// A tool's usual port and the provider a server there is added as.
    struct KnownEndpoint: Equatable {
        let port: Int
        let provider: String
        let displayName: String
    }

    static let knownEndpoints: [KnownEndpoint] = [
        KnownEndpoint(port: 1234, provider: "openai_compatible", displayName: "LM Studio"),
        // Ollama keeps its own connection type, which lists its models with
        // their sizes.
        KnownEndpoint(port: 11434, provider: "ollama", displayName: "Ollama"),
    ]

    /// Short, so Detect feels instant when nothing listens on a port.
    static let probeTimeoutSeconds: TimeInterval = 1.0
    /// For an address the person gave, which may be another machine.
    static let namedAddressTimeoutSeconds: TimeInterval = 5.0
    static let validPortRange = 1 ... 65535
    /// Loopback: Detect only ever asks this machine.
    static let defaultHost = "127.0.0.1"
    static let modelsPath = "/v1/models"
    /// The largest reply read. A model list is a few kilobytes.
    static let maxProbeResponseBytes = 512 * 1024

    /// Collects bytes up to `limit`, and returns `nil` once it is passed, so
    /// nothing larger is held. An over-long reply is unusable, not
    /// truncated: a cut-off body would read as a server with no models.
    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        limit: Int
    ) async throws -> Data? where Bytes.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(limit, 16 * 1024))
        for try await byte in bytes {
            if data.count >= limit { return nil }
            data.append(byte)
        }
        return data
    }

    private let transport: LocalProviderProbeTransport
    private let endpoints: [KnownEndpoint]

    init(
        transport: LocalProviderProbeTransport = URLSession.shared,
        endpoints: [KnownEndpoint] = LocalProviderDiscoveryService.knownEndpoints
    ) {
        self.transport = transport
        self.endpoints = endpoints
    }

    /// Asks every known port at once and returns the servers that answered,
    /// by port.
    func discover() async -> [DetectedLocalProvider] {
        await withTaskGroup(of: DetectedLocalProvider?.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    let address = ManualEndpoint(scheme: "http", host: Self.defaultHost, port: endpoint.port)
                    return await probe(
                        address,
                        provider: endpoint.provider,
                        displayName: endpoint.displayName,
                        timeout: Self.probeTimeoutSeconds
                    )
                }
            }
            var found: [DetectedLocalProvider] = []
            for await candidate in group {
                if let candidate { found.append(candidate) }
            }
            return found.sorted { $0.port < $1.port }
        }
    }

    /// Asks one address for its models, with no key. `nil` when nothing
    /// usable answered.
    func probe(
        _ endpoint: ManualEndpoint,
        provider: String,
        displayName: String,
        timeout: TimeInterval = LocalProviderDiscoveryService.namedAddressTimeoutSeconds
    ) async -> DetectedLocalProvider? {
        guard Self.validPortRange.contains(endpoint.port), !endpoint.host.isEmpty,
              let url = URL(string: endpoint.baseURL + Self.modelsPath) else { return nil }
        let models: [String]
        let requiresKey: Bool
        switch await transport.probe(url: url, bearerToken: nil, timeout: timeout) {
        case let .success(data):
            models = Self.parseModelIds(from: data)
            requiresKey = false
        case .unauthorized:
            models = []
            requiresKey = true
        case .unavailable:
            return nil
        }
        return DetectedLocalProvider(
            id: "\(provider)-\(endpoint.baseURL)",
            provider: provider,
            displayName: displayName,
            baseURL: endpoint.baseURL,
            port: endpoint.port,
            models: models,
            requiresKey: requiresKey
        )
    }

    /// Asks the server at `baseURL` for its models, with its key if it has
    /// one.
    func models(at baseURL: URL, apiKey: String?) async -> LocalProviderProbeOutcome {
        await transport.probe(
            url: baseURL.appendingPathComponent("v1/models"),
            bearerToken: apiKey,
            timeout: Self.namedAddressTimeoutSeconds
        )
    }

    /// The known tool whose usual port this is, which names a typed address.
    func knownEndpoint(forPort port: Int) -> KnownEndpoint? {
        endpoints.first { $0.port == port }
    }

    // MARK: - A typed address

    /// An address the person gave. It carries the scheme, so an `https`
    /// address is never asked (or saved) over plain `http`, and it brackets
    /// IPv6 literals.
    struct ManualEndpoint: Equatable {
        let scheme: String
        let host: String
        let port: Int

        /// `host:port`, with an IPv6 literal bracketed per RFC 3986.
        var authority: String {
            host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }

        var baseURL: String {
            "\(scheme)://\(authority)"
        }
    }

    enum ManualEntryCopy {
        static let placeholder = "8080 or 127.0.0.1:8080"
        static let invalidInput = "Enter a port (such as 8080), or a host and port (such as 127.0.0.1:8080)."

        static func noResponse(at endpoint: ManualEndpoint) -> String {
            "Nothing answered at \(endpoint.authority). Check the server is running and serves the OpenAI API."
        }
    }

    /// Reads what a person types: a port (`1234`), `host:port`, a bracketed
    /// IPv6 literal (`[::1]:1234`), or a pasted URL, whose path is dropped.
    /// A port alone means this Mac. `nil` when there is no usable port: 80
    /// and 443 are never guessed. An explicit `https://` is kept.
    static func parseManualEndpoint(_ raw: String) -> ManualEndpoint? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var scheme = "http"
        for candidate in ["https://", "http://"] where value.lowercased().hasPrefix(candidate) {
            scheme = String(candidate.dropLast(3))
            value = String(value.dropFirst(candidate.count))
            break
        }
        value = value.components(separatedBy: CharacterSet(charactersIn: "/?#"))[0]
        guard !value.isEmpty, !value.contains(" ") else { return nil }

        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex) ..< close])
            let rest = String(value[value.index(after: close)...])
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()),
                  !host.isEmpty, validPortRange.contains(port) else {
                return nil
            }
            return ManualEndpoint(scheme: scheme, host: host, port: port)
        }
        if let colon = value.lastIndex(of: ":") {
            let host = String(value[value.startIndex ..< colon])
            guard let port = Int(value[value.index(after: colon)...]),
                  validPortRange.contains(port), !host.isEmpty else {
                return nil
            }
            return ManualEndpoint(scheme: scheme, host: host, port: port)
        }
        guard let port = Int(value), validPortRange.contains(port) else { return nil }
        return ManualEndpoint(scheme: scheme, host: defaultHost, port: port)
    }

    /// The address a server is saved and reached at, from what a person
    /// typed in a connection's Address field: a port or `host:port` (as
    /// `parseManualEndpoint` reads them), or a URL. A trailing `/v1` is
    /// dropped, because requests add it; any other path stays, for a server
    /// behind a prefix. `nil` when it names no host.
    static func serverBaseURL(from raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") else {
            return parseManualEndpoint(value).flatMap { URL(string: $0.baseURL) }
        }
        guard var components = URLComponents(string: value), components.host?.isEmpty == false else { return nil }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The model ids in an OpenAI-style `{"data": [{"id": "..."}]}` list;
    /// empty for any other shape.
    static func parseModelIds(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { $0["id"] as? String }
    }
}
