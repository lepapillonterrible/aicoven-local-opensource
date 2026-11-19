import Foundation

/// What Figma's REST API is asked with a person's personal access token.
nonisolated enum FigmaError: LocalizedError, Equatable {
    /// Figma refused the token: it is wrong, expired or revoked.
    case tokenRefused
    /// Figma is limiting how often this account asks; it may say how many
    /// seconds to wait.
    case rateLimited(retryAfter: Int?)
    /// Figma answered with something other than what was asked for.
    case notAnswered(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .tokenRefused:
            "Figma refused the token."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Figma is limiting how often this account asks. Try again in \($0) seconds." } ?? "Figma is limiting how often this account asks. Try again later."
        case let .notAnswered(status):
            "Figma answered HTTP \(status)."
        case .invalidResponse:
            "Figma's answer could not be read."
        }
    }
}

/// Figma, asked with a personal access token. A token is sent to
/// api.figma.com only, in `X-Figma-Token`, and is never logged or told.
nonisolated enum FigmaToolService {
    static let host = "api.figma.com"

    /// The most characters a token may have (as the cloud app takes them).
    static let longestToken = 512

    /// Who a token belongs to.
    struct Identity: Equatable {
        /// Figma's id of the user.
        let id: String
        /// What the account is shown as: the email, else the handle.
        let label: String
    }

    /// Who a token belongs to, from `GET /v1/me`. Throws
    /// `FigmaError.tokenRefused` where Figma refuses the token.
    @concurrent
    static func identity(token: String, session: URLSession = .shared) async throws -> Identity {
        guard let path = RequestPath.path(of: ["v1", "me"]), let url = URL(string: "https://\(host)\(path)") else {
            throw FigmaError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FigmaError.invalidResponse }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw FigmaError.tokenRefused
        case 429:
            throw FigmaError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default:
            throw FigmaError.notAnswered(status: http.statusCode)
        }
        guard let me = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = me["id"] as? String, !id.isEmpty else {
            throw FigmaError.invalidResponse
        }
        let named = [me["email"], me["handle"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        return Identity(id: id, label: named ?? "Figma")
    }
}
