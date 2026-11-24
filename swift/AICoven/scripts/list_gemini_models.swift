
import Foundation

// Script to list available Gemini models using the API key from environment or arguments
// Usage: swift list_gemini_models.swift [API_KEY]

let apiKey: String
if CommandLine.arguments.count > 1 {
    apiKey = CommandLine.arguments[1]
} else if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] {
    apiKey = envKey
} else {
    print("Error: Please provide API key as argument or GEMINI_API_KEY environment variable")
    exit(1)
}

struct GeminiListResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let displayName: String?
        let description: String?
        let supportedGenerationMethods: [String]?
    }

    let models: [Model]
}

let urlString = "https://generativelanguage.googleapis.com/v1beta/models"
guard let url = URL(string: urlString) else {
    print("Invalid URL")
    exit(1)
}

/// The key in its header, never in the address.
var request = URLRequest(url: url)
request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

print("Fetching models from \(urlString)...")

let semaphore = DispatchSemaphore(value: 0)

let task = URLSession.shared.dataTask(with: request) { data, _, error in
    defer { semaphore.signal() }

    if let error {
        print("Error: \(error.localizedDescription)")
        return
    }

    guard let data else {
        print("No data received")
        return
    }

    do {
        let decoded = try JSONDecoder().decode(GeminiListResponse.self, from: data)
        print("\nFound \(decoded.models.count) models:")
        print("----------------------------------------")
        for model in decoded.models {
            print("Name: \(model.name)")
            print("Display: \(model.displayName ?? "N/A")")
            print("Methods: \(model.supportedGenerationMethods?.joined(separator: ", ") ?? "N/A")")
            print("----------------------------------------")
        }
    } catch {
        print("Decoding error: \(error)")
        if let str = String(data: data, encoding: .utf8) {
            print("Raw response: \(str)")
        }
    }
}

task.resume()
semaphore.wait()
