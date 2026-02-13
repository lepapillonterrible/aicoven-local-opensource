import Foundation

/// HTTP method enum
enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}

/// API error types
enum APIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case httpError(statusCode: Int, message: String?)
    case decodingError(Error)
    case unauthorized
    case noAuthToken
    /// Local-only open source build: backend API is not available
    case backendUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case let .networkError(error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid server response"
        case let .httpError(statusCode, message):
            let messageText = message ?? "Unknown error"
            return "HTTP \(statusCode): \(messageText)"
        case let .decodingError(error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .unauthorized:
            return "Unauthorized - please sign in again"
        case .noAuthToken:
            return "No authentication token available"
        case .backendUnavailable:
            return "Backend API is disabled in this local-only build"
        }
    }
}

/// Core API client for making authenticated requests
actor APIClient {
    static let shared = APIClient()

    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        // Configure URLSession with timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        urlSession = URLSession(configuration: config)

        // Configure JSON decoder
        // Note: We use explicit CodingKeys in models, so no automatic snake_case conversion
        decoder = JSONDecoder()

        // Use custom date decoding to handle multiple formats
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try ISO8601 with fractional seconds
            if let date = isoFormatter.date(from: dateString) {
                return date
            }

            // Try ISO8601 without fractional seconds
            if let date = isoFormatterNoFraction.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date from: \(dateString)")
        }

        // Configure JSON encoder
        // Note: We use explicit CodingKeys in models, so no automatic snake_case conversion
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    /// Make authenticated API request
    /// - Parameters:
    ///   - endpoint: API endpoint path (e.g., "/auth/me")
    ///   - method: HTTP method
    ///   - body: Optional request body (will be JSON encoded)
    ///   - requiresAuth: Whether request requires authentication token
    /// - Returns: Decoded response of type T
    func request<T: Decodable>(
        _ endpoint: String,
        method: HTTPMethod = .get,
        body: Encodable? = nil,
        headers: [String: String]? = nil,
        requiresAuth: Bool = true
    ) async throws -> T {
        // Local-first open source client has **no backend server**. Any
        // attempt to call the legacy API is a programming error. We
        // short-circuit here so that no HTTP request is ever made.
        AppErrorReporter.log(message: "APIClient.request called for endpoint \(endpoint) in local-only build – backend API is disabled.", context: "APIClient.request.localOnlyBackendDisabled")
        throw APIError.backendUnavailable
    }
}

/// Empty response for operations that don't return data
struct EmptyResponse: Codable {}
