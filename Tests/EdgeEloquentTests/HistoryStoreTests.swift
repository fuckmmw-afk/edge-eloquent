// Tests/EdgeEloquentTests/HistoryStoreTests.swift
// Edge Eloquent - On-Device Audio Intelligence Tests
import XCTest
@testable import EdgeEloquent

final class HistoryStoreTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var testFileURL: URL!

    override func setUpWithError() throws {
        super.setUp()
        // Create an isolated temporary test directory for each test
        let uniqueID = UUID().uuidString
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeEloquentTests-\(uniqueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        testFileURL = tempDirectoryURL.appendingPathComponent("transcription_history.json")
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func makeStore() -> TranscriptionHistoryStore {
        return TranscriptionHistoryStore(fileURL: testFileURL)
    }

    private func sampleRecord(
        id: UUID = UUID(),
        date: Date = Date(),
        clean: String = "Hello world",
        final: String = "Hello, world!",
        model: String = "gemma-3n-E2B-it",
        duration: Double = 5.5,
        isEnhanced: Bool = true
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: id,
            date: date,
            cleanTranscript: clean,
            finalText: final,
            modelUsed: model,
            durationSeconds: duration,
            isEnhanced: isEnhanced
        )
    }

    // MARK: - TranscriptionRecord Model Tests

    func testRecordInitializationAndDefaults() {
        let record = TranscriptionRecord(
            cleanTranscript: "Raw transcript",
            finalText: "Final polished text"
        )

        XCTAssertFalse(record.id.uuidString.isEmpty)
        XCTAssertEqual(record.cleanTranscript, "Raw transcript")
        XCTAssertEqual(record.finalText, "Final polished text")
        XCTAssertEqual(record.modelUsed, "")
        XCTAssertEqual(record.durationSeconds, 0.0)
        XCTAssertFalse(record.isEnhanced)
    }

    func testRecordCustomInitialization() {
        let fixedID = UUID()
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let record = TranscriptionRecord(
            id: fixedID,
            date: fixedDate,
            cleanTranscript: "test raw",
            finalText: "test final",
            modelUsed: "whisperKit",
            durationSeconds: 14.2,
            isEnhanced: true
        )

        XCTAssertEqual(record.id, fixedID)
        XCTAssertEqual(record.date, fixedDate)
        XCTAssertEqual(record.cleanTranscript, "test raw")
        XCTAssertEqual(record.finalText, "test final")
        XCTAssertEqual(record.modelUsed, "whisperKit")
        XCTAssertEqual(record.durationSeconds, 14.2)
        XCTAssertTrue(record.isEnhanced)
    }

    func testRecordConvenienceHelpers() {
        let r1 = sampleRecord(duration: 0.0)
        XCTAssertEqual(r1.durationLabel, "0s")

        let r2 = sampleRecord(duration: 42.4)
        XCTAssertEqual(r2.durationLabel, "42s")

        let r3 = sampleRecord(duration: 65.0)
        XCTAssertEqual(r3.durationLabel, "1m 05s")

        let r4 = sampleRecord(duration: 605.0)
        XCTAssertEqual(r4.durationLabel, "10m 05s")

        // Display text helper
        let rWithFinal = sampleRecord(clean: "raw text", final: "polished text")
        XCTAssertEqual(rWithFinal.displayText, "polished text")

        let rEmptyFinal = sampleRecord(clean: "raw text", final: "")
        XCTAssertEqual(rEmptyFinal.displayText, "raw text")

        // withFinalText helper
        let updated = rEmptyFinal.withFinalText("new final", isEnhanced: true)
        XCTAssertEqual(updated.finalText, "new final")
        XCTAssertTrue(updated.isEnhanced)
        XCTAssertEqual(updated.id, rEmptyFinal.id)
    }

    func testRecordCodableRoundTrip() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = sampleRecord(date: originalDate)

        let encoder = TranscriptionHistoryStore.encoder
        let decoder = TranscriptionHistoryStore.decoder

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TranscriptionRecord.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.cleanTranscript, original.cleanTranscript)
        XCTAssertEqual(decoded.finalText, original.finalText)
        XCTAssertEqual(decoded.modelUsed, original.modelUsed)
        XCTAssertEqual(decoded.durationSeconds, original.durationSeconds)
        XCTAssertEqual(decoded.isEnhanced, original.isEnhanced)
        XCTAssertEqual(
            decoded.date.timeIntervalSince1970,
            originalDate.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - History Store Tests

    func testInitialStateIsEmptyWhenNoFileExists() {
        let store = makeStore()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.listRecords().count, 0)
        XCTAssertNil(store.getRecord(id: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFileURL.path))
    }

    func testSaveRecordPersistsToMemoryAndDisk() {
        let store = makeStore()
        let record = sampleRecord()

        store.saveRecord(record)

        // Verify in-memory state
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.id, record.id)
        XCTAssertEqual(store.getRecord(id: record.id)?.finalText, record.finalText)

        // Verify filesystem persistence
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFileURL.path))
        let diskRecords = TranscriptionHistoryStore.read(from: testFileURL)
        XCTAssertEqual(diskRecords.count, 1)
        XCTAssertEqual(diskRecords.first?.id, record.id)
    }

    func testSaveRecordOrdersNewestFirst() {
        let store = makeStore()
        let record1 = sampleRecord(clean: "First")
        let record2 = sampleRecord(clean: "Second")
        let record3 = sampleRecord(clean: "Third")

        store.saveRecord(record1)
        store.saveRecord(record2)
        store.saveRecord(record3)

        // Newest saved record is at index 0
        XCTAssertEqual(store.records.map(\.cleanTranscript), ["Third", "Second", "First"])

        let diskRecords = TranscriptionHistoryStore.read(from: testFileURL)
        XCTAssertEqual(diskRecords.map(\.cleanTranscript), ["Third", "Second", "First"])
    }

    func testSaveRecordUpdatesExistingRecordInPlace() {
        let store = makeStore()
        let id = UUID()
        let original = sampleRecord(id: id, clean: "Original", final: "Original", isEnhanced: false)
        let later = sampleRecord(clean: "Another")

        store.saveRecord(original)
        store.saveRecord(later)

        XCTAssertEqual(store.records.count, 2)

        // Update original record with enhanced text
        let updated = sampleRecord(id: id, clean: "Original", final: "Polished", isEnhanced: true)
        store.saveRecord(updated)

        XCTAssertEqual(store.records.count, 2)
        let found = store.getRecord(id: id)
        XCTAssertEqual(found?.finalText, "Polished")
        XCTAssertTrue(found?.isEnhanced == true)

        // Disk reflects update
        let diskRecords = TranscriptionHistoryStore.read(from: testFileURL)
        XCTAssertEqual(diskRecords.first(where: { $0.id == id })?.finalText, "Polished")
    }

    func testPersistenceSurvivesRelaunch() {
        let store1 = makeStore()
        let r1 = sampleRecord(clean: "One", duration: 1.0)
        let r2 = sampleRecord(clean: "Two", duration: 2.0)

        store1.saveRecord(r1)
        store1.saveRecord(r2)

        // Simulate application relaunch by instantiating a new store instance with same URL
        let store2 = makeStore()

        XCTAssertEqual(store2.records.count, 2)
        XCTAssertEqual(store2.records.map(\.cleanTranscript), ["Two", "One"])
        XCTAssertEqual(store2.records.first?.durationSeconds, 2.0)
        XCTAssertEqual(store2.records.last?.durationSeconds, 1.0)
    }

    func testDeleteRecordById() {
        let store = makeStore()
        let r1 = sampleRecord(clean: "Record 1")
        let r2 = sampleRecord(clean: "Record 2")
        let r3 = sampleRecord(clean: "Record 3")

        store.saveRecord(r1)
        store.saveRecord(r2)
        store.saveRecord(r3)

        XCTAssertEqual(store.records.count, 3)

        // Delete middle record (r2)
        store.deleteRecord(id: r2.id)

        XCTAssertEqual(store.records.count, 2)
        XCTAssertNil(store.getRecord(id: r2.id))
        XCTAssertEqual(store.records.map(\.cleanTranscript), ["Record 3", "Record 1"])

        // Disk reflects deletion
        let diskRecords = TranscriptionHistoryStore.read(from: testFileURL)
        XCTAssertEqual(diskRecords.map(\.cleanTranscript), ["Record 3", "Record 1"])
    }

    func testDeleteNonExistentIdIsNoOp() {
        let store = makeStore()
        let r = sampleRecord()
        store.saveRecord(r)

        store.deleteRecord(id: UUID())

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.id, r.id)
    }

    func testDeleteMultipleRecords() {
        let store = makeStore()
        let r1 = sampleRecord(clean: "A")
        let r2 = sampleRecord(clean: "B")
        let r3 = sampleRecord(clean: "C")

        store.saveRecord(r1)
        store.saveRecord(r2)
        store.saveRecord(r3)

        store.deleteRecords(ids: [r1.id, r3.id])

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.cleanTranscript, "B")

        let diskRecords = TranscriptionHistoryStore.read(from: testFileURL)
        XCTAssertEqual(diskRecords.count, 1)
        XCTAssertEqual(diskRecords.first?.cleanTranscript, "B")
    }

    func testClearAllEmptiesStoreAndFile() {
        let store = makeStore()
        store.saveRecord(sampleRecord(clean: "Item 1"))
        store.saveRecord(sampleRecord(clean: "Item 2"))

        XCTAssertEqual(store.records.count, 2)

        store.clearAll()

        XCTAssertTrue(store.records.isEmpty)
        let diskRecords = TranscriptionHistoryStore.read(from: testFileURL)
        XCTAssertTrue(diskRecords.isEmpty)
    }

    func testCorruptedFileGracefulRecovery() throws {
        // Write corrupt non-JSON content
        try "Corrupted invalid JSON payload {{{".write(to: testFileURL, atomically: true, encoding: .utf8)

        // Store initialization should handle corrupt data gracefully without crashing
        let store = makeStore()
        XCTAssertTrue(store.records.isEmpty)

        // Saving a new record should cleanly overwrite corrupt file with valid JSON
        let validRecord = sampleRecord(clean: "Recovered")
        store.saveRecord(validRecord)

        XCTAssertEqual(store.records.count, 1)
        let diskRecords = TranscriptionHistoryStore.read(from: testFileURL)
        XCTAssertEqual(diskRecords.count, 1)
        XCTAssertEqual(diskRecords.first?.cleanTranscript, "Recovered")
    }

    func testDefaultFileURLStructure() {
        let defaultURL = TranscriptionHistoryStore.defaultFileURL
        XCTAssertTrue(defaultURL.lastPathComponent == "transcription_history.json")
        XCTAssertTrue(defaultURL.deletingLastPathComponent().lastPathComponent == "EdgeEloquent")
    }

    func testLocalIsolationNoCloudSync() {
        // Strict privacy requirement: Local storage only
        let defaultURL = TranscriptionHistoryStore.defaultFileURL
        XCTAssertTrue(defaultURL.isFileURL)
        XCTAssertFalse(defaultURL.path.contains("Mobile Documents")) // Not iCloud Ubiquity
    }
}
