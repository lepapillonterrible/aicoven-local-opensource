import Foundation

/// App environment configuration.
///
/// The local-first client does **not** require a custom backend, so
/// `apiBaseURL` returns an empty string.  This enum is retained for
/// build-configuration awareness only.
enum AppEnvironment {
    case development
    case staging
    case production

    /// Current environment (set via build configuration)
    static var current: AppEnvironment {
        #if DEBUG
        return .development
        #else
        if let envFlag = Bundle.main.object(forInfoDictionaryKey: "APP_ENV") as? String {
            switch envFlag {
            case "staging": return .staging
            case "production": return .production
            default: return .development
            }
        }
        return .production
        #endif
    }

    /// API base URL — unused in the local-first client.
    /// If you connect to a custom backend, set the URL here.
    var apiBaseURL: String {
        ""
    }

    /// Full API URL with /api/v1 path
    var apiURL: String {
        "\(apiBaseURL)/api/v1"
    }
}
