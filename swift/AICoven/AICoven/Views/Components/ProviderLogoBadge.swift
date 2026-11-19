import SwiftUI

/// The bundled logo for a provider slug; "" when there is none.
func providerLogoAssetName(slug: String) -> String {
    switch slug.lowercased() {
    case "openai": "provider_openai"
    case "google", "gemini": "provider_gemini"
    case "anthropic": "provider_claude"
    case "openclaw": "provider_openclaw"
    case "hermes": "provider_hermes"
    case "ollama": ProviderLogoBadge.serverSymbolAssetName
    case "mlx": ProviderLogoBadge.deviceSymbolAssetName
    default: ""
    }
}

/// A provider's name as the app shows it; the slug when it has none.
func providerDisplayName(slug: String) -> String {
    switch slug.lowercased() {
    case "openai": "OpenAI"
    case "anthropic": "Anthropic"
    case "google", "gemini": "Google Gemini"
    case "openrouter": "OpenRouter"
    case "hermes": "Hermes"
    case "ollama": "Ollama"
    case "openclaw": "OpenClaw"
    case "mlx": "MLX on this device"
    default: slug
    }
}

/// A provider's official logo at `size` points.
///
/// The logos are bundled SVGs under `Resources/Assets.xcassets/provider_<slug>.imageset`,
/// with a dark-appearance variant where the brand has one. They render in
/// their own colours. A server the person runs shows a server symbol, a
/// model on this device a chip, and any other provider without a logo a
/// key.
struct ProviderLogoBadge: View {
    static let serverSymbolAssetName = "provider_server"
    static let deviceSymbolAssetName = "provider_device"

    let assetName: String
    let size: CGFloat

    private var symbol: String? {
        switch assetName {
        case Self.serverSymbolAssetName: "server.rack"
        case Self.deviceSymbolAssetName: "cpu"
        case "": "key.fill"
        default: nil
        }
    }

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .foregroundStyle(Color.aicovenTextSecondary)
            } else {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
