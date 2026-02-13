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
        MLXModelInfo(
            id: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen 3 4B",
            summary: "Great all-rounder with strong reasoning and instruction following.",
            downloadSizeBytes: 2_400_000_000,
            minRAMGB: 4,
            parameterCount: "4B",
            quantization: "4-bit"
        ),
        MLXModelInfo(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B",
            summary: "Meta's compact model. Fast and good at following instructions.",
            downloadSizeBytes: 1_800_000_000,
            minRAMGB: 3,
            parameterCount: "3B",
            quantization: "4-bit"
        ),
        MLXModelInfo(
            id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            displayName: "Mistral 7B v0.3",
            summary: "Strong reasoning and coding. Needs more RAM.",
            downloadSizeBytes: 4_100_000_000,
            minRAMGB: 6,
            parameterCount: "7B",
            quantization: "4-bit"
        ),
        MLXModelInfo(
            id: "mlx-community/Phi-4-mini-instruct-4bit",
            displayName: "Phi-4 Mini",
            summary: "Microsoft's compact model. Great reasoning per parameter.",
            downloadSizeBytes: 2_200_000_000,
            minRAMGB: 4,
            parameterCount: "3.8B",
            quantization: "4-bit"
        ),
        MLXModelInfo(
            id: "mlx-community/gemma-3-4b-it-4bit",
            displayName: "Gemma 3 4B",
            summary: "Google's multilingual model. Good for diverse tasks.",
            downloadSizeBytes: 2_500_000_000,
            minRAMGB: 4,
            parameterCount: "4B",
            quantization: "4-bit"
        )
    ]

    // MARK: - Platform check

    /// Minimum RAM required for MLX inference (8 GB).
    private static let minimumRAMBytes: UInt64 = 8_000_000_000

    /// Whether the current device supports MLX inference.
    /// Supported on: macOS with Apple Silicon, iPadOS on M-series iPads with 8GB+ RAM.
    /// Not supported on: iPhones (insufficient memory headroom).
    nonisolated static var isSupported: Bool {
        #if arch(arm64)
        #if os(macOS)
        // All Apple Silicon Macs are supported
        return true
        #elseif os(iOS)
        // Only support iPads with M-series chips (8GB+ RAM)
        // iPhones are excluded even if they have enough RAM due to aggressive memory limits
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let hasEnoughRAM = ProcessInfo.processInfo.physicalMemory >= minimumRAMBytes
        return isIPad && hasEnoughRAM
        #else
        return false
        #endif
        #else
        return false
        #endif
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
