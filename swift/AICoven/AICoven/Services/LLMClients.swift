import Foundation

/// Errors specific to local chat orchestration
enum LocalChatError: Error, LocalizedError {
    case missingOpenAIAPIKey
    case missingAPIKey(provider: String)
    case missingBaseURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingOpenAIAPIKey:
            "No OpenAI API key configured. Add an OpenAI provider account or set OPENAI_API_KEY."
        case let .missingAPIKey(provider):
            "No \(provider) API key configured. Add a \(provider) provider account or set the provider-specific environment variable."
        case .missingBaseURL:
            "No base URL configured. Set the appropriate base URL in UserDefaults."
        case .invalidResponse:
            "Received an invalid response from the API."
        }
    }
}
