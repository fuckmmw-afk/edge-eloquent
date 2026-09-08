// Sources/EdgeEloquent/Models/ModelManager.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation
import Combine

/// State of a model within the local application lifecycle.
public enum ModelState: Equatable, Hashable, Sendable {
    /// Model artifact is not downloaded locally.
    case notDownloaded

    /// Model artifact is currently downloading with progress fraction (0.0 ... 1.0).
    case downloading(progress: Double)

    /// Model weights are verified and ready for memory mapping on device.
    case ready

    /// Model weights are actively being initialized, memory-mapped, or compiled into Metal pipelines.
    case loading

    /// Model is fully loaded into unified memory and active for dictation inference.
    case active

    /// An error occurred during download, verification, loading, or inference.
    case error(String)

    /// Indicates whether the model artifact is downloaded and present on disk.
    public var isDownloaded: Bool {
        switch self {
        case .ready, .loading, .active:
            return true
        default:
            return false
        }
    }

    /// Indicates whether this model is currently the active inference model.
    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// Indicates whether the model is actively downloading.
    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// Current download progress fraction if downloading, else nil.
    public var downloadProgress: Double? {
        if case .downloading(let progress) = self {
            return progress
        }
        return nil
    }

    /// User-friendly status description.
    public var statusDescription: String {
        switch self {
        case .notDownloaded:
            return "Not Downloaded"
        case .downloading(let progress):
            let percent = Int((progress * 100).rounded())
            return "Downloading (\(percent)%)"
        case .ready:
            return "Ready"
        case .loading:
            return "Loading..."
        case .active:
            return "Active"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

/// Domain errors encountered during model management operations.
public enum ModelManagerError: LocalizedError, Equatable {
    case modelNotFound(String)
    case modelNotReady(String)
    case bundledWeightsDetected([String])
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case downloadFailed(String)
    case deletionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let id):
            return "Supported model with ID '\(id)' was not found."
        case .modelNotReady(let id):
            return "Model '\(id)' is not downloaded or ready. Please download it before activating."
        case .bundledWeightsDetected(let files):
            return "IPA Invariant Violated: Model weights detected bundled inside application bundle: \(files.joined(separator: ", ")). Model weights must NEVER be bundled in the IPA."
        case .insufficientDiskSpace(let required, let available):
            let reqStr = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Insufficient storage space: \(reqStr) required, but only \(availStr) available."
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .deletionFailed(let reason):
            return "Failed to delete model from disk: \(reason)"
        }
    }
}

/// Central model management coordinator for Edge Eloquent.
///
/// Responsibilities:
/// - Discovers supported models from `SupportedAudioModel.allModels`.
/// - Tracks per-model states: `.notDownloaded`, `.downloading`, `.ready`, `.loading`, `.active`, `.error`.
/// - Coordinates chunked resumable downloads with SHA-256 and size verification.
/// - Manages active model selection with persistence in `UserDefaults`.
/// - Monitors disk storage and model footprint to prevent storage overflow.
/// - Enables model deletion to reclaim flash memory.
/// - Strictly enforces the Zero-Bundled-Weights IPA Invariant.
@MainActor
public final class ModelManager: ObservableObject {

    // MARK: - Constants

    /// Key used for persisting active model selection in `UserDefaults`.
    public static let activeModelUserDefaultsKey = "com.edgeeloquent.activeModelId"

    /// Application Support subdirectory for Edge Eloquent model artifacts.
    public static let modelsSubdirectory = "EdgeEloquent/Models"

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

    /// Total disk capacity in bytes on the device storage volume.
    @Published public private(set) var totalDiskSpaceBytes: Int64 = 0

    /// Aggregate disk space in bytes occupied by all downloaded models.
    @Published public private(set) var totalModelsSizeOnDiskBytes: Int64 = 0

    /// Active download progress snapshots keyed by model ID.
    @Published public private(set) var downloadProgresses: [String: DownloadProgress] = [:]

    /// Most recent error message for user-facing alerts.
    @Published public private(set) var lastErrorMessage: String? = nil

    // MARK: - Dependencies

    /// Directory URL where model weights are stored.
    public let modelsDirectory: URL

    /// Downloader service handling chunked resumable transfers.
    public let downloader: ModelRepoDownloader

    /// Hugging Face Hub metadata and compatibility verification service.
    public let searchService: HuggingFaceSearchService

    /// User defaults instance for state persistence.
    private let userDefaults: UserDefaults

    /// File manager for local disk operations.
    private let fileManager: FileManager

    // MARK: - Initialization

    /// Initializes a new Model Manager instance.
    /// - Parameters:
    ///   - modelsDirectory: Directory for model storage (defaults to Application Support).
    ///   - downloader: Downloader instance for model weights.
    ///   - searchService: Hugging Face metadata service.
    ///   - userDefaults: UserDefaults instance for preference persistence.
    ///   - fileManager: FileManager instance for disk operations.
    public init(
        modelsDirectory: URL = ModelManager.defaultModelsDirectoryURL,
        downloader: ModelRepoDownloader? = nil,
        searchService: HuggingFaceSearchService? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.modelsDirectory = modelsDirectory
        self.fileManager = fileManager
        self.downloader = downloader ?? ModelRepoDownloader(fileManager: fileManager)
        self.searchService = searchService ?? HuggingFaceSearchService()
        self.userDefaults = userDefaults

        // Ensure models directory exists and is excluded from backup
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true, attributes: nil)
        try? ModelRepoDownloader.excludeFromBackup(url: modelsDirectory)

        // Initialize model states and restore persisted active model
        self.refreshModelStates()
        self.refreshDiskSpace()
    }

    // MARK: - Computed Properties

    /// The currently active model specification, if any.
    public var activeModel: SupportedAudioModel? {
        guard let id = activeModelId else { return nil }
        return supportedModels.first { $0.id == id }
    }

    /// Models that are fully downloaded and ready for use.
    public var downloadedModels: [SupportedAudioModel] {
        supportedModels.filter { model in
            let st = modelStates[model.id] ?? .notDownloaded
            return st.isDownloaded
        }
    }

    /// Whether any model is currently downloading.
    public var isAnyModelDownloading: Bool {
        modelStates.values.contains { $0.isDownloading }
    }

    /// Formatted available storage string (e.g. "45.2 GB").
    public var availableStorageFormatted: String {
        ByteCountFormatter.string(fromByteCount: availableDiskSpaceBytes, countStyle: .file)
    }

    /// Formatted total storage string (e.g. "128.0 GB").
    public var totalStorageFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalDiskSpaceBytes, countStyle: .file)
    }

    /// Formatted storage consumed by models on disk (e.g. "3.39 GB").
    public var totalModelsSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalModelsSizeOnDiskBytes, countStyle: .file)
    }

    /// Returns the lifecycle state for a specific model ID.
    public func state(for modelId: String) -> ModelState {
        modelStates[modelId] ?? .notDownloaded
    }

    // MARK: - Model State & File Management

    /// Refreshes the local states of all supported models by inspecting the disk.
    public func refreshModelStates() {
        let savedActiveId = userDefaults.string(forKey: Self.activeModelUserDefaultsKey)

        for model in supportedModels {
            let fileURL = modelFileURL(for: model)
            if fileManager.fileExists(atPath: fileURL.path) {
                let attrs = (try? fileManager.attributesOfItem(atPath: fileURL.path)) ?? [:]
                let size = (attrs[.size] as? Int64) ?? 0

                // If file size matches or exceeds expected size, mark ready or active
                if size >= model.expectedBytes {
                    if model.id == savedActiveId {
                        modelStates[model.id] = .active
                        activeModelId = model.id
                    } else {
                        modelStates[model.id] = .ready
                    }
                    continue
                }
            }

            // Check if there is an in-progress partial download
            if downloader.hasPartialDownload(for: model, in: modelsDirectory) {
                let tempURL = downloader.temporaryFileURL(for: model, in: modelsDirectory)
                let attrs = (try? fileManager.attributesOfItem(atPath: tempURL.path)) ?? [:]
                let size = (attrs[.size] as? Int64) ?? 0
                let progress = model.expectedBytes > 0 ? Double(size) / Double(model.expectedBytes) : 0
                modelStates[model.id] = .downloading(progress: progress)
            } else {
                modelStates[model.id] = .notDownloaded
            }
        }

        // If saved active model is apple-native-speech, preserve it
        if savedActiveId == "apple-native-speech" {
            activeModelId = "apple-native-speech"
        } else if activeModelId == nil {
            // If saved active model is not present, select first ready model or nil
            if let firstReady = supportedModels.first(where: { modelStates[$0.id] == .ready }) {
                modelStates[firstReady.id] = .active
                activeModelId = firstReady.id
                userDefaults.set(firstReady.id, forKey: Self.activeModelUserDefaultsKey)
            }
        }
    }

    /// Resolves the permanent file URL for a model artifact.
    public func modelFileURL(for model: SupportedAudioModel) -> URL {
        downloader.finalDestinationURL(for: model, in: modelsDirectory)
    }

    /// Returns the size in bytes occupied by a specific model on disk.
    public func modelSizeOnDisk(for modelId: String) -> Int64? {
        guard let model = supportedModels.first(where: { $0.id == modelId }) else { return nil }
        let modelDir = modelsDirectory
            .appendingPathComponent(model.sanitizedDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: modelDir.path) else { return nil }

        var totalSize: Int64 = 0
        guard let enumerator = fileManager.enumerator(at: modelDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize > 0 ? totalSize : nil
    }

    /// Formatted disk size occupied by a specific model.
    public func modelSizeFormatted(for modelId: String) -> String {
        guard let bytes = modelSizeOnDisk(for: modelId) else { return "0 MB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Disk Storage Tracking

    /// Queries the filesystem to refresh available and total disk capacity metrics.
    public func refreshDiskSpace() {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: modelsDirectory.path)
            if let free = attrs[.systemFreeSize] as? Int64 {
                self.availableDiskSpaceBytes = free
            }
            if let total = attrs[.systemSize] as? Int64 {
                self.totalDiskSpaceBytes = total
            }
        } catch {
            // Fallback to URL resource values
            if let values = try? modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
                self.availableDiskSpaceBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
                self.totalDiskSpaceBytes = Int64(values.volumeTotalCapacity ?? 0)
            }
        }

        // Calculate total size of all installed model artifacts
        var aggregateSize: Int64 = 0
        for model in supportedModels {
            if let size = modelSizeOnDisk(for: model.id) {
                aggregateSize += size
            }
        }
        self.totalModelsSizeOnDiskBytes = aggregateSize
    }

    // MARK: - Download Lifecycle Actions

    /// Downloads a supported model with progress tracking and validation.
    /// - Parameters:
    ///   - model: Model specification to download.
    ///   - bearerToken: Optional Hugging Face access token for gated models.
    public func downloadModel(
        _ model: SupportedAudioModel,
        bearerToken: String? = nil
    ) async throws {
        refreshDiskSpace()

        // Verify available disk space before starting
        guard availableDiskSpaceBytes >= model.expectedBytes else {
            let err = ModelManagerError.insufficientDiskSpace(
                requiredBytes: model.expectedBytes,
                availableBytes: availableDiskSpaceBytes
            )
            modelStates[model.id] = .error(err.localizedDescription)
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
                Task { @MainActor in
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

        guard let newModel = supportedModels.first(where: { $0.id == id }) else {
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

        // Activate new model
        modelStates[id] = .active
        activeModelId = id
        userDefaults.set(id, forKey: Self.activeModelUserDefaultsKey)
    }

    /// Simulates or executes model loading into unified memory.
    public func loadModel(id: String) async throws {
        guard let model = supportedModels.first(where: { $0.id == id }) else {
            throw ModelManagerError.modelNotFound(id)
        }
        let currentState = modelStates[id] ?? .notDownloaded
        guard currentState.isDownloaded else {
            throw ModelManagerError.modelNotReady(id)
        }

        modelStates[id] = .loading

        // Simulate initialization / pipeline compilation
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms yield

        try setActiveModel(id: model.id)
    }

    // MARK: - Model Deletion & Space Reclamation

    /// Deletes a model from local storage to reclaim disk space.
    /// - Parameter id: Model identifier to delete.
    public func deleteModel(id: String) throws {
        guard let model = supportedModels.first(where: { $0.id == id }) else {
            throw ModelManagerError.modelNotFound(id)
        }

        let modelDir = modelsDirectory.appendingPathComponent(model.sanitizedDirectoryName, isDirectory: true)

        if fileManager.fileExists(atPath: modelDir.path) {
            do {
                try fileManager.removeItem(at: modelDir)
            } catch {
                throw ModelManagerError.deletionFailed(error.localizedDescription)
            }
        }

        // If the deleted model was active, clear active selection
        if activeModelId == id {
            activeModelId = nil
            userDefaults.removeObject(forKey: Self.activeModelUserDefaultsKey)

            // Fall back to another ready model if available
            if let nextReady = supportedModels.first(where: { $0.id != id && modelStates[$0.id]?.isDownloaded == true }) {
                modelStates[nextReady.id] = .active
                activeModelId = nextReady.id
                userDefaults.set(nextReady.id, forKey: Self.activeModelUserDefaultsKey)
            }
        }

        modelStates[id] = .notDownloaded
        downloadProgresses.removeValue(forKey: id)
        refreshDiskSpace()
    }

    // MARK: - Strict Architectural Invariant: Zero Bundled Weights

    /// Asserts that no model weight artifacts (.litertlm, .safetensors, .bin, .gguf) are bundled
    /// inside the compiled application bundle.
    ///
    /// The IPA bundle must strictly contain compiled code, UI assets, and CLiteRTLM.xcframework,
    /// maintaining an app distribution footprint between 15 MB and 25 MB.
    public static func assertNoBundledWeights(bundle: Bundle = .main) throws {
        guard let resourcePath = bundle.resourcePath else { return }
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(atPath: resourcePath) else { return }
        var offendingFiles: [String] = []

        let forbiddenExtensions = [".litertlm", ".safetensors", ".bin", ".gguf", ".tflite"]

        while let item = enumerator.nextObject() as? String {
            let lower = item.lowercased()
            for ext in forbiddenExtensions {
                if lower.hasSuffix(ext) {
                    offendingFiles.append(item)
                    break
                }
            }
        }

        guard offendingFiles.isEmpty else {
            throw ModelManagerError.bundledWeightsDetected(offendingFiles)
        }
    }
}
