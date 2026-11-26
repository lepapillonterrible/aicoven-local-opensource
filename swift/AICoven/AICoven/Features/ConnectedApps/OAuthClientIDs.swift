import Foundation

/// The OAuth client IDs the app signs in to GitHub and Google with. They
/// are not secrets: a native app's client ID is in every copy of it. The
/// build may set them (`GITHUB_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_ID`,
/// through the xcconfig into the Info.plist), for a fork with its own apps;
/// a value the build left as a placeholder (`YOUR_…`), as an unresolved
/// `$(…)`, or empty is no ID, and AICoven Local's own is used. Sent as it
/// was, a placeholder made GitHub answer 404 and Google refuse the sign-in.
nonisolated enum OAuthClientIDs {
    static let githubDefault = "Iv23liJu04XRFISDVMBO"
    static let googleDefault = "870439799161-1c7u8utd0t0kh3ote5kugh8cj9961ugb.apps.googleusercontent.com"

    static var github: String {
        id(Bundle.main.object(forInfoDictionaryKey: "GITHUB_OAUTH_CLIENT_ID") as? String, otherwise: githubDefault)
    }

    static var google: String {
        id(Bundle.main.object(forInfoDictionaryKey: "GOOGLE_OAUTH_CLIENT_ID") as? String, otherwise: googleDefault)
    }

    /// The configured value where it reads as an ID, else the default.
    static func id(_ configured: String?, otherwise fallback: String) -> String {
        guard let value = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("YOUR_"),
              !value.contains("$(") else { return fallback }
        return value
    }
}
