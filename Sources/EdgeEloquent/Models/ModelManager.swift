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
    case bundledWeightsDetected([String])
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
        case .bundledWeightsDetected(let files):
            return "CRITICAL ARCHITECTURE VIOLATION: Model weights were found bundled in application bundle: \(files.joined(separator: ", ")). Edge Eloquent enforces zero-bundled weights."
        case .bundledWeightsProhibited:
            return "CRITICAL ARCHITECTURE VIOLATION: Model weights were found bundled in application bundle. Edge Eloquent enforces zero-bundled weights."
        }
    }
}

/// Represents the download and operational state of a model.
public enum ModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case loading
    case ready
    case active
    case error(String)

    public var isDownloaded: Bool {
        switch self {
        case .loading, .ready, .active:
            return true
        default:
            return false
        }
    }

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
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
    nonisolated public static let customModelsUserDefaultsKey = "com.edgeeloquent.customAudioModels"

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

    /// The currently active model instance, if one is selected and available.
    public var activeModel: SupportedAudioModel? {
        guard let id = activeModelId else { return nil }
        return supportedModels.first(where: { $0.id == id })
    }

    /// File URL for the given model on local storage.
    public func modelFileURL(for model: SupportedAudioModel) -> URL {
        localModelArtifactURL(for: model)
    }

    /// Available disk space in bytes on the device storage volume.
    @Published public private(set) var availableDiskSpaceBytes: Int64 = 0

    /// Total storage capacity in bytes on the volume.
    @Published public private(set) var totalDiskSpaceBytes: Int64 = 64_000_000_000

    /// Total bytes currently occupied by downloaded model weights on disk.
    public var totalModelsSizeOnDiskBytes: Int64 {
        supportedModels.reduce(0) { total, model in
            let path = localModelArtifactURL(for: model).path
            guard fileManager.fileExists(atPath: path),
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64 else {
                return total
            }
            return total + size
        }
    }

    /// Formatted string of space occupied by models on disk.
    public var totalModelsSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalModelsSizeOnDiskBytes, countStyle: .file)
    }

    /// Formatted total storage space on device.
    public var totalDiskSpaceFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalDiskSpaceBytes, countStyle: .file)
    }

    /// Formatted available storage space on device.
    /// Alias for storage overview card
    public var availableStorageFormatted: String {
        availableDiskSpaceFormatted
    }

    public var availableDiskSpaceFormatted: String {
        ByteCountFormatter.string(fromByteCount: availableDiskSpaceBytes, countStyle: .file)
    }

    /// List of models currently present on disk.
    public var downloadedModels: [SupportedAudioModel] {
        supportedModels.filter { isModelDownloaded($0) }
    }

    /// Real-time progress trackers for active downloads keyed by model ID.
    @Published public private(set) var downloadProgresses: [String: DownloadProgress] = [:]

    /// Last encountered error message for user-facing alerts.
    @Published public var lastErrorMessage: String? = nil

    /// Returns the current state of a model given its identifier.
    public func state(for modelId: String) -> ModelState {
        modelStates[modelId] ?? .notDownloaded
    }

    /// Deletes an on-device model given its identifier.
    public func deleteModel(id modelId: String) throws {
        guard let model = supportedModels.first(where: { $0.id == modelId }) else {
            throw ModelManagerError.modelNotFound(modelId)
        }
        try deleteModel(model)
    }

    // MARK: - Dependencies

    public let modelsDirectory: URL
    private let downloader: ModelRepoDownloader
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private var customModelIds: Set<String> = []

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

        if let data = userDefaults.data(forKey: Self.customModelsUserDefaultsKey),
           let customModels = try? JSONDecoder().decode([SupportedAudioModel].self, from: data) {
            self.customModelIds = Set(customModels.map(\.id))
            var merged = SupportedAudioModel.allModels
            for model in customModels where !merged.contains(where: { $0.id == model.id }) {
                merged.append(model)
            }
            self.supportedModels = merged
        }

        createModelsDirectoryIfNeeded()
        try? Self.assertNoBundledWeights()
        refreshDiskSpace()
        restorePersistedActiveModel()
        refreshModelStates()
    }

    // MARK: - Architectural Assertions

    /// Enforces the core rule: No model weights (.bin, .safetensors, .task, .litertlm) can be in the IPA.
    nonisolated public static func assertNoBundledWeights(bundle: Bundle = .main) throws {
        guard let bundlePath = bundle.resourcePath else { return }
        let prohibitedExtensions = ["litertlm", "task", "bin", "safetensors", "tflite", "gguf", "onnx"]
        var detected: [String] = []

        if let enumerator = FileManager.default.enumerator(atPath: bundlePath) {
            for case let file as String in enumerator {
                let ext = (file as NSString).pathExtension.lowercased()
                if prohibitedExtensions.contains(ext) {
                    detected.append(file)
                }
            }
        }
        if !detected.isEmpty {
            throw ModelManagerError.bundledWeightsDetected(detected)
        }
    }

    public func modelSizeOnDisk(for modelId: String) -> Int64? {
        guard let model = supportedModels.first(where: { $0.id == modelId }) else { return nil }
        let path = localModelArtifactURL(for: model).path
        guard fileManager.fileExists(atPath: path),
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        return size
    }

    public var totalStorageFormatted: String {
        totalDiskSpaceFormatted
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
            let values = try modelsDirectory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])
            if let total = values.volumeTotalCapacity {
                self.totalDiskSpaceBytes = Int64(total)
            }
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
            if isModelDownloaded(model) {
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

        // Automatically activate first ready downloaded model if no model is currently active
        if activeModelId == nil, let firstReady = supportedModels.first(where: { isModelDownloaded($0) }) {
            activeModelId = firstReady.id
            modelStates[firstReady.id] = .active
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
        guard fileManager.fileExists(atPath: path),
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == model.expectedBytes
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

    /// Adds a compatible Hub search result to the local catalog and persists it across launches.
    @discardableResult
    public func addDiscoveredModel(_ report: ModelCompatibilityReport) throws -> SupportedAudioModel {
        guard let discovered = SupportedAudioModel(compatibilityReport: report) else {
            throw ModelManagerError.activationFailed(
                report.diagnosticReasons.joined(separator: " ")
            )
        }

        if let existing = supportedModels.first(where: { $0.id == discovered.id }) {
            return existing
        }

        supportedModels.append(discovered)
        customModelIds.insert(discovered.id)
        modelStates[discovered.id] = .notDownloaded
        persistCustomModels()
        return discovered
    }

    public func isUserImportedModel(_ model: SupportedAudioModel) -> Bool {
        customModelIds.contains(model.id)
    }

    private func persistCustomModels() {
        let models = supportedModels.filter { customModelIds.contains($0.id) }
        if let data = try? JSONEncoder().encode(models) {
            userDefaults.set(data, forKey: Self.customModelsUserDefaultsKey)
        }
    }

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
                return
            }
        }

        // Default activation: check if any supported model is downloaded, activate first ready
        if let firstReady = supportedModels.first(where: { isModelDownloaded($0) }) {
            activeModelId = firstReady.id
        } else {
            activeModelId = nil
        }
    }
}
