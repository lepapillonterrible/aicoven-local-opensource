import Foundation
import os

/// Which models are asked with a temperature. Some refuse a request that
/// carries one, whatever its value: OpenAI's reasoning models, and
/// Anthropic's from Opus 4.7 on. Such a model is asked without one and
/// answers at its own default.
nonisolated enum ModelTemperature {
    /// The models that refused a temperature while the app ran, as
    /// "provider model".
    private static let refused = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Whether a request to `model` carries a temperature: not where its
    /// name says it takes none, and not once it has refused one.
    static func isSent(provider: String, model: String) -> Bool {
        if takesNoneByName(provider: provider, model: model) { return false }
        let key = key(provider, model)
        return !refused.withLock { $0.contains(key) }
    }

    /// Whether a model's name says it takes no temperature, as the
    /// providers' own models stood in November 2026. A name this does not
    /// know is sent one; if the model refuses it, it is asked again
    /// without (`send`).
    static func takesNoneByName(provider: String, model: String) -> Bool {
        let name = model.lowercased()
        switch provider.lowercased() {
        case "openai":
            // The chat variants (`gpt-5-chat-latest`) are not reasoning
            // models and take one.
            if name.contains("chat") { return false }
            if name.firstMatch(of: #/^o\d/#) != nil { return true }
            guard let version = name.firstMatch(of: #/^gpt-(\d+)(?:\.(\d+))?/#), let major = Int(version.1) else { return false }
            let minor = version.2.flatMap { Int($0) } ?? 0
            // GPT-5 itself and everything from 5.5 on take none; 5.1 to
            // 5.4 take one.
            if major == 5 { return minor == 0 || minor >= 5 }
            return major > 5
        case "anthropic":
            // claude-<family>-<major>[-<minor>][-<date>]: from 4.7 on. An
            // older name (`claude-3-5-sonnet-latest`) is not of this shape.
            guard let version = name.firstMatch(of: #/^claude-[a-z]+-(\d+)(?:-(\d{1,2}))?(?:-|$)/#),
                  let major = Int(version.1) else { return false }
            let minor = version.2.flatMap { Int($0) } ?? 0
            return major > 4 || (major == 4 && minor >= 7)
        default:
            return false
        }
    }

    /// Whether a provider's answer refuses the request for its
    /// temperature: a 400 whose error names the parameter (OpenAI's
    /// `param`) or speaks of it (Anthropic's message). Only that is read
    /// of the answer; nothing of it is kept.
    static func isRefusal(status: Int, body: Data) -> Bool {
        guard status == 400,
              let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = answer["error"] as? [String: Any] else { return false }
        if (error["param"] as? String)?.lowercased() == "temperature" { return true }
        return (error["message"] as? String)?.lowercased().contains("temperature") == true
    }

    /// Sends a chat request whose body is made by `body`: with
    /// `temperature` where the model takes one, with none where it does
    /// not. A model that refuses the temperature is asked once more
    /// without it, and is asked without one for the rest of the app's run.
    static func send(
        _ request: URLRequest,
        to model: String,
        of provider: String,
        temperature: Double,
        with session: URLSession,
        body: (Double?) throws -> Data
    ) async throws -> (Data, URLResponse) {
        var request = request
        guard isSent(provider: provider, model: model) else {
            request.httpBody = try body(nil)
            return try await session.data(for: request)
        }
        request.httpBody = try body(temperature)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, isRefusal(status: http.statusCode, body: data) else {
            return (data, response)
        }
        let key = key(provider, model)
        refused.withLock { _ = $0.insert(key) }
        request.httpBody = try body(nil)
        return try await session.data(for: request)
    }

    private static func key(_ provider: String, _ model: String) -> String {
        "\(provider.lowercased()) \(model.lowercased())"
    }
}
