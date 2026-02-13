import Foundation
import AuthenticationServices
import CommonCrypto
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Protocol for OAuth authentication flows
protocol OAuthFlow {
    /// Start the OAuth flow and return the token bundle on success
    func authenticate() async throws -> OAuthTokenBundle
}

// MARK: - GitHub Device Flow

/// GitHub Device Flow - no client secret needed, ideal for open-source apps.
/// User visits github.com/login/device and enters a code to authorize.
final class GitHubDeviceFlow: OAuthFlow {

    private let clientId: String
    private let scopes: [String]

    /// Callback to display the user code and verification URL to the user
    var onUserCodeReceived: ((String, String) -> Void)?

    init(clientId: String, scopes: [String]? = nil) {
        self.clientId = clientId
        self.scopes = scopes ?? ConnectedAppProvider.github.defaultScopes
    }

    /// Start the GitHub Device Flow
    func authenticate() async throws -> OAuthTokenBundle {
        // Step 1: Request device and user codes
        let deviceCode = try await requestDeviceCodes()

        // Step 2: Notify UI to display the user code
        await MainActor.run {
            onUserCodeReceived?(deviceCode.userCode, deviceCode.verificationUri)
        }

        // Step 3: Poll for access token
        return try await pollForAccessToken(deviceCode: deviceCode)
    }

    /// Device code response from GitHub
    private struct DeviceCodeResponse {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int
    }

    /// Request device and user codes from GitHub
    private func requestDeviceCodes() async throws -> DeviceCodeResponse {
        let url = URL(string: "https://github.com/login/device/code")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "scope": scopes.joined(separator: " ")
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ConnectedAccountError.oauthFailed(message: "Failed to get device code: \(errorText)")
        }

        // Parse response
        struct Response: Codable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let expires_in: Int
            let interval: Int
        }

        let codeResponse = try JSONDecoder().decode(Response.self, from: data)

        return DeviceCodeResponse(
            deviceCode: codeResponse.device_code,
            userCode: codeResponse.user_code,
            verificationUri: codeResponse.verification_uri,
            expiresIn: codeResponse.expires_in,
            interval: codeResponse.interval
        )
    }

    /// Poll GitHub for access token after user authorizes
    private func pollForAccessToken(deviceCode: DeviceCodeResponse) async throws -> OAuthTokenBundle {
        let url = URL(string: "https://github.com/login/oauth/access_token")!
        let pollInterval = TimeInterval(max(deviceCode.interval, 5)) // Minimum 5 seconds
        let expiresAt = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))

        while Date() < expiresAt {
            // Wait before polling
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            // Check if task was cancelled
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let body = [
                "client_id": clientId,
                "device_code": deviceCode.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ]
            request.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)

            // Parse response - could be success, pending, or error
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Check for error
                if let error = json["error"] as? String {
                    switch error {
                    case "authorization_pending":
                        // User hasn't authorized yet, continue polling
                        continue
                    case "slow_down":
                        // Need to slow down polling - wait extra time
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    case "expired_token":
                        throw ConnectedAccountError.oauthFailed(message: "Authorization timed out. Please try again.")
                    case "access_denied":
                        throw ConnectedAccountError.oauthFailed(message: "Authorization was denied.")
                    default:
                        throw ConnectedAccountError.oauthFailed(message: "Authorization failed: \(error)")
                    }
                }

                // Check for access token
                if let accessToken = json["access_token"] as? String {
                    let tokenType = json["token_type"] as? String ?? "bearer"
                    let scope = json["scope"] as? String ?? ""

                    return OAuthTokenBundle(
                        accessToken: accessToken,
                        refreshToken: nil, // GitHub doesn't provide refresh tokens
                        tokenType: tokenType,
                        expiresAt: nil, // GitHub tokens don't expire
                        scopes: scope.split(separator: ",").map(String.init)
                    )
                }
            }
        }

        throw ConnectedAccountError.oauthFailed(message: "Authorization timed out. Please try again.")
    }
}

// MARK: - Google OAuth Flow (PKCE)

/// Google OAuth flow using PKCE (no client secret needed)
@MainActor
final class GoogleOAuthFlow: NSObject, OAuthFlow, ASWebAuthenticationPresentationContextProviding {

    private let clientId: String
    private let scopes: [String]

    /// Redirect URI using Google's reversed client ID format for native apps.
    /// Format: com.googleusercontent.apps.CLIENT_ID:/oauth2redirect
    private var redirectUri: String {
        // Extract the full client ID prefix (everything before .apps.googleusercontent.com)
        let prefix = clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix):/oauth2redirect"
    }

    /// The URL scheme portion for ASWebAuthenticationSession callback
    private var callbackURLScheme: String {
        let prefix = clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }

    // PKCE parameters
    private var codeVerifier: String = ""
    private var codeChallenge: String = ""

    init(clientId: String, scopes: [String]? = nil) {
        self.clientId = clientId
        self.scopes = scopes ?? ConnectedAppProvider.googleDrive.defaultScopes
    }

    /// Start the Google OAuth flow with PKCE
    func authenticate() async throws -> OAuthTokenBundle {
        // Generate PKCE code verifier and challenge
        codeVerifier = generateCodeVerifier()
        codeChallenge = generateCodeChallenge(verifier: codeVerifier)

        // Generate state for CSRF protection
        let state = UUID().uuidString

        // Build authorization URL
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"), // Request refresh token
            URLQueryItem(name: "prompt", value: "consent") // Force consent to get refresh token
        ]

        guard let authURL = components.url else {
            throw ConnectedAccountError.oauthFailed(message: "Failed to build authorization URL")
        }

        // Start web authentication session
        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: self.callbackURLScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: ConnectedAccountError.oauthFailed(message: "No callback URL received"))
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false

            if !session.start() {
                continuation.resume(throwing: ConnectedAccountError.oauthFailed(message: "Failed to start authentication session"))
            }
        }

        // Parse the callback URL for the authorization code
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
            throw ConnectedAccountError.oauthFailed(message: "Invalid callback URL or state mismatch")
        }

        // Exchange code for access token
        return try await exchangeCodeForToken(code: code)
    }

    /// Exchange authorization code for access token using PKCE
    private func exchangeCodeForToken(code: String) async throws -> OAuthTokenBundle {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectUri
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ConnectedAccountError.oauthFailed(message: "Token exchange failed: \(errorText)")
        }

        // Parse response
        struct TokenResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let token_type: String
            let scope: String?
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        return OAuthTokenBundle(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            tokenType: tokenResponse.token_type,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in)),
            scopes: tokenResponse.scope?.split(separator: " ").map(String.init) ?? scopes
        )
    }

    // MARK: - PKCE Helpers

    /// Generate a random code verifier for PKCE
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generate SHA256 code challenge from verifier
    private func generateCodeChallenge(verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }

        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}
