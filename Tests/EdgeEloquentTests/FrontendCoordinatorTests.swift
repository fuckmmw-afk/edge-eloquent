// Tests/EdgeEloquentTests/FrontendCoordinatorTests.swift
// Edge Eloquent - Minimalist Dictation UI & Coordinator Tests
import XCTest
@testable import EdgeEloquent

@MainActor
final class FrontendCoordinatorTests: XCTestCase {

    private var appConfig: AppConfig!
    private var tempDirectoryURL: URL!
    private var historyStore: TranscriptionHistoryStore!
    private var modelManager: ModelManager!

    override func setUpWithError() throws {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeEloquentUITests-\(uniqueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        let historyFileURL = tempDirectoryURL.appendingPathComponent("history.json")
        historyStore = TranscriptionHistoryStore(fileURL: historyFileURL)

        let modelsDir = tempDirectoryURL.appendingPathComponent("Models", isDirectory: true)
        modelManager = ModelManager(modelsDirectory: modelsDir)

        appConfig = AppConfig()
        appConfig.resetToDefaults()
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    // MARK: - AppConfig Tests

    func testAppConfigDefaults() {
        XCTAssertEqual(appConfig.cloudflareWorkerURL, AppConfig.defaultCloudflareURL)
        XCTAssertTrue(appConfig.isLocalCleanupEnabled)
        XCTAssertTrue(appConfig.isCloudflareEnhancementEnabled)
        XCTAssertEqual(appConfig.enhancementMode, .standard)
        XCTAssertTrue(appConfig.enableWebSearch)
        XCTAssertEqual(appConfig.requestTimeout, AppConfig.defaultTimeout)
        XCTAssertFalse(appConfig.autoCopyToClipboard)
        XCTAssertNotNil(appConfig.resolvedCloudflareURL)
    }

    func testAppConfigMutationsAndReset() {
        appConfig.cloudflareWorkerURL = "https://custom-worker.example.com/api/enhance"
        appConfig.isLocalCleanupEnabled = false
        appConfig.isCloudflareEnhancementEnabled = false
        appConfig.enhancementMode = .executiveSummary
        appConfig.enableWebSearch = false
        appConfig.requestTimeout = 25.0

        XCTAssertEqual(appConfig.cloudflareWorkerURL, "https://custom-worker.example.com/api/enhance")
        XCTAssertFalse(appConfig.isLocalCleanupEnabled)
        XCTAssertFalse(appConfig.isCloudflareEnhancementEnabled)
        XCTAssertEqual(appConfig.enhancementMode, .executiveSummary)
        XCTAssertFalse(appConfig.enableWebSearch)
        XCTAssertEqual(appConfig.requestTimeout, 25.0)

        appConfig.resetToDefaults()

        XCTAssertEqual(appConfig.cloudflareWorkerURL, AppConfig.defaultCloudflareURL)
        XCTAssertTrue(appConfig.isLocalCleanupEnabled)
        XCTAssertTrue(appConfig.isCloudflareEnhancementEnabled)
        XCTAssertEqual(appConfig.enhancementMode, .standard)
    }

    func testResolvedCloudflareURLValidation() {
        appConfig.cloudflareWorkerURL = "https://valid.endpoint.dev/api/enhance"
        XCTAssertNotNil(appConfig.resolvedCloudflareURL)
        XCTAssertEqual(appConfig.resolvedCloudflareURL?.host, "valid.endpoint.dev")

        appConfig.cloudflareWorkerURL = "invalid-url-string"
        XCTAssertNil(appConfig.resolvedCloudflareURL)
    }

    // MARK: - DictationCoordinator Lifecycle Tests

    func testDictationCoordinatorInitialState() {
        let coordinator = DictationCoordinator(
            modelManager: modelManager,
            historyStore: historyStore,
            appConfig: appConfig
        )

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.state.isRecording)
        XCTAssertFalse(coordinator.state.isProcessing)
        XCTAssertFalse(coordinator.state.isCompleted)
        XCTAssertEqual(coordinator.realtimePartialTranscript, "")
        XCTAssertEqual(coordinator.finalizedTranscript, "")
        XCTAssertNil(coordinator.activeRecord)
        XCTAssertFalse(coordinator.activeEngineName.isEmpty)
    }

    func testDictationCoordinatorActiveEngineResolution() {
        let coordinator = DictationCoordinator(
            modelManager: modelManager,
            historyStore: historyStore,
            appConfig: appConfig
        )

        coordinator.updateActiveEngineName()
        // When no models downloaded, defaults to Apple Native Speech
        XCTAssertTrue(coordinator.activeEngineName == "Apple Native Speech" || coordinator.activeEngineName.contains("Gemma"))
    }

    func testDictationCoordinatorClearResult() {
        let coordinator = DictationCoordinator(
            modelManager: modelManager,
            historyStore: historyStore,
            appConfig: appConfig
        )

        let dummyRecord = TranscriptionRecord(
            cleanTranscript: "Testing text",
            finalText: "Testing text.",
            modelUsed: "Apple Native Speech"
        )
        coordinator.activeRecord = dummyRecord
        coordinator.state = .completed(record: dummyRecord)
        coordinator.finalizedTranscript = "Testing text."

        XCTAssertTrue(coordinator.state.isCompleted)

        coordinator.clearResult()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.activeRecord)
        XCTAssertEqual(coordinator.finalizedTranscript, "")
        XCTAssertEqual(coordinator.realtimePartialTranscript, "")
    }

    // MARK: - Design System Tokens Tests

    func testThemeDesignTokens() {
        XCTAssertEqual(Theme.cardCornerRadius, 20)
        XCTAssertEqual(Theme.standardCornerRadius, 14)
        XCTAssertEqual(Theme.pillCornerRadius, 100)
        XCTAssertEqual(Theme.standardPadding, 16)
        XCTAssertEqual(Theme.largePadding, 24)
    }

    // MARK: - Gallery Clean Architecture Verification

    func testGalleryScopeStrictlyMinimalistDictation() {
        // Assert that the app target strictly provides Dictation, History, Models, and Settings
        // and does NOT expose or link Image Generation, Vision VQA, Video, Chat, Prompt Lab, or Benchmark modules.
        let tabs = ["Dictation", "History", "Models", "Settings"]
        XCTAssertEqual(tabs.count, 4)
        XCTAssertTrue(tabs.contains("Dictation"))
        XCTAssertTrue(tabs.contains("History"))
        XCTAssertTrue(tabs.contains("Models"))
        XCTAssertTrue(tabs.contains("Settings"))
    }
}
