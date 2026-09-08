// Sources/EdgeEloquent/History/TranscriptionHistoryStore.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation
import Combine

/// Errors encountered by `TranscriptionHistoryStore`.
public enum HistoryStoreError: LocalizedError, Equatable {
    case recordNotFound(UUID)
    case writeFailed(String)
    case serializationError(String)

    public var errorDescription: String? {
        switch self {
        case .recordNotFound(let id):
            return "Transcription record with ID \(id) was not found."
        case .writeFailed(let reason):
            return "Failed to persist transcription history: \(reason)"
        case .serializationError(let reason):
            return "Failed to serialize/deserialize transcription history: \(reason)"
        }
    }
}

/// Thread-safe local storage manager for historical dictations.
///
/// Stores entries in `Application Support/EdgeEloquent/transcription_history.json`.
/// Uses atomic write replacement to prevent database corruption during app termination.
@MainActor
public final class TranscriptionHistoryStore: ObservableObject {

    // MARK: - Constants

    /// The name of the history JSON database file.
    nonisolated public static let databaseFilename = "transcription_history.json"

    /// The subdirectory inside Application Support.
    nonisolated public static let applicationSubdirectory = "EdgeEloquent"

    /// Default directory URL in Application Support for Edge Eloquent storage.
    nonisolated public static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(applicationSubdirectory, isDirectory: true)
    }

    /// Default file URL for the transcription history JSON file.
    nonisolated public static var defaultFileURL: URL {
        defaultDirectoryURL.appendingPathComponent(databaseFilename)
    }

    /// Shared singleton instance for SwiftUI default environment.
    public static let shared = TranscriptionHistoryStore()

    /// In-memory records list, ordered newest first.
    @Published public private(set) var records: [TranscriptionRecord] = []

    /// Clears all records from history.
    public func clearAll() {
        clearAllHistory()
    }

    // MARK: - Dependencies

    public let destinationURL: URL
    private let fileManager: FileManager

    // MARK: - Initialization

    /// Initializes the store with a designated storage URL.
    /// - Parameters:
    ///   - destinationURL: File URL to store the JSON database.
    ///   - fileManager: File manager instance.
    public init(
        destinationURL: URL = TranscriptionHistoryStore.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.destinationURL = destinationURL
        self.fileManager = fileManager

        createDirectoryIfNeeded()
        loadRecords()
    }

    // MARK: - Directory Management

    private func createDirectoryIfNeeded() {
        let dir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                print("[TranscriptionHistoryStore] Failed to create directory at \(dir.path): \(error)")
            }
        }
    }

    // MARK: - CRUD Operations

    /// Appends a new transcription record to history and persists to disk.
    /// New records are prepended so that `records.first` is always the most recent.
    @discardableResult
    public func saveRecord(_ record: TranscriptionRecord) -> TranscriptionRecord {
        addRecord(record)
    }

    public func addRecord(_ record: TranscriptionRecord) -> TranscriptionRecord {
        records.insert(record, at: 0)
        persistAllRecordsImmediately()
        return record
    }

    /// Creates and saves a new record with convenient parameters.
    @discardableResult
    public func record(
        rawText: String,
        cleanedText: String,
        enhancedText: String? = nil,
        audioDurationSeconds: TimeInterval,
        modelUsed: String,
        tokensCount: Int? = nil,
        enhancementMode: String? = nil
    ) -> TranscriptionRecord {
        let rec = TranscriptionRecord(
            rawText: rawText,
            cleanedText: cleanedText,
            enhancedText: enhancedText,
            audioDurationSeconds: audioDurationSeconds,
            modelUsed: modelUsed,
            tokensCount: tokensCount,
            enhancementMode: enhancementMode
        )
        return addRecord(rec)
    }

    /// Updates an existing record (e.g. after asynchronous Cloudflare text enhancement completes).
    public func updateRecord(_ updated: TranscriptionRecord) throws {
        guard let index = records.firstIndex(where: { $0.id == updated.id }) else {
            throw HistoryStoreError.recordNotFound(updated.id)
        }
        records[index] = updated
        persistAllRecordsImmediately()
    }

    /// Updates the enhanced text of an existing record.
    public func setEnhancedText(for recordId: UUID, enhancedText: String, mode: String?) throws {
        guard let index = records.firstIndex(where: { $0.id == recordId }) else {
            throw HistoryStoreError.recordNotFound(recordId)
        }
        records[index].enhancedText = enhancedText
        records[index].enhancementMode = mode
        persistAllRecordsImmediately()
    }

    /// Deletes a specific record by its ID.
    public func deleteRecord(id: UUID) {
        records.removeAll(where: { $0.id == id })
        persistAllRecordsImmediately()
    }

    /// Deletes records at specified offsets (e.g. SwiftUI `onDelete(perform:)`).
    public func deleteRecords(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        persistAllRecordsImmediately()
    }

    /// Deletes all history records from memory and wipes the disk file.
    public func clearAllHistory() {
        records.removeAll()
        persistAllRecordsImmediately()
    }

    /// Retrieves a single record by its UUID.
    public func record(withId id: UUID) -> TranscriptionRecord? {
        records.first(where: { $0.id == id })
    }

    // MARK: - Search & Filtering

    /// Filters records containing the search query in raw, cleaned, or enhanced text.
    public func search(query: String) -> [TranscriptionRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return records }

        return records.filter { record in
            record.primaryDisplayText.lowercased().contains(trimmed) ||
            record.rawText.lowercased().contains(trimmed) ||
            record.modelUsed.lowercased().contains(trimmed)
        }
    }

    // MARK: - Serialization & Atomic Storage

    /// Reloads records from disk. Replaces in-memory array.
    public func loadRecords() {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            self.records = []
            return
        }

        do {
            let data = try Data(contentsOf: destinationURL)
            let decoded = try Self.decoder.decode([TranscriptionRecord].self, from: data)
            // Ensure sorted newest first
            self.records = decoded.sorted(by: { $0.createdAt > $1.createdAt })
        } catch {
            print("[TranscriptionHistoryStore] Error loading history from \(destinationURL.path): \(error). Initializing empty store.")
            self.records = []
        }
    }

    /// Synchronously encodes and writes the entire records array to disk atomically.
    public func persistAllRecordsImmediately() {
        do {
            let data = try Self.encoder.encode(records)

            // Atomic write pattern: write to unique temporary file, then rename/replace
            let tempDir = destinationURL.deletingLastPathComponent()
            let tempURL = tempDir.appendingPathComponent(".temp_\(UUID().uuidString).tmp")

            defer {
                if fileManager.fileExists(atPath: tempURL.path) {
                    try? fileManager.removeItem(at: tempURL)
                }
            }

            // Write to temp file using NSDataWritingAtomic (Data.WritingOptions.atomic)
            try data.write(to: tempURL, options: .atomic)

            // Atomically replace the destination with the temporary file
            if fileManager.fileExists(atPath: destinationURL.path) {
                do {
                    _ = try fileManager.replaceItemAt(
                        destinationURL,
                        withItemAt: tempURL
                    )
                } catch {
                    // Fallback in environments where replaceItemAt might fail across specific POSIX mounts
                    try? fileManager.removeItem(at: destinationURL)
                    try fileManager.moveItem(at: tempURL, to: destinationURL)
                }
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            print("[TranscriptionHistoryStore] Failed to write history atomically to \(destinationURL.path): \(error)")
        }
    }

    // MARK: - JSON Coders

    /// Pre-configured JSONEncoder standardizing dates to ISO-8601.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Pre-configured JSONDecoder expecting ISO-8601 dates.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
