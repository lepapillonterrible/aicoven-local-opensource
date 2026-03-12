import Foundation
internal import Combine

#if canImport(UIKit)
import UIKit
#endif

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

// MARK: - MLX Model Catalog

/// Use-case category for a model.
enum MLXModelCategory: String, Codable, CaseIterable, Sendable {
    /// General-purpose chat and tool calling.
    case general
    /// Optimised for code generation and developer tools.
    case coding
    /// Lightweight models suitable for iPhones / constrained devices.
    case mobile
}

/// Download priority tier.
enum MLXModelTier: String, Codable, Sendable {
    /// Recommended for all users.
    case core
    /// Optional download for specialised use-cases.
    case specialized
}

/// Metadata for a model available in the MLX curated catalog.
struct MLXModelInfo: Identifiable, Codable, Sendable {
    /// Hugging Face model ID (e.g. "mlx-community/Qwen3-4B-4bit").
    let id: String
    /// Human-readable display name.
    let displayName: String
    /// Short description of the model's strengths.
    let summary: String
    /// Approximate download size in bytes.
    let downloadSizeBytes: Int64
    /// Minimum recommended RAM in GB.
    let minRAMGB: Int
    /// Number of parameters (e.g. "4B").
    let parameterCount: String
    /// Quantization level (e.g. "4-bit").
    let quantization: String
    /// Use-case category (general / coding / mobile).
    let category: MLXModelCategory
    /// Download priority tier (core / specialized).
    let tier: MLXModelTier
    /// Tags describing ideal use-cases (e.g. "GitHub", "MCP Tools").
    let recommendedFor: [String]
    /// Whether this model is a top pick for its category.
    let isRecommended: Bool

    var formattedDownloadSize: String {
        ByteCountFormatter.string(fromByteCount: downloadSizeBytes, countStyle: .file)
    }
}

/// Download state for a single model.
enum MLXDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case error(String)
}

// MARK: - Model Manager

/// Manages MLX model discovery, downloading, and disk lifecycle.
///
/// The manager provides a curated catalog of recommended quantized models
/// from the `mlx-community` Hugging Face organisation and tracks which
/// ones have been downloaded to the local cache.
@MainActor
final class MLXModelManager: ObservableObject {
    static let shared = MLXModelManager()

    // MARK: - Published state

    /// Curated catalog of recommended models.
    @Published private(set) var catalog: [MLXModelInfo] = MLXModelManager.defaultCatalog

    /// Download state per model ID.
    @Published private(set) var downloadStates: [String: MLXDownloadState] = [:]

    /// The currently active (loaded in memory) model ID, if any.
    @Published var activeModelID: String?

    // MARK: - Persistence keys

    private static let downloadedModelsKey = "MLXModelManager.downloadedModelIDs"
    private static let activeModelKey = "MLXModelManager.activeModelID"

    // MARK: - Init

    private init() {
        loadPersistedState()
    }

    // MARK: - Curated catalog

    static let defaultCatalog: [MLXModelInfo] = [
        // ── AICoven Fine-Tuned ──────────────────────────────────────
        MLXModelInfo(
            id: "aicoven/Llama-3.2-3B-Instruct-4bit-MCP-LoRA",
            displayName: "AICoven MCP 3B ⚡",
            summary: "Fine-tuned for MCP tool calling. Best accuracy for AICoven workflows.",
            downloadSizeBytes: 1_800_000_000,
            minRAMGB: 3,
            parameterCount: "3B",
            quantization: "4-bit",
            category: .general,
            tier: .core,
            recommendedFor: ["MCP Tools", "Tool Calling", "Agents"],
            isRecommended: true
        ),
        MLXModelInfo(
            id: "aicoven/Gemma-2-2B-IT-4bit-MCP-iOS",
            displayName: "AICoven MCP 2B iOS 📱",
            summary: "Compact model fine-tuned for iOS MCP tool calling. No file/shell tools.",
            downloadSizeBytes: 1_470_000_000,
            minRAMGB: 2,
            parameterCount: "2B",
            quantization: "4-bit",
            category: .general,
            tier: .core,
            recommendedFor: ["MCP Tools", "iOS", "On-Device"],
            isRecommended: true
        ),
        // ── Core: General ────────────────────────────────────────────
        MLXModelInfo(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            displayName: "Qwen 2.5 1.5B",
            summary: "Ultra-compact model. Ideal for iPhones with strict memory limits.",
            downloadSizeBytes: 1_100_000_000,
            minRAMGB: 4,
            parameterCount: "1.5B",
            quantization: "4-bit",
            category: .mobile,
            tier: .core,
            recommendedFor: ["iOS", "Low RAM"],
            isRecommended: false
        ),
        MLXModelInfo(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen 3.5 4B 🆕 Best Small",
            summary: "Newest & best 4B model. Hybrid reasoning, native tool calling, 262K context. Replaces Qwen 3 4B.",
            downloadSizeBytes: 3_030_000_000,
            minRAMGB: 4,
            parameterCount: "4B",
            quantization: "4-bit",
            category: .general,
            tier: .core,
            recommendedFor: ["MCP Tools", "Chat", "Reasoning", "Agents"],
            isRecommended: true
        ),
        MLXModelInfo(
            id: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen 3 4B",
            summary: "Previous-gen all-rounder. Use Qwen 3.5 4B for best results.",
            downloadSizeBytes: 2_400_000_000,
            minRAMGB: 4,
            parameterCount: "4B",
            quantization: "4-bit",
            category: .general,
            tier: .core,
            recommendedFor: ["MCP Tools", "Chat", "Reasoning"],
            isRecommended: false
        ),
        MLXModelInfo(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B",
            summary: "Meta's compact model. Fast and good at following instructions.",
            downloadSizeBytes: 1_800_000_000,
            minRAMGB: 3,
            parameterCount: "3B",
            quantization: "4-bit",
            category: .general,
            tier: .core,
            recommendedFor: ["MCP Tools", "Chat"],
            isRecommended: true
        ),
        MLXModelInfo(
            id: "mlx-community/Phi-4-mini-instruct-4bit",
            displayName: "Phi-4 Mini",
            summary: "Microsoft's compact model. Great reasoning per parameter.",
            downloadSizeBytes: 2_200_000_000,
            minRAMGB: 4,
            parameterCount: "3.8B",
            quantization: "4-bit",
            category: .general,
            tier: .core,
            recommendedFor: ["Fast Inference", "Reasoning"],
            isRecommended: false
        ),
        MLXModelInfo(
            id: "mlx-community/gemma-3-4b-it-4bit",
            displayName: "Gemma 3 4B",
            summary: "Google's multilingual model. Good for diverse tasks.",
            downloadSizeBytes: 2_500_000_000,
            minRAMGB: 4,
            parameterCount: "4B",
            quantization: "4-bit",
            category: .general,
            tier: .core,
            recommendedFor: ["Multilingual", "Chat"],
            isRecommended: false
        ),
        // ── Core: Mid-Size ───────────────────────────────────────────
        MLXModelInfo(
            id: "mlx-community/Qwen3.5-9B-MLX-4bit",
            displayName: "Qwen 3.5 9B 🎯 Sweet Spot",
            summary: "Best quality-to-speed ratio. Strong reasoning, coding, and tool calling. Ideal for 16GB Macs.",
            downloadSizeBytes: 5_500_000_000,
            minRAMGB: 8,
            parameterCount: "9B",
            quantization: "4-bit",
            category: .general,
            tier: .core,
            recommendedFor: ["MCP Tools", "Reasoning", "Coding", "Agents"],
            isRecommended: true
        ),
        // ── Specialized: Large ──────────────────────────────────────
        MLXModelInfo(
            id: "mlx-community/Qwen3.5-35B-A3B-4bit",
            displayName: "Qwen 3.5 35B MoE ⚡ Speed King",
            summary: "35B knowledge at 3B speed — only 3B params active per token. Blazing fast inference with frontier quality. Best for 16GB+.",
            downloadSizeBytes: 12_000_000_000,
            minRAMGB: 16,
            parameterCount: "35B (3B active)",
            quantization: "4-bit",
            category: .general,
            tier: .specialized,
            recommendedFor: ["Fast Inference", "Tool Calling", "Agents", "Coding"],
            isRecommended: true
        ),
        MLXModelInfo(
            id: "mlx-community/Qwen3.5-27B-4bit",
            displayName: "Qwen 3.5 27B ⚠️",
            summary: "Frontier-class dense model. Native tool calling, 262K context. Requires 24GB+ RAM — tight on 24GB devices (limited context). Best with 32GB+.",
            downloadSizeBytes: 14_500_000_000,
            minRAMGB: 24,
            parameterCount: "27B",
            quantization: "4-bit",
            category: .general,
            tier: .specialized,
            recommendedFor: ["Tool Calling", "Coding", "Reasoning", "Agents"],
            isRecommended: false
        ),
        MLXModelInfo(
            id: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            displayName: "Qwen 2.5 14B — Proven Workhorse",
            summary: "Battle-tested 14B with 128K context. Strong across all tasks, 29 languages. Needs 12GB+ RAM.",
            downloadSizeBytes: 8_310_000_000,
            minRAMGB: 12,
            parameterCount: "14B",
            quantization: "4-bit",
            category: .general,
            tier: .specialized,
            recommendedFor: ["Chat", "Reasoning", "Multilingual", "Long Context"],
            isRecommended: false
        ),
        // ── Specialized: Coding ─────────────────────────────────────
        MLXModelInfo(
            id: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
            displayName: "Qwen 2.5 Coder 14B 💻 Best Coder",
            summary: "Best coding model in the catalog. 128K context for large codebases. Needs 12GB+ RAM.",
            downloadSizeBytes: 8_330_000_000,
            minRAMGB: 12,
            parameterCount: "14B",
            quantization: "4-bit",
            category: .coding,
            tier: .specialized,
            recommendedFor: ["GitHub", "Code", "Debugging", "Architecture"],
            isRecommended: true
        ),
        MLXModelInfo(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            displayName: "Qwen 2.5 Coder 7B",
            summary: "Purpose-built for code. Best for GitHub and developer tools.",
            downloadSizeBytes: 4_000_000_000,
            minRAMGB: 8,
            parameterCount: "7B",
            quantization: "4-bit",
            category: .coding,
            tier: .specialized,
            recommendedFor: ["GitHub", "Code", "Debugging"],
            isRecommended: true
        ),
        MLXModelInfo(
            id: "mlx-community/DeepSeek-R1-Distill-Qwen-8B-4bit",
            displayName: "DeepSeek R1 8B",
            summary: "Reasoning powerhouse. Great for complex multi-step tasks.",
            downloadSizeBytes: 4_500_000_000,
            minRAMGB: 8,
            parameterCount: "8B",
            quantization: "4-bit",
            category: .coding,
            tier: .specialized,
            recommendedFor: ["Reasoning", "Debugging", "Architecture"],
            isRecommended: false
        ),
        MLXModelInfo(
            id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            displayName: "Mistral 7B v0.3",
            summary: "Strong reasoning and coding. Needs more RAM.",
            downloadSizeBytes: 4_100_000_000,
            minRAMGB: 6,
            parameterCount: "7B",
            quantization: "4-bit",
            category: .general,
            tier: .specialized,
            recommendedFor: ["Reasoning", "Code"],
            isRecommended: false
        ),
        // ── Specialized: Mobile ─────────────────────────────────────
        MLXModelInfo(
            id: "mlx-community/Qwen3.5-2B-MLX-4bit",
            displayName: "Qwen 3.5 2B 📱 Best Mobile",
            summary: "Best small model for iPhones. Modern hybrid reasoning in a tiny package.",
            downloadSizeBytes: 1_300_000_000,
            minRAMGB: 3,
            parameterCount: "2B",
            quantization: "4-bit",
            category: .mobile,
            tier: .core,
            recommendedFor: ["iOS", "On-Device", "Low RAM"],
            isRecommended: true
        ),
        MLXModelInfo(
            id: "mlx-community/gemma-2-2b-it-4bit",
            displayName: "Gemma 2 2B",
            summary: "Ultra-lightweight. Ideal for iPhone and constrained devices.",
            downloadSizeBytes: 1_500_000_000,
            minRAMGB: 3,
            parameterCount: "2B",
            quantization: "4-bit",
            category: .mobile,
            tier: .specialized,
            recommendedFor: ["iOS", "Low RAM"],
            isRecommended: true
        )
    ]

    // MARK: - Platform check

    /// Minimum RAM for full-catalog MLX inference (8 GB — iPads & Macs).
    private static let minimumRAMBytes: UInt64 = 8_000_000_000
    /// Lower threshold for mobile-tier models on iPhone (6 GB — iPhone 15 Pro+).
    private static let mobileMinRAMBytes: UInt64 = 6_000_000_000

    /// Whether the current device supports MLX inference (any model).
    /// Supported on: macOS with Apple Silicon, iPads with 8 GB+ RAM,
    /// and iPhones with 6 GB+ RAM (mobile-tier models only).
    nonisolated static var isSupported: Bool {
        #if arch(arm64)
        #if os(macOS)
        return true
        #elseif os(iOS)
        let physicalRAM = ProcessInfo.processInfo.physicalMemory
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        // iPads: 8 GB+   iPhones: 6 GB+ (mobile-tier only)
        return (isIPad && physicalRAM >= minimumRAMBytes)
            || (!isIPad && physicalRAM >= mobileMinRAMBytes)
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    /// Whether the device is limited to mobile-tier models (iPhones).
    nonisolated static var isMobileOnly: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom != .pad
        #else
        return false
        #endif
    }

    /// Catalog filtered for the current device's capabilities.
    /// On iPhone this only returns `.mobile` models and small general
    /// models (≤ 3 GB RAM). On Mac/iPad it returns everything.
    var deviceFilteredCatalog: [MLXModelInfo] {
        if Self.isMobileOnly {
            return catalog.filter { $0.category == .mobile || $0.minRAMGB <= 3 }
        }
        return catalog
    }

    // MARK: - Download management

    /// Check whether a model has been downloaded to the local HF cache.
    func isDownloaded(_ modelID: String) -> Bool {
        downloadStates[modelID] == .downloaded
    }

    /// Begin downloading a model. In a real implementation this calls
    /// `MLXLMCommon.loadModel(id:)` which handles HF Hub download + caching.
    /// For now, we track state and delegate to the MLX framework.
    func downloadModel(_ modelID: String) async {
        guard downloadStates[modelID] != .downloaded else { return }
        downloadStates[modelID] = .downloading(progress: 0.0)

        #if canImport(MLXLLM)
        do {
            // MLX's loadModel downloads from HF Hub and caches locally.
            // Progress is not directly observable in the current API,
            // so we show indeterminate and then mark complete.
            downloadStates[modelID] = .downloading(progress: 0.5)
            _ = try await loadModelContainer(id: modelID)
            downloadStates[modelID] = .downloaded
            persistDownloadedModel(modelID)
        } catch {
            downloadStates[modelID] = .error(error.localizedDescription)
        }
        #else
        // Without the MLX package, simulate download for compilation.
        downloadStates[modelID] = .error("MLX package not available. Add mlx-swift-lm to the project.")
        #endif
    }

    /// Cancel an in-progress download (best-effort).
    func cancelDownload(_ modelID: String) {
        if case .downloading = downloadStates[modelID] {
            downloadStates[modelID] = .notDownloaded
        }
    }

    /// Delete a downloaded model's cached files to reclaim disk space.
    func deleteModel(_ modelID: String) {
        // Remove from HF Hub cache if possible.
        // The HF Hub library stores models at:
        //   ~/Library/Caches/huggingface/hub/models--{org}--{model}/
        // where slashes in the model ID are replaced with "--".
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let cacheDir {
            let modelDir = cacheDir.appendingPathComponent("huggingface/hub/models--" + modelID.replacingOccurrences(of: "/", with: "--"))
            if FileManager.default.fileExists(atPath: modelDir.path) {
                do {
                    try FileManager.default.removeItem(at: modelDir)
                } catch {
                    print("⚠️ Failed to delete cached model at \(modelDir.path): \(error.localizedDescription)")
                }
            }
        }

        downloadStates[modelID] = .notDownloaded

        if activeModelID == modelID {
            activeModelID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
        }

        // Update persisted set.
        var downloaded = Set(UserDefaults.standard.stringArray(forKey: Self.downloadedModelsKey) ?? [])
        downloaded.remove(modelID)
        UserDefaults.standard.set(Array(downloaded), forKey: Self.downloadedModelsKey)
    }

    /// Set the active model for inference.
    func setActiveModel(_ modelID: String) {
        activeModelID = modelID
        UserDefaults.standard.set(modelID, forKey: Self.activeModelKey)
    }

    /// List of downloaded model IDs.
    var downloadedModelIDs: [String] {
        downloadStates
            .filter { $0.value == .downloaded }
            .map(\.key)
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        let downloaded = Set(UserDefaults.standard.stringArray(forKey: Self.downloadedModelsKey) ?? [])
        for id in downloaded {
            downloadStates[id] = .downloaded
        }
        activeModelID = UserDefaults.standard.string(forKey: Self.activeModelKey)
    }

    private func persistDownloadedModel(_ modelID: String) {
        var downloaded = Set(UserDefaults.standard.stringArray(forKey: Self.downloadedModelsKey) ?? [])
        downloaded.insert(modelID)
        UserDefaults.standard.set(Array(downloaded), forKey: Self.downloadedModelsKey)
    }
}
