// Sources/EdgeEloquent/Models/ModelRepoDownloader.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation
import CryptoKit

/// Represents real-time download progress for a model artifact.
public struct DownloadProgress: Equatable, Sendable {
    /// Progress fraction between 0.0 and 1.0.
    public let fractionCompleted: Double

    /// Number of bytes successfully downloaded and written to disk so far.
    public let bytesWritten: Int64

    /// Total expected size of the model file in bytes.
    public let totalBytes: Int64

    /// Estimated download speed in bytes per second.
    public let speedBytesPerSecond: Double

    /// Initializes a new download progress snapshot.
    public init(
        fractionCompleted: Double,
        bytesWritten: Int64,
        totalBytes: Int64,
        speedBytesPerSecond: Double = 0
    ) {
        self.fractionCompleted = fractionCompleted
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
    }

    /// Formatted speed string (e.g. "25.4 MB/s").
    public var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(speedBytesPerSecond)))/s"
    }

    /// Formatted transferred bytes string (e.g. "1.20 GB / 2.59 GB").
    public var formattedBytesTransfer: String {
        let written = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(written) / \(total)"
    }
}

/// Errors produced during model download, validation, or persistence operations.
public enum DownloaderError: LocalizedError, Equatable {
    case invalidResponse(statusCode: Int, message: String)
    case authenticationRequired(statusCode: Int)
    case cancelled
    case fileSizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case fileSystemError(String)
    case destinationUnavailable(String)
    case downloadAlreadyInProgress(String)
    case noActiveDownloadToPause(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let code, let msg):
            return "Hugging Face download failed with HTTP status \(code): \(msg)"
        case .authenticationRequired(let code):
            return "Access denied (HTTP \(code)). This Gemma model requires a Hugging Face User Access Token."
        case .cancelled:
            return "Model download was paused or cancelled."
        case .fileSizeMismatch(let expected, let actual):
            return "File size validation failed: expected \(expected) bytes but received \(actual) bytes."
        case .checksumMismatch(let expected, let actual):
            return "Integrity check failed: expected SHA-256 \(expected) but computed \(actual)."
        case .fileSystemError(let detail):
            return "Filesystem error: \(detail)"
        case .destinationUnavailable(let detail):
            return "Destination path is unavailable: \(detail)"
        case .downloadAlreadyInProgress(let id):
            return "Download for model \(id) is already in progress."
        case .noActiveDownloadToPause(let id):
            return "No active download found for model \(id) to pause."
        }
    }
}

/// Production downloader implementing chunked HTTP Range resumable downloads with
/// validation (file size, SHA-256) and atomic persistence in Application Support.
///
/// Complies with:
/// - iOS Jetsam memory budgets via low-footprint 1 MB buffer streaming.
/// - Byte-range resumption via `Range: bytes=N-` and `Accept-Encoding: identity`.
/// - Atomic move from temporary `.downloadtmp` files to prevent partial file corruption.
/// - `isExcludedFromBackup = true` to satisfy Apple App Store Guideline 2.2.
public final class ModelRepoDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    // MARK: - Internal Download Context

    private final class DownloadTaskContext: @unchecked Sendable {
        let model: SupportedAudioModel
        let destinationDirectory: URL
        let temporaryFileURL: URL
        let destinationFileURL: URL
        var dataTask: URLSessionDataTask?
        var fileHandle: FileHandle?
        var bytesWritten: Int64 = 0
        var totalBytesExpected: Int64
        var isPaused: Bool = false
        var isCancelled: Bool = false
        let progressHandler: (@Sendable (DownloadProgress) -> Void)?
        var continuation: CheckedContinuation<URL, Error>?
        var lastSpeedTime: Date = Date()
        var lastBytesCount: Int64 = 0
        var currentSpeed: Double = 0

        init(
            model: SupportedAudioModel,
            destinationDirectory: URL,
            temporaryFileURL: URL,
            destinationFileURL: URL,
            totalBytesExpected: Int64,
            progressHandler: (@Sendable (DownloadProgress) -> Void)?,
            continuation: CheckedContinuation<URL, Error>?
        ) {
            self.model = model
            self.destinationDirectory = destinationDirectory
            self.temporaryFileURL = temporaryFileURL
            self.destinationFileURL = destinationFileURL
            self.totalBytesExpected = totalBytesExpected
            self.progressHandler = progressHandler
            self.continuation = continuation
        }
    }

    // MARK: - Properties

    private let sessionConfiguration: URLSessionConfiguration
    private var session: URLSession!
    private let fileManager: FileManager
    private let lock = NSLock()
    private var activeDownloads: [String: DownloadTaskContext] = [:]
    private var taskLookup: [Int: String] = [:]

    // MARK: - Initialization & Deinitialization

    /// Initializes a new model repository downloader.
    /// - Parameters:
    ///   - sessionConfiguration: Custom configuration if needed (e.g. background or ephemeral for tests).
    ///   - fileManager: FileManager instance for disk operations.
    public init(
        sessionConfiguration: URLSessionConfiguration = .default,
        fileManager: FileManager = .default
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.fileManager = fileManager
        super.init()

        // Disable automatic gzip expansion for chunked Range requests
        sessionConfiguration.httpAdditionalHeaders = [
            "Accept-Encoding": "identity"
        ]
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: nil
        )
    }

    deinit {
        session?.invalidateAndCancel()
    }

    /// Explicitly tears down URLSession and cancels all active downloads to prevent retain cycles.
    public func invalidate() {
        session?.invalidateAndCancel()
    }

    // MARK: - Path Resolution Helpers

    /// Computes the temporary download file URL for a model.
    public func temporaryFileURL(for model: SupportedAudioModel, in destinationDirectory: URL) -> URL {
        destinationDirectory
            .appendingPathComponent(model.sanitizedDirectoryName, isDirectory: true)
            .appendingPathComponent(model.commitHash, isDirectory: true)
            .appendingPathComponent("\(model.filename).downloadtmp")
    }

    /// Computes the final permanent destination file URL for a model.
    public func finalDestinationURL(for model: SupportedAudioModel, in destinationDirectory: URL) -> URL {
        destinationDirectory
            .appendingPathComponent(model.sanitizedDirectoryName, isDirectory: true)
            .appendingPathComponent(model.commitHash, isDirectory: true)
            .appendingPathComponent(model.filename)
    }

    // MARK: - Download Lifecycle API

    /// Starts or resumes downloading a model artifact from Hugging Face.
    /// - Parameters:
    ///   - model: The supported model specification to download.
    ///   - destinationDirectory: Base directory for storing models (e.g. Application Support/EdgeEloquent/Models).
    ///   - bearerToken: Optional Hugging Face API user access token for gated models.
    ///   - progressHandler: Optional real-time progress closure.
    /// - Returns: File URL pointing to the atomically verified model artifact on disk.
    public func startDownload(
        model: SupportedAudioModel,
        destinationDirectory: URL,
        bearerToken: String? = nil,
        progressHandler: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        let tempURL = temporaryFileURL(for: model, in: destinationDirectory)
        let finalURL = finalDestinationURL(for: model, in: destinationDirectory)

        // Ensure parent directory hierarchy exists
        let parentDir = tempURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        try Self.excludeFromBackup(url: parentDir)

        // Recover a fully transferred temporary file left behind if the process ended
        // between the last network callback and the atomic move.
        if fileManager.fileExists(atPath: tempURL.path) {
            let size = ((try? fileManager.attributesOfItem(atPath: tempURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            if size == model.expectedBytes {
                try Self.validateChecksum(fileURL: tempURL, expectedChecksum: model.expectedSHA256)
                try Self.atomicMove(from: tempURL, to: finalURL, fileManager: fileManager)
                return finalURL
            }
            if size > model.expectedBytes {
                try fileManager.removeItem(at: tempURL)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if activeDownloads[model.id] != nil {
                lock.unlock()
                continuation.resume(throwing: DownloaderError.downloadAlreadyInProgress(model.id))
                return
            }

            // Determine existing downloaded bytes for HTTP Range resumption
            let existingBytes: Int64
            if fileManager.fileExists(atPath: tempURL.path) {
                let attrs = (try? fileManager.attributesOfItem(atPath: tempURL.path)) ?? [:]
                existingBytes = (attrs[.size] as? Int64) ?? 0
            } else {
                existingBytes = 0
            }

            let context = DownloadTaskContext(
                model: model,
                destinationDirectory: destinationDirectory,
                temporaryFileURL: tempURL,
                destinationFileURL: finalURL,
                totalBytesExpected: model.expectedBytes,
                progressHandler: progressHandler,
                continuation: continuation
            )
            context.bytesWritten = existingBytes
            activeDownloads[model.id] = context

            // Construct streaming HTTP GET request with Range header
            var request = URLRequest(url: model.downloadURL)
            request.httpMethod = "GET"
            request.setValue("AIEdgeGallery/1.0 (iOS) EdgeEloquent/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            if let token = bearerToken, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            if existingBytes > 0 {
                request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
            }

            let task = session.dataTask(with: request)
            context.dataTask = task
            taskLookup[task.taskIdentifier] = model.id
            lock.unlock()

            // Initial progress notification
            if existingBytes > 0 {
                let initialFraction = Double(existingBytes) / Double(model.expectedBytes)
                progressHandler?(DownloadProgress(
                    fractionCompleted: min(1.0, initialFraction),
                    bytesWritten: existingBytes,
                    totalBytes: model.expectedBytes,
                    speedBytesPerSecond: 0
                ))
            }

            task.resume()
        }
    }

    /// Pauses an active download, keeping the partial `.downloadtmp` file intact for future resumption.
    /// - Parameter modelId: Model identifier to pause.
    public func pauseDownload(modelId: String) {
        lock.lock()
        guard let context = activeDownloads[modelId] else {
            lock.unlock()
            return
        }
        context.isPaused = true
        let task = context.dataTask
        lock.unlock()

        task?.cancel()
    }

    /// Resumes a paused or interrupted download.
    public func resumeDownload(
        model: SupportedAudioModel,
        destinationDirectory: URL,
        bearerToken: String? = nil,
        progressHandler: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        try await startDownload(
            model: model,
            destinationDirectory: destinationDirectory,
            bearerToken: bearerToken,
            progressHandler: progressHandler
        )
    }

    /// Cancels an active download and deletes the partial temporary file to free storage.
    /// - Parameter modelId: Model identifier to cancel.
    public func cancelDownload(modelId: String) {
        lock.lock()
        guard let context = activeDownloads.removeValue(forKey: modelId) else {
            lock.unlock()
            return
        }
        if let taskId = context.dataTask?.taskIdentifier {
            taskLookup.removeValue(forKey: taskId)
        }
        context.isCancelled = true
        let task = context.dataTask
        let tempURL = context.temporaryFileURL
        let cont = context.continuation
        context.continuation = nil
        lock.unlock()

        task?.cancel()
        try? context.fileHandle?.close()
        try? fileManager.removeItem(at: tempURL)
        cont?.resume(throwing: DownloaderError.cancelled)
    }

    /// Checks if a model download is currently running.
    public func isDownloading(modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let context = activeDownloads[modelId] else { return false }
        return !context.isPaused && !context.isCancelled
    }

    /// Checks if a download has a paused partial file on disk.
    public func hasPartialDownload(for model: SupportedAudioModel, in destinationDirectory: URL) -> Bool {
        let tempURL = temporaryFileURL(for: model, in: destinationDirectory)
        guard fileManager.fileExists(atPath: tempURL.path) else { return false }
        let size = (try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        return size > 0 && size < model.expectedBytes
    }

    // MARK: - Validation & Persistence Utilities

    /// Computes the streaming SHA-256 checksum of a file without loading it entirely into memory.
    public static func computeSHA256(for fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1 MB streaming buffer
        while autoreleasepool(invoking: {
            let chunk = fileHandle.readData(ofLength: bufferSize)
            if !chunk.isEmpty {
                hasher.update(data: chunk)
                return true
            }
            return false
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates that a downloaded file matches the expected byte size.
    public static func validateFileSize(
        fileURL: URL,
        expectedBytes: Int64,
        toleranceRatio: Double = 0.05,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw DownloaderError.fileSystemError("File does not exist at \(fileURL.path)")
        }
        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        let actualBytes = (attrs[.size] as? Int64) ?? 0

        // Exact match
        if actualBytes == expectedBytes {
            return
        }

        // Optional tolerance is retained for callers validating unpinned artifacts. Production
        // downloads pass zero because every supported revision is pinned by size and checksum.
        if expectedBytes > 500_000_000 && toleranceRatio > 0 {
            let diff = abs(actualBytes - expectedBytes)
            let maxAllowedDiff = Int64(Double(expectedBytes) * toleranceRatio)
            if diff <= maxAllowedDiff {
                return
            }
        }

        throw DownloaderError.fileSizeMismatch(expected: expectedBytes, actual: actualBytes)
    }

    /// Validates that a downloaded file matches an expected SHA-256 checksum.
    public static func validateChecksum(fileURL: URL, expectedChecksum: String) throws {
        let actual = try computeSHA256(for: fileURL)
        guard actual.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
            throw DownloaderError.checksumMismatch(expected: expectedChecksum, actual: actual)
        }
    }

    /// Atomically moves a validated temporary file to its permanent destination URL.
    public static func atomicMove(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(atPath: parentDir.path, withIntermediateDirectories: true, attributes: nil)
        }
        try excludeFromBackup(url: parentDir)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)
            try excludeFromBackup(url: destinationURL)
            return
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        try excludeFromBackup(url: destinationURL)
    }

    /// Sets `isExcludedFromBackup = true` on the specified filesystem URL.
    public static func excludeFromBackup(url: URL) throws {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableURL.setResourceValues(resourceValues)
    }

    // MARK: - URLSessionDataDelegate Implementation

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard let modelId = taskLookup[dataTask.taskIdentifier],
              let context = activeDownloads[modelId] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }

        let statusCode = httpResponse.statusCode

        // Check authentication requirements for gated models
        if statusCode == 401 || statusCode == 403 {
            let cont = context.continuation
            context.continuation = nil
            lock.unlock()
            completionHandler(.cancel)
            cont?.resume(throwing: DownloaderError.authenticationRequired(statusCode: statusCode))
            cleanupTask(modelId: modelId)
            return
        }

        // Validate HTTP success codes (200 OK or 206 Partial Content)
        guard statusCode == 200 || statusCode == 206 else {
            let cont = context.continuation
            context.continuation = nil
            lock.unlock()
            completionHandler(.cancel)
            let msg = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            cont?.resume(throwing: DownloaderError.invalidResponse(statusCode: statusCode, message: msg))
            cleanupTask(modelId: modelId)
            return
        }

        do {
            if statusCode == 200 {
                // Fresh download: truncate or recreate temp file
                if fileManager.fileExists(atPath: context.temporaryFileURL.path) {
                    try fileManager.removeItem(at: context.temporaryFileURL)
                }
                guard fileManager.createFile(atPath: context.temporaryFileURL.path, contents: nil, attributes: nil) else {
                    throw DownloaderError.fileSystemError("Unable to create temporary download file")
                }
                context.bytesWritten = 0
                context.totalBytesExpected = context.model.expectedBytes
                let fh = try FileHandle(forWritingTo: context.temporaryFileURL)
                context.fileHandle = fh
            } else if statusCode == 206 {
                // Resumed download: open existing file and seek to end
                let expectedPrefix = "bytes \(context.bytesWritten)-"
                guard let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range")?.lowercased(),
                      contentRange.hasPrefix(expectedPrefix) else {
                    throw DownloaderError.invalidResponse(statusCode: statusCode, message: "Invalid Content-Range for resumed download")
                }
                context.totalBytesExpected = context.model.expectedBytes
                let fh = try FileHandle(forWritingTo: context.temporaryFileURL)
                try fh.seekToEnd()
                context.fileHandle = fh
            }
            context.lastSpeedTime = Date()
            context.lastBytesCount = context.bytesWritten
            lock.unlock()
            completionHandler(.allow)
        } catch {
            let cont = context.continuation
            context.continuation = nil
            lock.unlock()
            completionHandler(.cancel)
            cont?.resume(throwing: DownloaderError.fileSystemError(error.localizedDescription))
            cleanupTask(modelId: modelId)
        }
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard let modelId = taskLookup[dataTask.taskIdentifier],
              let context = activeDownloads[modelId],
              let handle = context.fileHandle else {
            lock.unlock()
            return
        }

        do {
            try handle.write(contentsOf: data)
            context.bytesWritten += Int64(data.count)

            // Speed estimation
            let now = Date()
            let timeDelta = now.timeIntervalSince(context.lastSpeedTime)
            if timeDelta >= 0.5 {
                let bytesDelta = context.bytesWritten - context.lastBytesCount
                context.currentSpeed = Double(bytesDelta) / timeDelta
                context.lastSpeedTime = now
                context.lastBytesCount = context.bytesWritten
            }

            let total = context.totalBytesExpected
            let fraction = total > 0 ? min(1.0, max(0.0, Double(context.bytesWritten) / Double(total))) : 0.0
            let progress = DownloadProgress(
                fractionCompleted: fraction,
                bytesWritten: context.bytesWritten,
                totalBytes: total,
                speedBytesPerSecond: context.currentSpeed
            )
            let handler = context.progressHandler
            lock.unlock()

            handler?(progress)
        } catch {
            let cont = context.continuation
            context.continuation = nil
            lock.unlock()
            cont?.resume(throwing: DownloaderError.fileSystemError(error.localizedDescription))
            cleanupTask(modelId: modelId)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard let modelId = taskLookup[task.taskIdentifier],
              let context = activeDownloads[modelId] else {
            lock.unlock()
            return
        }
        let cont = context.continuation
        context.continuation = nil
        lock.unlock()

        // Close open file handle
        try? context.fileHandle?.close()

        if let error = error {
            if context.isPaused {
                cont?.resume(throwing: DownloaderError.cancelled)
            } else if (error as NSError).code == NSURLErrorCancelled {
                cont?.resume(throwing: DownloaderError.cancelled)
            } else {
                cont?.resume(throwing: error)
            }
            cleanupTask(modelId: modelId)
            return
        }

        // Completion without error: validate integrity and commit atomically
        do {
            // Flush any buffered writes to disk
            try? context.fileHandle?.synchronize()

            // 1. Validate file size against totalBytesExpected (or model.expectedBytes as baseline)
            try Self.validateFileSize(
                fileURL: context.temporaryFileURL,
                expectedBytes: context.model.expectedBytes,
                toleranceRatio: 0,
                fileManager: fileManager
            )

            // 2. Validate checksum if present
            if let expectedSHA = context.model.expectedSHA256 {
                try Self.validateChecksum(fileURL: context.temporaryFileURL, expectedChecksum: expectedSHA)
            }

            // 3. Atomically move temporary file to final destination
            try Self.atomicMove(
                from: context.temporaryFileURL,
                to: context.destinationFileURL,
                fileManager: fileManager
            )

            // 4. Emit final 100% progress
            let finalBytes = (try? fileManager.attributesOfItem(atPath: context.destinationFileURL.path)[.size] as? Int64) ?? context.bytesWritten
            context.progressHandler?(DownloadProgress(
                fractionCompleted: 1.0,
                bytesWritten: finalBytes,
                totalBytes: finalBytes,
                speedBytesPerSecond: 0
            ))

            cont?.resume(returning: context.destinationFileURL)
        } catch {
            // Retain temporary file on size mismatch to allow resumption; delete only on checksum corruption
            if case DownloaderError.checksumMismatch = error {
                try? fileManager.removeItem(at: context.temporaryFileURL)
            }
            cont?.resume(throwing: error)
        }

        cleanupTask(modelId: modelId)
    }

    private func cleanupTask(modelId: String) {
        lock.lock()
        defer { lock.unlock() }
        if let context = activeDownloads.removeValue(forKey: modelId),
           let taskId = context.dataTask?.taskIdentifier {
            taskLookup.removeValue(forKey: taskId)
        }
    }
}
