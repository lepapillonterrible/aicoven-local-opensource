import SwiftUI

/// Dedicated settings view for managing downloaded MLX models.
///
/// Shows all models from the curated catalog grouped by category,
/// with download status, tier badges, and device-aware filtering.
struct MLXModelSettingsView: View {
    @StateObject private var modelManager = MLXModelManager.shared

    /// Currently selected category filter.
    @State private var selectedCategory: MLXModelCategory?

    /// Benchmark state.
    @State private var benchmarkResults: [String: MCPToolCallingBenchmark.BenchmarkResult] = [:]
    @State private var benchmarkingModelID: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Header
                VStack(spacing: Spacing.md) {
                    IconBadge(icon: "brain", size: 60, color: .purple)

                    Text("On-Device Models")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.primary)

                    Text("Models run entirely on your device using Apple Silicon. No server or API key required.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                        .multilineTextAlignment(.center)

                    if MLXModelManager.isMobileOnly {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "iphone")
                                .foregroundColor(.aicovenTeal)
                            Text("Showing models optimised for iPhone")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                        }
                    }
                }
                .padding(.bottom, Spacing.md)

                if !MLXModelManager.isSupported {
                    unsupportedView
                } else {
                    categoryFilter
                    modelList
                }
            }
            .padding(Spacing.lg)
        }
        .background(NebulaBackground())
        .navigationTitle("MLX Models")
        .onAppear {
            benchmarkResults = MCPToolCallingBenchmark.shared.loadResults()
        }
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

                Text("MLX on-device models require a Mac or iPad with Apple Silicon (M1 or newer) and at least 8 GB of RAM, or an iPhone with 6 GB+ RAM.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: - Category Filter

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                filterPill(title: "All", category: nil)

                ForEach(availableCategories, id: \.self) { cat in
                    filterPill(title: cat.displayName, category: cat)
                }
            }
            .padding(.horizontal, Spacing.xs)
        }
    }

    /// Categories that actually have models in the device-filtered catalog.
    private var availableCategories: [MLXModelCategory] {
        let cats = Set(modelManager.deviceFilteredCatalog.map(\.category))
        return MLXModelCategory.allCases.filter { cats.contains($0) }
    }

    private func filterPill(title: String, category: MLXModelCategory?) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedCategory = category
            }
        } label: {
            Text(title)
                .font(.aicovenBodySmall)
                .foregroundColor(isSelected ? .white : .aicovenTextSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.aicovenTeal : Color.aicovenGlass)
                )
        }
    }

    // MARK: - Model List

    private var filteredModels: [MLXModelInfo] {
        let base = modelManager.deviceFilteredCatalog
        if let cat = selectedCategory {
            return base.filter { $0.category == cat }
        }
        return base
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(filteredModels) { model in
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

                            if model.isRecommended {
                                Text("⭐")
                                    .font(.system(size: 12))
                            }

                            tierBadge(for: model.tier)

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

                // Tags
                if !model.recommendedFor.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.xs) {
                            ForEach(model.recommendedFor, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.aicovenTeal)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .strokeBorder(Color.aicovenTeal.opacity(0.4), lineWidth: 1)
                                    )
                            }
                        }
                    }
                }

                // Model specs
                HStack(spacing: Spacing.md) {
                    Label(model.formattedDownloadSize, systemImage: "arrow.down.circle")
                    Label("\(model.minRAMGB) GB RAM", systemImage: "memorychip")
                    Label(model.quantization, systemImage: "cube")
                    Label(model.category.displayName, systemImage: model.category.iconName)
                }
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)

                // RAM warning
                if !canRunOnDevice(model) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("This model may exceed your device's available memory.")
                            .font(.aicovenCaption)
                            .foregroundColor(.orange)
                    }
                }

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

                    case let .downloading(progress):
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
                        VStack(alignment: .leading, spacing: Spacing.sm) {
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

                                // Benchmark button
                                if benchmarkingModelID == model.id {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .tint(.aicovenTeal)
                                } else {
                                    Button {
                                        Task { await runBenchmark(for: model) }
                                    } label: {
                                        Label("Test", systemImage: "gauge.with.dots.needle.33percent")
                                            .font(.aicovenBodySmall)
                                            .foregroundColor(.aicovenTextSecondary)
                                            .padding(.horizontal, Spacing.sm)
                                            .padding(.vertical, Spacing.sm)
                                            .background(Color.aicovenGlass)
                                            .cornerRadius(BorderRadius.md)
                                    }
                                }

                                Spacer()

                                Button {
                                    modelManager.deleteModel(model.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red.opacity(0.7))
                                }
                            }

                            // Benchmark results (if available)
                            if let result = benchmarkResults[model.id] {
                                benchmarkResultView(result)
                            }
                        }

                    case let .error(message):
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

    // MARK: - Helpers

    private func tierBadge(for tier: MLXModelTier) -> some View {
        Text(tier == .core ? "CORE" : "OPTIONAL")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(tier == .core ? .white : .aicovenTextTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(tier == .core ? Color.purple.opacity(0.8) : Color.aicovenGlass)
            )
    }

    /// Heuristic check: compare model's minimum RAM against device's physical memory.
    private func canRunOnDevice(_ model: MLXModelInfo) -> Bool {
        let deviceRAMGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        // Model needs minRAMGB for the model + ~2 GB for system overhead.
        return deviceRAMGB >= model.minRAMGB + 2
    }

    // MARK: - Benchmark

    private func runBenchmark(for model: MLXModelInfo) async {
        benchmarkingModelID = model.id
        let client = MLXLLMClient(modelID: model.id)
        let result = await MCPToolCallingBenchmark.shared.run(
            client: client,
            modelID: model.id
        )
        benchmarkResults[model.id] = result
        benchmarkingModelID = nil
    }

    private func benchmarkResultView(_ result: MCPToolCallingBenchmark.BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("MCP Tool Calling Benchmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.aicovenTextSecondary)

            HStack(spacing: Spacing.md) {
                benchmarkMetric(
                    label: "Accuracy",
                    value: "\(Int(result.accuracy * 100))%",
                    color: result.accuracy >= 0.8 ? .green : (result.accuracy >= 0.5 ? .orange : .red)
                )
                benchmarkMetric(
                    label: "Refusals",
                    value: "\(Int(result.refusalRate * 100))%",
                    color: result.refusalRate <= 0.1 ? .green : .orange
                )
                benchmarkMetric(
                    label: "Halluc.",
                    value: "\(Int(result.hallucinationRate * 100))%",
                    color: result.hallucinationRate <= 0.1 ? .green : .red
                )
                benchmarkMetric(
                    label: "Latency",
                    value: "\(Int(result.averageLatencyMs))ms",
                    color: result.averageLatencyMs <= 500 ? .green : .orange
                )
            }
        }
        .padding(Spacing.sm)
        .background(Color.aicovenGlass.opacity(0.5))
        .cornerRadius(BorderRadius.sm)
    }

    private func benchmarkMetric(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.aicovenTextTertiary)
        }
    }
}

// MARK: - MLXModelCategory Display Helpers

extension MLXModelCategory {
    var displayName: String {
        switch self {
        case .general: "General"
        case .coding: "Coding"
        case .mobile: "Mobile"
        }
    }

    var iconName: String {
        switch self {
        case .general: "sparkles"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .mobile: "iphone"
        }
    }
}
