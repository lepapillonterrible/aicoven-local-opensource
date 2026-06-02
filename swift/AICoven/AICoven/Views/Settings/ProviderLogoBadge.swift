import SwiftUI

/// Renders a provider brand logo (OpenAI, Claude, Gemini, Mistral, Cohere,
/// Hermes, OpenClaw) inside a tinted, circular badge.
///
/// The logos themselves are bundled as template SVGs under
/// `Resources/Assets.xcassets/provider_<slug>.imageset` (sourced from
/// lobehub/lobe-icons, CC-BY). Because the assets are configured with
/// `template-rendering-intent: template`, we tint them with the provider's
/// brand colour at runtime via `.foregroundColor(...)`. The badge fills the
/// same colour at low opacity so the icon reads as a real brand mark rather
/// than the placeholder emoji bubbles we used previously.
///
/// If `assetName` is empty (a provider we don't have an asset for, such as a
/// local Ollama/MLX entry), we fall back to a neutral key glyph so the
/// component never renders an empty box.
struct ProviderLogoBadge: View {
    let assetName: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))

            if !assetName.isEmpty {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(tint)
                    // Logo occupies ~58% of the badge so it visually matches
                    // the optical weight of an SF Symbol of comparable size.
                    .frame(width: size * 0.58, height: size * 0.58)
            } else {
                Image(systemName: "key.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundColor(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: 12) {
        ProviderLogoBadge(assetName: "provider_openai", tint: Color(hex: "#10A37F"), size: 40)
        ProviderLogoBadge(assetName: "provider_claude", tint: Color(hex: "#D97757"), size: 40)
        ProviderLogoBadge(assetName: "provider_gemini", tint: Color(hex: "#1A73E8"), size: 40)
        ProviderLogoBadge(assetName: "provider_mistral", tint: Color(hex: "#FA520F"), size: 40)
        ProviderLogoBadge(assetName: "provider_cohere", tint: Color(hex: "#39594D"), size: 40)
    }
    .padding()
}
