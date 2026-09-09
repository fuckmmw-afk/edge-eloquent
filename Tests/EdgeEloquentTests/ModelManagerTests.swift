// Tests/EdgeEloquentTests/ModelManagerTests.swift
// Edge Eloquent - On-Device Audio Intelligence Tests
import XCTest
import CryptoKit
@testable import EdgeEloquent

// MARK: - Mock URL Protocol for Network Isolation

final class MockModelURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.withLock {
            requestHandler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let handler = MockModelURLProtocol.lock.withLock {
            MockModelURLProtocol.requestHandler
        }

        guard let handler = handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        DispatchQueue.global().async {
            do {
                let (response, data) = try handler(self.request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

// MARK: - ModelManagerTests Suite

final class ModelManagerTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var testUserDefaults: UserDefaults!
    private var testSuiteName: String!

    override func setUpWithError() throws {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeEloquentModelTests-\(uniqueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        testSuiteName = "com.edgeeloquent.tests.\(uniqueID)"
        testUserDefaults = UserDefaults(suiteName: testSuiteName)!
        testUserDefaults.removePersistentDomain(forName: testSuiteName)

        // Reset mock network handler
        MockModelURLProtocol.lock.lock()
        MockModelURLProtocol.requestHandler = nil
        MockModelURLProtocol.lock.unlock()
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        if let testSuiteName = testSuiteName {
            testUserDefaults?.removePersistentDomain(forName: testSuiteName)
        }
        MockModelURLProtocol.lock.lock()
        MockModelURLProtocol.requestHandler = nil
        MockModelURLProtocol.lock.unlock()
        super.tearDown()
    }

    // MARK: - SupportedAudioModel Catalog Tests

    func testSupportedAudioModelsCatalogCompleteness() {
        let models = SupportedAudioModel.allModels

        // Three runnable bundles plus Qwen retained only for incompatible-download cleanup.
        XCTAssertEqual(models.count, 4)

        let ids = Set(models.map { $0.name })
        XCTAssertTrue(ids.contains("Gemma-3n-E2B-it"))
        XCTAssertTrue(ids.contains("Gemma-3n-E4B-it"))
        XCTAssertTrue(ids.contains("Qwen3-ASR-0.6B"))
        XCTAssertTrue(ids.contains("VibeVoice-ASR-BitNet"))

        // Invariant: All supported models must support audio dictation
        for model in models {
            XCTAssertTrue(model.llmSupportAudio, "Model \(model.name) must support audio input")
            XCTAssertTrue(model.filename.hasSuffix(".litertlm"), "Model \(model.name) must be .litertlm format")
            XCTAssertFalse(model.commitHash.isEmpty, "Model \(model.name) must have a pinned commit hash")
            XCTAssertGreaterThan(model.expectedBytes, 0, "Model \(model.name) expected bytes must be positive")
            XCTAssertGreaterThan(model.minRAMBytes, 0, "Model \(model.name) min RAM must be positive")
            XCTAssertFalse(model.sanitizedDirectoryName.contains("/"), "Sanitized directory name must not contain slashes")
        }
        XCTAssertFalse(SupportedAudioModel.qwen3ASR_06B.supportsLiteRTLMConversation)
        XCTAssertEqual(SupportedAudioModel.defaultModel, .vibeVoiceASRBitNet)
    }

    func testModelLookupByIdOrName() {
        let e2b = SupportedAudioModel.find(byIdOrName: "Gemma-3n-E2B-it")
        XCTAssertNotNil(e2b)
        XCTAssertEqual(e2b?.id, "google/gemma-3n-E2B-it-litert-lm")

        let g3n = SupportedAudioModel.find(byIdOrName: "google/gemma-3n-E2B-it-litert-lm")
        XCTAssertNotNil(g3n)
        XCTAssertEqual(g3n?.name, "Gemma-3n-E2B-it")

        let nonexistent = SupportedAudioModel.find(byIdOrName: "nonexistent-model")
        XCTAssertNil(nonexistent)
    }

    func testModelResolveURLGeneration() {
        let model = SupportedAudioModel.gemma3n_E2B_it
        let url = model.resolveURL()

        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertTrue(url.path.contains("google/gemma-3n-E2B-it-litert-lm"))
        XCTAssertTrue(url.path.contains("resolve"))
        XCTAssertTrue(url.path.contains(model.commitHash))
        XCTAssertTrue(url.path.contains("gemma-3n-E2B-it-int4.litertlm"))
    }

    func testModelFormattedSize() {
        let model = SupportedAudioModel.gemma3n_E2B_it
        let formatted = model.formattedExpectedSize
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.contains("GB") || formatted.contains("B"))
    }

    // MARK: - ModelRepoDownloader Utilities Tests

    func testFileSizeValidation() throws {
        let testFile = tempDirectoryURL.appendingPathComponent("dummy.bin")
        let dummyData = Data(repeating: 0xAB, count: 1024)
        try dummyData.write(to: testFile)

        // Exact match succeeds
        XCTAssertNoThrow(try ModelRepoDownloader.validateFileSize(fileURL: testFile, expectedBytes: 1024))

        // Mismatch throws
        XCTAssertThrowsError(try ModelRepoDownloader.validateFileSize(fileURL: testFile, expectedBytes: 2048)) { error in
            guard case DownloaderError.fileSizeMismatch(let expected, let actual) = error else {
                XCTFail("Expected fileSizeMismatch, got \(error)")
                return
            }
            XCTAssertEqual(expected, 2048)
            XCTAssertEqual(actual, 1024)
        }
    }

    func testStreamingSHA256ChecksumCalculation() throws {
        let testFile = tempDirectoryURL.appendingPathComponent("hash_test.bin")
        let testString = "EdgeEloquent-LiteRT-Audio-Verification"
        let data = testString.data(using: .utf8)!
        try data.write(to: testFile)

        let computedHash = try ModelRepoDownloader.computeSHA256(for: testFile)

        // Compute expected hash using CryptoKit directly
        let expectedDigest = SHA256.hash(data: data)
        let expectedHash = expectedDigest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(computedHash, expectedHash)

        // Validate checksum helper
        XCTAssertNoThrow(try ModelRepoDownloader.validateChecksum(fileURL: testFile, expectedChecksum: expectedHash))
        XCTAssertThrowsError(try ModelRepoDownloader.validateChecksum(fileURL: testFile, expectedChecksum: "0000000000000000000000000000000000000000000000000000000000000000"))
    }

    func testAtomicMoveAndReplace() throws {
        let sourceFile = tempDirectoryURL.appendingPathComponent("source.bin")
        let destFile = tempDirectoryURL.appendingPathComponent("dest_dir/final.bin")

        let sourceData = "New model weights".data(using: .utf8)!
        try sourceData.write(to: sourceFile)

        // Atomic move into new directory
        try ModelRepoDownloader.atomicMove(from: sourceFile, to: destFile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))

        let readBack = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(readBack, "New model weights")

        // Replace existing item
        let newSource = tempDirectoryURL.appendingPathComponent("new_source.bin")
        try "Updated weights".data(using: .utf8)!.write(to: newSource)
        try ModelRepoDownloader.atomicMove(from: newSource, to: destFile)

        let updatedReadBack = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(updatedReadBack, "Updated weights")
    }

    func testDownloadProgressFormatting() {
        let progress = DownloadProgress(
            fractionCompleted: 0.75,
            bytesWritten: 750_000_000,
            totalBytes: 1_000_000_000,
            speedBytesPerSecond: 25_000_000
        )

        XCTAssertEqual(progress.fractionCompleted, 0.75)
        XCTAssertEqual(progress.bytesWritten, 750_000_000)
        XCTAssertEqual(progress.totalBytes, 1_000_000_000)
        XCTAssertTrue(progress.formattedSpeed.contains("/s"))
        XCTAssertTrue(progress.formattedBytesTransfer.contains("/"))
        XCTAssertEqual(progress.formattedPercent, "75%")
    }

    // MARK: - HuggingFaceSearchService Tests

    func testMetadataParsingAndAudioCompatibility() throws {
        let json = """
        {
            "id": "litert-community/gemma-4-E2B-it-litert-lm",
            "author": "litert-community",
            "sha": "7fa1d78473894f7e736a21d920c3aa80f950c0db",
            "tags": ["litert-lm", "gemma", "audio", "multimodal"],
            "pipeline_tag": "audio-to-text",
            "siblings": [
                {
                    "rfilename": "gemma-4-E2B-it.litertlm",
                    "size": 2588147712,
                    "lfs": {
                        "oid": "7fa1d78473894f7e736a21d920c3aa80f950c0db",
                        "size": 2588147712
                    }
                },
                {
                    "rfilename": "README.md",
                    "size": 450
                }
            ],
            "cardData": {
                "tags": ["audio"],
                "llmSupportAudio": true,
                "llmSupportImage": true
            }
        }
        """
        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(HuggingFaceModelMetadata.self, from: data)

        XCTAssertEqual(metadata.id, "litert-community/gemma-4-E2B-it-litert-lm")
        XCTAssertEqual(metadata.siblings.count, 2)
        XCTAssertEqual(metadata.litertlmSiblings.count, 1)
        XCTAssertEqual(metadata.primaryLitertlmSibling?.rfilename, "gemma-4-E2B-it.litertlm")
        XCTAssertEqual(metadata.cardData?.llmSupportAudio, true)

        let service = HuggingFaceSearchService()
        let report = service.verifyCompatibility(metadata: metadata)

        XCTAssertTrue(report.isCompatible)
        XCTAssertTrue(report.hasLitertlmFormat)
        XCTAssertTrue(report.supportsAudio)
        XCTAssertEqual(report.modelFilename, "gemma-4-E2B-it.litertlm")
        XCTAssertEqual(report.fileSizeBytes, 2_588_147_712)
    }

    func testIncompatibleModelWithoutLitertlmFormat() throws {
        let json = """
        {
            "id": "openai/whisper-large-v3",
            "tags": ["audio", "speech"],
            "pipeline_tag": "automatic-speech-recognition",
            "siblings": [
                { "rfilename": "model.safetensors", "size": 3000000000 }
            ],
            "cardData": {
                "llmSupportAudio": true
            }
        }
        """
        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(HuggingFaceModelMetadata.self, from: data)

        let service = HuggingFaceSearchService()
        let report = service.verifyCompatibility(metadata: metadata)

        XCTAssertFalse(report.isCompatible, "Model without .litertlm format must be rejected")
        XCTAssertFalse(report.hasLitertlmFormat)
        XCTAssertTrue(report.supportsAudio)
        XCTAssertTrue(report.diagnosticReasons.contains(where: { $0.contains(".litertlm") }))
    }

    func testIncompatibleModelWithoutAudioSupport() throws {
        let json = """
        {
            "id": "litert-community/Qwen2.5-1.5B-Instruct",
            "tags": ["text-generation", "litert-lm"],
            "pipeline_tag": "text-generation",
            "siblings": [
                { "rfilename": "qwen2.5-1.5b-instruct.litertlm", "size": 1600000000 }
            ],
            "cardData": {
                "llmSupportAudio": false
            }
        }
        """
        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(HuggingFaceModelMetadata.self, from: data)

        let service = HuggingFaceSearchService()
        let report = service.verifyCompatibility(metadata: metadata)

        XCTAssertFalse(report.isCompatible, "Model without audio support must be rejected for dictation pipeline")
        XCTAssertTrue(report.hasLitertlmFormat)
        XCTAssertFalse(report.supportsAudio)
        XCTAssertTrue(report.diagnosticReasons.contains(where: { $0.contains("audio") }))
    }

    func testHuggingFaceNetworkFetchWithMock() async throws {
        let modelId = "google/gemma-3n-E2B-it-litert-lm"
        let jsonResponse = """
        {
            "id": "\(modelId)",
            "sha": "73b019b63436d346f68dd9c1dbfd117eb264d888",
            "tags": ["litert-lm", "audio"],
            "siblings": [
                { "rfilename": "gemma-3n-E2B-it-int4.litertlm", "size": 3388604416 }
            ],
            "cardData": {
                "llmSupportAudio": true
            }
        }
        """

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockModelURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        MockModelURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, jsonResponse.data(using: .utf8)!)
        }

        let service = HuggingFaceSearchService(session: mockSession)
        let report = try await service.fetchAndVerifyModel(modelId: modelId)

        XCTAssertTrue(report.isCompatible)
        XCTAssertEqual(report.modelId, modelId)
        XCTAssertEqual(report.modelFilename, "gemma-3n-E2B-it-int4.litertlm")
    }

    func testCurrentHuggingFaceLFSChecksumFieldIsDecoded() throws {
        let data = #"{"sha256":"d4444d51","size":959627232}"#.data(using: .utf8)!
        let lfs = try JSONDecoder().decode(HuggingFaceLFS.self, from: data)
        XCTAssertEqual(lfs.checksum, "d4444d51")
        XCTAssertEqual(lfs.size, 959_627_232)
    }

    func testCompatibilityUsesRepositoryRevisionAndArtifactChecksumSeparately() throws {
        let metadata = HuggingFaceModelMetadata(
            id: "example/audio-model",
            sha: "repository-revision",
            tags: ["audio", "litert-lm"],
            pipelineTag: "automatic-speech-recognition",
            siblings: [
                HuggingFaceSibling(
                    rfilename: "audio.litertlm",
                    lfs: HuggingFaceLFS(sha256: "artifact-sha256", size: 900_000_000)
                )
            ]
        )
        let report = HuggingFaceSearchService().verifyCompatibility(metadata: metadata)
        XCTAssertEqual(report.commitHash, "repository-revision")
        XCTAssertEqual(report.artifactSHA256, "artifact-sha256")
    }

    func testQwenCompiledModelIsRejectedDespiteLitertlmExtension() {
        let metadata = HuggingFaceModelMetadata(
            id: "litert-community/Qwen3-ASR-0.6B",
            sha: "revision",
            tags: ["tflite", "automatic-speech-recognition", "audio"],
            pipelineTag: "automatic-speech-recognition",
            siblings: [
                HuggingFaceSibling(
                    rfilename: "qwen3_asr_0.6b_5s_i8.litertlm",
                    size: 959_627_232
                )
            ]
        )

        let report = HuggingFaceSearchService().verifyCompatibility(metadata: metadata)
        XCTAssertTrue(report.hasLitertlmFormat)
        XCTAssertTrue(report.supportsAudio)
        XCTAssertFalse(report.isCompatible)
        XCTAssertTrue(report.diagnosticReasons.contains(where: { $0.contains("conversation runtime") }))
    }

    // MARK: - ModelManager Lifecycle & State Tests

    @MainActor
    func testModelManagerInitialStateAllNotDownloaded() {
        let manager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )

        XCTAssertEqual(manager.supportedModels.count, 4)
        XCTAssertNil(manager.activeModelId)
        XCTAssertNil(manager.activeModel)
        XCTAssertEqual(manager.downloadedModels.count, 0)

        for model in manager.supportedModels {
            if model == .qwen3ASR_06B {
                guard case .unsupported(let installed, _) = manager.state(for: model.id) else {
                    return XCTFail("Qwen must be marked unsupported")
                }
                XCTAssertFalse(installed)
            } else {
                XCTAssertEqual(manager.state(for: model.id), .notDownloaded)
            }
        }
    }

    @MainActor
    func testLegacyQwenSelectionIsPreservedWithoutAppleFallback() throws {
        let qwen = SupportedAudioModel.qwen3ASR_06B
        let target = tempDirectoryURL
            .appendingPathComponent(qwen.sanitizedDirectoryName, isDirectory: true)
            .appendingPathComponent(qwen.commitHash, isDirectory: true)
            .appendingPathComponent(qwen.filename)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: target)
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: UInt64(qwen.expectedBytes))
        try handle.close()
        testUserDefaults.set(qwen.id, forKey: ModelManager.activeModelUserDefaultsKey)

        let manager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )

        XCTAssertEqual(manager.activeModelId, qwen.id)
        guard case .unsupported(let installed, let reason) = manager.state(for: qwen.id) else {
            return XCTFail("Qwen must be marked unsupported")
        }
        XCTAssertTrue(installed)
        XCTAssertTrue(reason.contains("CompiledModel"))
        XCTAssertThrowsError(try manager.setActiveModel(id: qwen.id))
    }

    @MainActor
    func testDiscoveredCompatibleModelPersistsInCatalog() throws {
        let report = ModelCompatibilityReport(
            modelId: "publisher/custom-asr",
            isCompatible: true,
            hasLitertlmFormat: true,
            supportsAudio: true,
            modelFilename: "custom-asr.litertlm",
            fileSizeBytes: 800_000_000,
            commitHash: "repository-revision",
            artifactSHA256: "artifact-checksum",
            diagnosticReasons: []
        )
        let manager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )
        let imported = try manager.addDiscoveredModel(report)
        XCTAssertTrue(manager.isUserImportedModel(imported))
        XCTAssertEqual(imported.expectedSHA256, "artifact-checksum")

        let restored = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )
        XCTAssertTrue(restored.supportedModels.contains(where: { $0.id == report.modelId }))
    }

    @MainActor
    func testModelManagerDetectsDownloadedFiles() throws {
        let testModel = SupportedAudioModel.gemma3n_E2B_it
        let manager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )

        let targetURL = manager.modelFileURL(for: testModel)
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Create dummy model file of expected size
        let handle = FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        XCTAssertTrue(handle)
        let fileHandle = try FileHandle(forWritingTo: targetURL)
        try fileHandle.truncate(atOffset: UInt64(testModel.expectedBytes))
        try fileHandle.close()

        // Refresh states
        manager.refreshModelStates()

        XCTAssertEqual(manager.state(for: testModel.id), .active) // First ready model automatically activates
        XCTAssertEqual(manager.activeModelId, testModel.id)
        XCTAssertEqual(manager.activeModel?.name, "Gemma-3n-E2B-it")
        XCTAssertEqual(manager.downloadedModels.count, 1)
    }

    @MainActor
    func testModelManagerRejectsTruncatedModelFile() throws {
        let model = SupportedAudioModel.gemma3n_E2B_it
        let manager = ModelManager(modelsDirectory: tempDirectoryURL, userDefaults: testUserDefaults)
        let targetURL = manager.modelFileURL(for: model)
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: targetURL)

        manager.refreshModelStates()

        XCTAssertFalse(manager.isModelDownloaded(model))
        XCTAssertEqual(manager.state(for: model.id), .notDownloaded)
    }

    @MainActor
    func testSetActiveModelPersistenceInUserDefaults() throws {
        let model1 = SupportedAudioModel.gemma3n_E2B_it
        let model2 = SupportedAudioModel.gemma3n_E4B_it

        let manager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )

        // Place both models on disk
        for m in [model1, model2] {
            let url = manager.modelFileURL(for: m)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let fh = try FileHandle(forWritingTo: url)
            try fh.truncate(atOffset: UInt64(m.expectedBytes))
            try fh.close()
        }

        manager.refreshModelStates()

        // Switch active model to model2
        try manager.setActiveModel(id: model2.id)

        XCTAssertEqual(manager.activeModelId, model2.id)
        XCTAssertEqual(manager.state(for: model2.id), .active)
        XCTAssertEqual(manager.state(for: model1.id), .ready)

        // Verify persistence in UserDefaults
        let persisted = testUserDefaults.string(forKey: ModelManager.activeModelUserDefaultsKey)
        XCTAssertEqual(persisted, model2.id)

        // Create new ModelManager with same UserDefaults and verify restored active model
        let newManager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )
        XCTAssertEqual(newManager.activeModelId, model2.id)
        XCTAssertEqual(newManager.state(for: model2.id), .active)
        XCTAssertEqual(newManager.state(for: model1.id), .ready)
    }

    @MainActor
    func testSetActiveModelThrowsIfNotDownloaded() {
        let manager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )

        XCTAssertThrowsError(try manager.setActiveModel(id: SupportedAudioModel.gemma3n_E4B_it.id)) { error in
            guard case ModelManagerError.modelNotReady(let id) = error else {
                XCTFail("Expected modelNotReady, got \(error)")
                return
            }
            XCTAssertEqual(id, SupportedAudioModel.gemma3n_E4B_it.id)
        }
    }

    @MainActor
    func testModelDeletionReclaimsSpaceAndResetsState() throws {
        let model = SupportedAudioModel.gemma3n_E2B_it
        let manager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )

        let targetURL = manager.modelFileURL(for: model)
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: targetURL)
        try fh.truncate(atOffset: UInt64(model.expectedBytes))
        try fh.close()

        manager.refreshModelStates()
        manager.refreshDiskSpace()

        XCTAssertTrue(manager.state(for: model.id).isDownloaded)
        XCTAssertNotNil(manager.modelSizeOnDisk(for: model.id))

        // Delete model
        try manager.deleteModel(id: model.id)

        XCTAssertEqual(manager.state(for: model.id), .notDownloaded)
        XCTAssertNil(manager.activeModelId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        XCTAssertNil(manager.modelSizeOnDisk(for: model.id))
        XCTAssertNil(testUserDefaults.string(forKey: ModelManager.activeModelUserDefaultsKey))
    }

    @MainActor
    func testDiskSpaceTrackingMetrics() {
        let manager = ModelManager(
            modelsDirectory: tempDirectoryURL,
            userDefaults: testUserDefaults
        )

        manager.refreshDiskSpace()

        // Available disk space should be non-zero on healthy storage volume
        XCTAssertGreaterThan(manager.availableDiskSpaceBytes, 0)
        XCTAssertGreaterThan(manager.totalDiskSpaceBytes, 0)
        XCTAssertFalse(manager.availableStorageFormatted.isEmpty)
        XCTAssertFalse(manager.totalStorageFormatted.isEmpty)
    }

    // MARK: - Architectural Invariant: Zero Bundled Weights

    func testBundleWeightIsolationInvariantPassesWhenClean() throws {
        // Standard bundle has no .litertlm weights
        XCTAssertNoThrow(try ModelManager.assertNoBundledWeights(bundle: .main))
    }

    func testBundleWeightIsolationInvariantThrowsWhenWeightsPresent() throws {
        // Create a simulated bundle directory containing forbidden .litertlm file
        let simulatedBundleDir = tempDirectoryURL.appendingPathComponent("SimulatedApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: simulatedBundleDir, withIntermediateDirectories: true)

        let forbiddenFile = simulatedBundleDir.appendingPathComponent("gemma-4-E2B-it.litertlm")
        FileManager.default.createFile(atPath: forbiddenFile.path, contents: Data("fake weights".utf8))

        let simulatedBundle = Bundle(url: simulatedBundleDir)!

        XCTAssertThrowsError(try ModelManager.assertNoBundledWeights(bundle: simulatedBundle)) { error in
            guard case ModelManagerError.bundledWeightsDetected(let files) = error else {
                XCTFail("Expected bundledWeightsDetected error, got \(error)")
                return
            }
            XCTAssertFalse(files.isEmpty)
            XCTAssertTrue(files.contains { $0.contains(".litertlm") })
        }
    }
}
