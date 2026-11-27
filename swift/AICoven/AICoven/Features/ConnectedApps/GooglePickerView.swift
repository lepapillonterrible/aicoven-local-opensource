import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A file chosen in Google's Picker. With `drive.file`, choosing it is what
/// lets the app's Google tools open it.
nonisolated struct GooglePickerFile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let mimeType: String
}

/// Google's Picker, on AICoven Local's own page (`pages/google-picker` in
/// this repository, published to GitHub Pages from its `gh-pages` branch).
/// The Picker needs the person signed in to Google in the browser that
/// shows it, and Google allows no sign-in in an embedded web view, so the
/// page is opened in the system's browser, as the cloud app opens its own.
/// It is given the token, the app ID and a state in its fragment, which the
/// browser sends to no server, and answers at `aicoven-local://google-picker`
/// with the state and the files chosen.
nonisolated enum GooglePickerPage {
    /// Where the page is. A fork that publishes its own changes this.
    static let address = "https://lepapillonterrible.github.io/aicoven-local-opensource/google-picker/"

    static let callbackScheme = "aicoven-local"
    static let callbackHost = "google-picker"
    /// The most files the page gives back at once.
    static let mostFiles = 25

    /// What the page said.
    enum Answer: Equatable {
        case picked([GooglePickerFile])
        case cancelled
        case failed
    }

    /// The page's address with what it needs in its fragment, or nil where
    /// one of them does not read as it must.
    static func url(token: String, appID: String, state: String) -> URL? {
        guard (1 ... 4096).contains(token.utf8.count),
              token.utf8.allSatisfy({ (0x21 ... 0x7E).contains($0) }),
              (1 ... 20).contains(appID.utf8.count),
              appID.utf8.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }),
              GoogleToolArguments.isID(state), state.utf8.count >= 16,
              var parts = URLComponents(string: address) else { return nil }
        var fragment = URLComponents()
        fragment.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "app_id", value: appID),
            URLQueryItem(name: "state", value: state)
        ]
        // `+` would read as a space on the page, which reads the fragment as
        // a form.
        parts.percentEncodedFragment = fragment.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    /// A new state for one opening of the page.
    static func newState() -> String? {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What the page answered, read strictly: only its own address, with
    /// the state it was given, and files that read as Google's. Nil for
    /// anything else, which is no answer of the page's.
    static func answer(of url: URL, state: String) -> Answer? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == callbackScheme, parts.host == callbackHost,
              parts.path.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { return nil }
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard ["state", "status", "files"].contains(item.name),
                  values[item.name] == nil, let value = item.value, !value.isEmpty else { return nil }
            values[item.name] = value
        }
        guard values["state"] == state, let status = values["status"] else { return nil }
        switch status {
        case "cancel":
            return values["files"] == nil ? .cancelled : nil
        case "error":
            return values["files"] == nil ? .failed : nil
        case "picked":
            guard let encoded = values["files"], let files = files(from: encoded) else { return nil }
            return .picked(files)
        default:
            return nil
        }
    }

    /// The files of a `picked` answer: base64url of a JSON list of
    /// `{id, name, mimeType}`, 1 to `mostFiles` of them.
    private static func files(from encoded: String) -> [GooglePickerFile]? {
        guard encoded.utf8.count <= 64 * 1024 else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let files = try? JSONDecoder().decode([GooglePickerFile].self, from: data),
              (1 ... mostFiles).contains(files.count) else { return nil }
        var seen = Set<String>()
        var kept: [GooglePickerFile] = []
        for file in files {
            guard GoogleToolArguments.isID(file.id), file.name.count <= 200,
                  file.mimeType.utf8.count <= 255,
                  file.mimeType.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F })
            else { return nil }
            guard seen.insert(file.id).inserted else { continue }
            kept.append(GooglePickerFile(
                id: file.id,
                name: AttachmentContext.plainName(file.name),
                mimeType: file.mimeType
            ))
        }
        return kept
    }
}

/// One opening of the Picker page in the system's browser, held until it
/// answers or is called off.
@MainActor
final class GooglePickerBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    /// Opens `url` and gives the address the page answered at. Throws
    /// `CancellationError` where the person closed the browser, or the
    /// opening was called off.
    func open(_ url: URL) async throws -> URL {
        cancel()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: GooglePickerPage.callbackScheme
                ) { [weak self] answer, error in
                    Task { @MainActor in self?.finish(answer, error) }
                }
                session.presentationContextProvider = self
                // The browser's own sign-in to Google is what the Picker needs.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() {
                    finish(nil, URLError(.cannotOpenFile))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// Calls off the opening under way, if any.
    func cancel() {
        let session = session
        finish(nil, CancellationError())
        session?.cancel()
    }

    private func finish(_ answer: URL?, _ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: error)
        } else if let answer {
            continuation.resume(returning: answer)
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
            #endif
        }
    }
}
