// Sources/EdgeEloquent/Models/ModelManager.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation
import Combine

/// Errors thrown by the ModelManager during lifecycle operations.
public enum ModelManagerError: LocalizedError, Equatable {
    case modelNotFound(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case modelNotReady(String)
    case activationFailed(String)
    case bundledWeightsProhibited

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let id):
            return "Supported audio model '\(id)' was not found in the verified catalog."
        case .insufficientDiskSpace(let required, let available):
            let reqStr = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Insufficient storage: \(reqStr) required, but only \(availStr) available."
        case .modelNotReady(let id):
            return "Model '\(id)' is not downloaded or ready for activation."
        case .activationFailed(let reason):
            return "Failed to activate model: \(reason)"
        case .bundledWeightsProhibited:
            return "CRITICAL ARCHITECTURE VIOLATION: Model weights were found bundled in application bundle. Edge Eloquent enforces zero-bundled weights."
        }
    }
}

/// Represents the download and operational state of a model.
public enum ModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case active
    case error(String)

    public var isDownloaded: Bool {
        switch self {
        case .ready, .active:
            return true
        default:
            return false
        }
    }

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Multi-model orchestrator for Edge Eloquent.
///
/// Responsible for:
/// 1. Enumerating supported audio-capable models (Gemma 4 E2B, Gemma 3n E2B, Gemma 3n E4B).
/// 2. Tracking downloaded weights on disk inside `Application Support/EdgeEloquent/Models/`.
/// 3. Initiating, pausing, resuming, and cancelling chunked downloads from Hugging Face Hub.
/// 4. Managing the currently active model for inference without hardcoding any single model.
/// 5. Strictly enforcing the zero-bundled-weights architectural invariant.
@MainActor
public final class ModelManager: ObservableObject {

    // MARK: - Constants

    /// Key used for persisting active model selection in `UserDefaults`.
    nonisolated public static let activeModelUserDefaultsKey = "com.edgeeloquent.activeModelId"

    /// Application Support subdirectory for Edge Eloquent model artifacts.
    nonisolated public static let modelsSubdirectory = "EdgeEloquent/Models"

    /// Default directory URL in Application Support for storing downloaded model weights.
    nonisolated public static var defaultModelsDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(modelsSubdirectory, isDirectory: true)
    }

    // MARK: - Published State

    /// The list of supported audio models compatible with the speech dictation pipeline.
    @Published public private(set) var supportedModels: [SupportedAudioModel] = SupportedAudioModel.allModels

    /// Current lifecycle state for each supported model keyed by model ID.
    @Published public private(set) var modelStates: [String: ModelState] = [:]

    /// The ID of the currently active model for transcription.
    @Published public private(set) var activeModelId: String? = nil

    /// Available disk space in bytes on the device storage volume.
    @Published public private(set) var availableDiskSpaceBytes: Int64 = 0

    /// Real-time progress trackers for active downloads keyed by model ID.
    @Published public private(set) var downloadProgresses: [String: Progress] = [:]

    /// Last encountered error message for user-facing alerts.
    @Published public var lastErrorMessage: String? = nil

    // MARK: - Dependencies

    public let modelsDirectory: URL
    private let downloader: ModelRepoDownloader
    private let fileManager: FileManager
    private let userDefaults: UserDefaults

    // MARK: - Initialization

    /// Initializes the ModelManager.
    /// - Parameters:
    ///   - modelsDirectory: Target directory for storing `.litertlm` files.
    ///   - downloader: Downloader handling chunked range requests.
    ///   - fileManager: FileManager instance for disk queries.
    ///   - userDefaults: UserDefaults for persisting user selection.
    public init(
        modelsDirectory: URL = ModelManager.defaultModelsDirectoryURL,
        downloader: ModelRepoDownloader = ModelRepoDownloader(),
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.modelsDirectory = modelsDirectory
        self.downloader = downloader
        self.fileManager = fileManager
        self.userDefaults = userDefaults

        createModelsDirectoryIfNeeded()
        assertNoBundledWeights()
        refreshDiskSpace()
        refreshModelStates()
        restorePersistedActiveModel()
    }

    // MARK: - Architectural Assertions

    /// Enforces the core rule: No model weights (.bin, .safetensors, .task, .litertlm) can be in the IPA.
    private func assertNoBundledWeights() {
        guard let bundlePath = Bundle.main.resourcePath else { return }
        let prohibitedExtensions = ["litertlm", "task", "bin", "safetensors", "tflite"]

        if let enumerator = fileManager.enumerator(atPath: bundlePath) {
            for case let file as String in enumerator {
                let ext = (file as NSString).pathExtension.lowercased()
                if prohibitedExtensions.contains(ext) {
                    fatalError("[CRITICAL] Bundled model weights found at: \(file). Zero-bundled weights rule violated!")
                }
            }
        }
    }

    private func createModelsDirectoryIfNeeded() {
        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            // Exclude from iCloud / iTunes backup as per App Store Guidelines for large downloadable assets
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var dirURL = modelsDirectory
            try dirURL.setResourceValues(resourceValues)
        } catch {
            print("[ModelManager] Failed to create or configure models directory: \(error)")
        }
    }

    // MARK: - Disk & State Queries

    /// Refreshes the available free disk space on the volume holding the models directory.
    public func refreshDiskSpace() {
        do {
            let values = try modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                self.availableDiskSpaceBytes = capacity
            } else {
                let fsAttrs = try fileManager.attributesOfFileSystem(forPath: modelsDirectory.path)
                if let free = fsAttrs[.systemFreeSize] as? Int64 {
                    self.availableDiskSpaceBytes = free
                }
            }
        } catch {
            // Fallback estimation
            self.availableDiskSpaceBytes = 10_000_000_000 // 10 GB default assumed
        }
    }

    /// Scans the models directory and updates `modelStates` according to file existence and integrity.
    public func refreshModelStates() {
        for model in supportedModels {
            let targetPath = localModelArtifactURL(for: model)
            if fileManager.fileExists(atPath: targetPath.path) {
                if activeModelId == model.id {
                    modelStates[model.id] = .active
                } else {
                    modelStates[model.id] = .ready
                }
            } else {
                // If previously active but deleted from disk, clear active state
                if activeModelId == model.id {
                    activeModelId = nil
                }
                modelStates[model.id] = .notDownloaded
            }
        }

        // Apple Native Speech fallback handling
        if activeModelId == "apple-native-speech" {
            modelStates["apple-native-speech"] = .active
        } else {
            modelStates["apple-native-speech"] = .ready
        }
    }

    /// Checks if a model's weights file exists locally on disk.
    public func isModelDownloaded(_ model: SupportedAudioModel) -> Bool {
        let path = localModelArtifactURL(for: model).path
        return fileManager.fileExists(atPath: path)
    }

    /// Returns the local destination URL for a given model's `.litertlm` artifact.
    public func localModelArtifactURL(for model: SupportedAudioModel) -> URL {
        modelsDirectory
            .appendingPathComponent(model.sanitizedDirectoryName, isDirectory: true)
            .appendingPathComponent(model.commitHash, isDirectory: true)
            .appendingPathComponent(model.filename)
    }

    /// Returns the local destination URL for a model by ID.
    public func localArtifactURL(forModelId id: String) -> URL? {
        guard let model = supportedModels.first(where: { $0.id == id }) else { return nil }
        return localModelArtifactURL(for: model)
    }

    /// Checks if the device has enough free storage to download the specified model.
    public func hasSufficientStorage(for model: SupportedAudioModel) -> Bool {
        refreshDiskSpace()
        // Require expected size + 500 MB safety headroom
        let required = model.expectedBytes + 500_000_000
        return availableDiskSpaceBytes >= required
    }

    // MARK: - Download Orchestration

    /// Starts downloading a model from Hugging Face Hub using chunked, resumable range requests.
    /// - Parameters:
    ///   - model: SupportedAudioModel specification to download.
    ///   - bearerToken: Optional Hugging Face User Access Token for gated models.
    public func downloadModel(
        _ model: SupportedAudioModel,
        bearerToken: String? = nil
    ) async throws {
        guard hasSufficientStorage(for: model) else {
            let err = ModelManagerError.insufficientDiskSpace(
                requiredBytes: model.expectedBytes,
                availableBytes: availableDiskSpaceBytes
            )
            lastErrorMessage = err.localizedDescription
            throw err
        }

        modelStates[model.id] = .downloading(progress: 0.0)
        lastErrorMessage = nil

        do {
            _ = try await downloader.startDownload(
                model: model,
                destinationDirectory: modelsDirectory,
                bearerToken: bearerToken
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgresses[model.id] = progress
                    self?.modelStates[model.id] = .downloading(progress: progress.fractionCompleted)
                }
            }

            downloadProgresses.removeValue(forKey: model.id)
            modelStates[model.id] = .ready
            refreshDiskSpace()

            // If no model is currently active, activate the newly downloaded model
            if activeModelId == nil {
                try setActiveModel(id: model.id)
            }
        } catch {
            if (error as? DownloaderError) == .cancelled {
                // Paused or intentionally cancelled
                refreshModelStates()
            } else {
                let errString = error.localizedDescription
                modelStates[model.id] = .error(errString)
                lastErrorMessage = errString
                throw error
            }
        }
    }

    /// Pauses an ongoing model download.
    public func pauseDownload(modelId: String) {
        downloader.pauseDownload(modelId: modelId)
        if case .downloading(let progress) = modelStates[modelId] {
            // Keep the progress fraction recorded
            modelStates[modelId] = .downloading(progress: progress)
        }
    }

    /// Resumes a paused model download.
    public func resumeDownload(
        modelId: String,
        bearerToken: String? = nil
    ) async throws {
        guard let model = supportedModels.first(where: { $0.id == modelId }) else {
            throw ModelManagerError.modelNotFound(modelId)
        }
        try await downloadModel(model, bearerToken: bearerToken)
    }

    /// Cancels an active download and discards partial artifacts.
    public func cancelDownload(modelId: String) {
        downloader.cancelDownload(modelId: modelId)
        downloadProgresses.removeValue(forKey: modelId)
        modelStates[modelId] = .notDownloaded
        refreshDiskSpace()
    }

    // MARK: - Active Model Selection & Lifecycle

    /// Selects and activates a downloaded model or Apple Native Speech for dictation inference.
    /// - Parameter id: Supported model identifier or "apple-native-speech".
    public func setActiveModel(id: String) throws {
        if id == "apple-native-speech" {
            if let previousId = activeModelId, previousId != id {
                if modelStates[previousId]?.isDownloaded == true {
                    modelStates[previousId] = .ready
                }
            }
            activeModelId = id
            userDefaults.set(id, forKey: Self.activeModelUserDefaultsKey)
            return
        }

        guard supportedModels.contains(where: { $0.id == id }) else {
            throw ModelManagerError.modelNotFound(id)
        }

        let currentState = modelStates[id] ?? .notDownloaded
        guard currentState.isDownloaded else {
            throw ModelManagerError.modelNotReady(id)
        }

        // Deactivate previous active model
        if let previousId = activeModelId, previousId != id {
            if modelStates[previousId]?.isDownloaded == true {
                modelStates[previousId] = .ready
            }
        }

        activeModelId = id
        modelStates[id] = .active
        userDefaults.set(id, forKey: Self.activeModelUserDefaultsKey)
    }

    /// Deletes a downloaded model artifact from local storage to free up space.
    public func deleteModel(_ model: SupportedAudioModel) throws {
        let modelDir = modelsDirectory
            .appendingPathComponent(model.sanitizedDirectoryName, isDirectory: true)

        if fileManager.fileExists(atPath: modelDir.path) {
            try fileManager.removeItem(at: modelDir)
        }

        if activeModelId == model.id {
            activeModelId = nil
            userDefaults.removeObject(forKey: Self.activeModelUserDefaultsKey)
        }

        modelStates[model.id] = .notDownloaded
        refreshDiskSpace()
    }

    // MARK: - Persistence & Restoration

    private func restorePersistedActiveModel() {
        if let savedId = userDefaults.string(forKey: Self.activeModelUserDefaultsKey) {
            if savedId == "apple-native-speech" {
                activeModelId = savedId
                return
            }
            if let model = supportedModels.first(where: { $0.id == savedId }), isModelDownloaded(model) {
                activeModelId = savedId
                modelStates[savedId] = .active
                return
            }
        }

        // Default activation: check if default model is downloaded, or fall back to Apple Native Speech
        if isModelDownloaded(SupportedAudioModel.defaultModel) {
            try? setActiveModel(id: SupportedAudioModel.defaultModel.id)
        } else {
            // Instant out-of-the-box fallback without requiring downloads
            activeModelId = "apple-native-speech"
        }
    }
}
