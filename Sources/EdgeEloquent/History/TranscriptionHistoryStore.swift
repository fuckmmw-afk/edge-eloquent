// Sources/EdgeEloquent/History/TranscriptionHistoryStore.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation
import SwiftUI

/// Manages on-device persistence for transcription records using a local JSON store.
///
/// ### Architecture & Privacy Invariants:
/// - **Strictly Local:** Stored exclusively in the local Application Support container.
/// - **Zero Cloud / Sync:** No iCloud, CloudKit, remote databases, accounts, or telemetry.
/// - **No Export:** Encapsulated strictly on-device; records remain in local sandbox storage.
/// - **Atomic Durability:** Atomic file replacement prevents corruption during crashes or mid-write interruptions.
/// - **Excluded from Backup:** Backing directory is excluded from iCloud/iTunes backups to preserve user privacy.
@MainActor
public final class TranscriptionHistoryStore: ObservableObject {

    /// Shared singleton instance for application-wide access.
    public static let shared = TranscriptionHistoryStore()

    /// The name of the history JSON database file.
    public static let databaseFilename = "transcription_history.json"

    /// The subdirectory inside Application Support.
    public static let applicationSubdirectory = "EdgeEloquent"

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

    /// In-memory records list, ordered newest first.
    @Published public private(set) var records: [TranscriptionRecord] = []

    /// Backing filesystem URL.
    public let fileURL: URL

    /// File manager instance used for I/O operations.
    private let fileManager: FileManager

    /// Creates a new transcription history store.
    /// - Parameters:
    ///   - fileURL: The JSON file location on disk. Defaults to Application Support container.
    ///   - fileManager: The FileManager to use for filesystem operations. Defaults to `.default`.
    public init(
        fileURL: URL = TranscriptionHistoryStore.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.loadHistory()
    }

    // MARK: - CRUD Operations

    /// Loads all transcription records from local storage into memory.
    ///
    /// If the file does not exist, an empty list is assigned without throwing.
    /// - Returns: The array of loaded records.
    @discardableResult
    public func loadHistory() -> [TranscriptionRecord] {
        let loaded = Self.read(from: fileURL, fileManager: fileManager)
        self.records = loaded
        return loaded
    }

    /// Retrieves all current records (convenience accessor).
    /// - Returns: An array of all saved records.
    public func listRecords() -> [TranscriptionRecord] {
        return records
    }

    /// Retrieves a single record by its unique identifier.
    /// - Parameter id: The UUID of the record to locate.
    /// - Returns: The matching `TranscriptionRecord` if found, or `nil`.
    public func getRecord(id: UUID) -> TranscriptionRecord? {
        return records.first { $0.id == id }
    }

    /// Saves a transcription record to the store.
    ///
    /// If a record with the same ID exists, it is updated in place.
    /// Otherwise, the new record is prepended at index 0 (newest first).
    /// Immediately triggers an atomic write to disk.
    /// - Parameter record: The transcription record to save.
    public func saveRecord(_ record: TranscriptionRecord) {
        if let existingIndex = records.firstIndex(where: { $0.id == record.id }) {
            records[existingIndex] = record
        } else {
            records.insert(record, at: 0)
        }
        persist()
    }

    /// Deletes a record with the specified UUID from memory and disk.
    /// - Parameter id: The UUID of the record to delete.
    public func deleteRecord(id: UUID) {
        let originalCount = records.count
        records.removeAll { $0.id == id }
        if records.count != originalCount {
            persist()
        }
    }

    /// Deletes multiple records identified by their UUIDs.
    /// - Parameter ids: A set of UUIDs to delete.
    public func deleteRecords(ids: Set<UUID>) {
        let originalCount = records.count
        records.removeAll { ids.contains($0.id) }
        if records.count != originalCount {
            persist()
        }
    }

    /// Removes all records from memory and empties the persistent file.
    public func clearAll() {
        guard !records.isEmpty else { return }
        records.removeAll()
        persist()
    }

    // MARK: - Persistence & Atomic I/O

    /// Commits the in-memory records to disk atomically.
    private func persist() {
        Self.write(records, to: fileURL, fileManager: fileManager)
    }

    /// Reads transcription records from a JSON file URL.
    /// - Parameters:
    ///   - sourceURL: The source file location.
    ///   - fileManager: The FileManager to check existence with.
    /// - Returns: The decoded records or an empty array on failure.
    public static func read(from sourceURL: URL, fileManager: FileManager = .default) -> [TranscriptionRecord] {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: sourceURL)
            let decoded = try decoder.decode([TranscriptionRecord].self, from: data)
            return decoded
        } catch {
            print("[TranscriptionHistoryStore] Failed to decode history from \(sourceURL.path): \(error)")
            return []
        }
    }

    /// Writes an array of transcription records atomically to the specified destination.
    ///
    /// 1. Ensures directory exists and is excluded from backup.
    /// 2. Serializes data using ISO-8601 JSON format.
    /// 3. Writes data to a unique temporary file with `Data.WritingOptions.atomic` (`NSDataWritingAtomic`).
    /// 4. Atomically replaces or moves the temporary file to the final destination.
    /// - Parameters:
    ///   - records: The array of records to serialize.
    ///   - destinationURL: The target file destination URL.
    ///   - fileManager: The FileManager used for filesystem operations.
    public static func write(_ records: [TranscriptionRecord], to destinationURL: URL, fileManager: FileManager = .default) {
        do {
            let directory = destinationURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                var mutableDirectory = directory
                try? mutableDirectory.setResourceValues(resourceValues)
            }

            let data = try encoder.encode(records)

            // Create temporary file path in the same directory to enable atomic filesystem rename
            let tempFilename = ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
            let tempURL = directory.appendingPathComponent(tempFilename)

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
                        withItemAt: tempURL,
                        backupItemName: nil,
                        options: [],
                        resultingItemURL: nil
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
