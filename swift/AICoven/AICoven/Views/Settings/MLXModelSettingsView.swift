import SwiftUI

/// Dedicated settings view for managing downloaded MLX models.
///
/// Shows all models from the curated catalog with their download status,
/// sizes, and allows downloading new models or deleting existing ones to
/// reclaim disk space.
struct MLXModelSettingsView: View {
    @StateObject private var modelManager = MLXModelManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Header
                VStack(spacing: Spacing.md) {
                    IconBadge(icon: "brain", size: 60, color: .purple)

                    Text("On-Device Models")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.primary)

                    Text("Models run entirely on your Mac using Apple Silicon. No server or API key required.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, Spacing.md)

                if !MLXModelManager.isSupported {
                    unsupportedView
                } else {
                    modelList
                }
            }
            .padding(Spacing.lg)
        }
        .background(Color.aicovenDark)
        .navigationTitle("MLX Models")
    }

    // MARK: - Subviews

    private var unsupportedView: some View {
        GlassCard {
            VStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)

                Text("Apple Silicon Required")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                Text("MLX on-device models require a Mac with Apple Silicon (M1 or newer).")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.lg)
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(modelManager.catalog) { model in
                modelCard(for: model)
            }
        }
    }

    private func modelCard(for model: MLXModelInfo) -> some View {
        let state = modelManager.downloadStates[model.id] ?? .notDownloaded
        let isActive = modelManager.activeModelID == model.id

        return GlassCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Header row
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.xs) {
                            Text(model.displayName)
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            if isActive {
                                Text("ACTIVE")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green))
                            }
                        }

                        Text(model.summary)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }

                    Spacer()

                    Text(model.parameterCount)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.aicovenTextTertiary)
                }

                // Model specs
                HStack(spacing: Spacing.md) {
                    Label(model.formattedDownloadSize, systemImage: "arrow.down.circle")
                    Label("\(model.minRAMGB) GB RAM", systemImage: "memorychip")
                    Label(model.quantization, systemImage: "cube")
                }
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)

                // Action buttons based on state
                HStack(spacing: Spacing.sm) {
                    switch state {
                    case .notDownloaded:
                        Button {
                            Task { await modelManager.downloadModel(model.id) }
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                        }

                    case .downloading(let progress):
                        HStack(spacing: Spacing.sm) {
                            ProgressView(value: progress)
                                .tint(.aicovenTeal)
                                .frame(maxWidth: 120)

                            Text("\(Int(progress * 100))%")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            Button {
                                modelManager.cancelDownload(model.id)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.aicovenTextTertiary)
                            }
                        }

                    case .downloaded:
                        HStack(spacing: Spacing.sm) {
                            if !isActive {
                                Button {
                                    modelManager.setActiveModel(model.id)
                                } label: {
                                    Label("Use This Model", systemImage: "checkmark.circle")
                                        .font(.aicovenBodySmall)
                                        .foregroundColor(.aicovenTextPrimary)
                                        .padding(.horizontal, Spacing.md)
                                        .padding(.vertical, Spacing.sm)
                                        .background(Color.aicovenGlass)
                                        .cornerRadius(BorderRadius.md)
                                }
                            } else {
                                Label("Currently Active", systemImage: "checkmark.seal.fill")
                                    .font(.aicovenBodySmall)
                                    .foregroundColor(.green)
                            }

                            Spacer()

                            Button {
                                modelManager.deleteModel(model.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.7))
                            }
                        }

                    case .error(let message):
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(message)
                                .font(.aicovenCaption)
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }

                        Button {
                            Task { await modelManager.downloadModel(model.id) }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                        }
                    }
                }
            }
            .padding(Spacing.md)
        }
    }
}
