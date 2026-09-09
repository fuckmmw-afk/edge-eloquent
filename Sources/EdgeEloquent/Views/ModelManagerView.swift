//
//  ModelManagerView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Model browser and lifecycle manager adapted from Google AI Edge Gallery.
//

import SwiftUI

/// Primary Model Manager interface allowing users to browse, download, switch, and delete
/// on-device audio models matching the Google AI Edge Gallery allowlists.
@MainActor
public struct ModelManagerView: View {

    @ObservedObject public var modelManager: ModelManager
    @ObservedObject public var appConfig: AppConfig

    @State private var showingTokenSheet: Bool = false
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false
    @State private var searchQuery: String = "ASR"
    @State private var searchResults: [ModelCompatibilityReport] = []
    @State private var isSearching: Bool = false

    private let searchService = HuggingFaceSearchService()

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.appConfig = .shared
    }

    public init(
        modelManager: ModelManager,
        appConfig: AppConfig
    ) {
        self.modelManager = modelManager
        self.appConfig = appConfig
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 20) {
                    // Storage breakdown card
                    storageOverviewCard

                    // Apple Native Zero-Download Section
                    appleNativeSpeechCard

                    // Search the live Hugging Face catalog instead of presenting a
                    // hard-coded pair of models that may not fit the current device.
                    huggingFaceSearchSection

                    // Recommended, imported, and already-downloaded models.
                    modelLibrarySection

                    // Zero Bundled Weights Architectural Guarantee
                    architecturalGuaranteeCard
                }
                .padding(Theme.standardPadding)
            }
            .background(Theme.surfaceBackground)
            .navigationTitle("Model Manager")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingTokenSheet = true
                    } label: {
                        Image(systemName: "key.fill")
                            .font(.subheadline)
                    }
                }
            }
            #else
            .toolbar {
                ToolbarItem {
                    Button {
                        showingTokenSheet = true
                    } label: {
                        Image(systemName: "key.fill")
                            .font(.subheadline)
                    }
                }
            }
            #endif
            .sheet(isPresented: $showingTokenSheet) {
                hfTokenSheet
            }
            .alert("Model Manager Alert", isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "An unknown error occurred.")
            }
            .onAppear {
                modelManager.refreshModelStates()
                modelManager.refreshDiskSpace()
                if searchResults.isEmpty {
                    searchHuggingFace()
                }
            }
        }
    }


    // MARK: - Subviews & Actions

    private var visibleModels: [SupportedAudioModel] {
        modelManager.supportedModels.filter { model in
            modelManager.isUserImportedModel(model)
                || modelManager.isModelDownloaded(model)
        }
    }

    private var modelLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MODEL LIBRARY")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .tracking(1.0)

                Spacer()

                Text("LiteRT-LM Runtime")
                    .font(.caption2)
                    .foregroundColor(Theme.edgeBlue)
            }

            ForEach(visibleModels) { model in
                modelCard(for: model)
            }
        }
    }

    private var huggingFaceSearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SEARCH HUGGING FACE")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .tracking(1.0)

            HStack(spacing: 8) {
                TextField("Repository or model name", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onSubmit { searchHuggingFace() }

                Button(action: searchHuggingFace) {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Only audio-capable repositories that explicitly declare the LiteRT-LM conversation runtime can be imported. A .litertlm filename by itself is not enough.")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("VibeVoice · ~1.85 GiB") {
                    searchQuery = "VibeVoice-ASR-BitNet"
                    searchHuggingFace()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Gemma 3n · Multilingual") {
                    searchQuery = "gemma-3n litert-lm"
                    searchHuggingFace()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ForEach(searchResults, id: \.modelId) { report in
                searchResultCard(report)
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private func searchResultCard(_ report: ModelCompatibilityReport) -> some View {
        let importedModel = modelManager.supportedModels.first { $0.id == report.modelId }
        let state = modelManager.state(for: report.modelId)
        let progress = modelManager.downloadProgresses[report.modelId]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.modelId)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if let filename = report.modelFilename {
                        Text(filename)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(searchResultStatus(report: report, state: state, progress: progress))
                    .font(.caption2)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundColor(searchResultStatusColor(report: report, state: state))
            }

            if let fraction = state.downloadFraction {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                        .tint(Theme.edgeBlue)

                    HStack {
                        Text(progress?.formattedBytesTransfer ?? "Waiting for data…")
                        Spacer()
                        Text(progress?.formattedPercent ?? "\(Int((fraction * 100).rounded()))%")
                            .fontWeight(.bold)
                            .foregroundColor(Theme.edgeBlue)
                    }
                    .font(.caption2)
                    .monospacedDigit()
                }
            }

            HStack {
                if let bytes = report.fileSizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if report.isCompatible && !state.isDownloading && !state.isDownloaded {
                    Button(importedModel == nil ? "Add & Download" : "Download") {
                        if let importedModel {
                            handleDownload(importedModel)
                        } else {
                            importAndDownload(report)
                        }
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if state.isDownloaded {
                    Text(state.isActive ? "Active" : "Installed")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(Theme.successGreen)
                }
            }

            if !report.isCompatible {
                Text(report.diagnosticReasons.joined(separator: " "))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func searchResultStatus(
        report: ModelCompatibilityReport,
        state: ModelState,
        progress: DownloadProgress?
    ) -> String {
        switch state {
        case .downloading(let fraction):
            let percent = progress?.formattedPercent ?? "\(Int((fraction * 100).rounded()))%"
            return "DOWNLOADING \(percent)"
        case .loading:
            return "LOADING"
        case .ready:
            return "READY"
        case .active:
            return "ACTIVE"
        case .error:
            return "ERROR"
        case .unsupported:
            return "UNSUPPORTED"
        case .notDownloaded:
            return report.isCompatible ? "COMPATIBLE" : "UNSUPPORTED"
        }
    }

    private func searchResultStatusColor(report: ModelCompatibilityReport, state: ModelState) -> Color {
        switch state {
        case .downloading:
            return Theme.edgeBlue
        case .loading:
            return Theme.processingAmber
        case .ready, .active:
            return Theme.successGreen
        case .error:
            return .red
        case .unsupported:
            return .red
        case .notDownloaded:
            return report.isCompatible ? Theme.successGreen : .red
        }
    }

    private func searchHuggingFace() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchResults = []
        Task {
            defer { isSearching = false }
            do {
                let token = appConfig.huggingFaceToken.isEmpty ? nil : appConfig.huggingFaceToken
                searchResults = try await searchService.searchAudioModels(
                    query: query,
                    bearerToken: token
                )
                if searchResults.isEmpty {
                    alertMessage = "No Hugging Face repositories matched this search."
                    showAlert = true
                }
            } catch {
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }

    private func importAndDownload(_ report: ModelCompatibilityReport) {
        Task {
            do {
                let model = try modelManager.addDiscoveredModel(report)
                let token = appConfig.huggingFaceToken.isEmpty ? nil : appConfig.huggingFaceToken
                try await modelManager.downloadModel(model, bearerToken: token)
            } catch {
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }

    private func modelCard(for model: SupportedAudioModel) -> some View {
        ModelCardView(
            model: model,
            state: modelManager.state(for: model.id),
            progress: modelManager.downloadProgresses[model.id],
            onDownload: { handleDownload(model) },
            onPause: { modelManager.pauseDownload(modelId: model.id) },
            onCancel: { modelManager.cancelDownload(modelId: model.id) },
            onActivate: { handleActivate(model) },
            onDelete: { handleDelete(model) }
        )
    }

    private func handleDownload(_ model: SupportedAudioModel) {
        Task {
            do {
                let token = appConfig.huggingFaceToken.isEmpty ? nil : appConfig.huggingFaceToken
                try await modelManager.downloadModel(model, bearerToken: token)
            } catch {
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }

    private func handleActivate(_ model: SupportedAudioModel) {
        do {
            try modelManager.setActiveModel(id: model.id)
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func handleDelete(_ model: SupportedAudioModel) {
        do {
            try modelManager.deleteModel(id: model.id)
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    // MARK: - Subviews

    private var storageOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Device Storage", systemImage: "internaldrive.fill")
                    .font(.headline)

                Spacer()

                Text("\(modelManager.totalModelsSizeFormatted) used by models")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Custom multi-segment bar
            GeometryReader { geo in
                let total = max(1, Double(modelManager.totalDiskSpaceBytes))
                let modelsFraction = min(1.0, Double(modelManager.totalModelsSizeOnDiskBytes) / total)
                let freeFraction = min(1.0, Double(modelManager.availableDiskSpaceBytes) / total)
                let systemFraction = max(0, 1.0 - modelsFraction - freeFraction)

                HStack(spacing: 2) {
                    Rectangle()
                        .fill(Theme.edgeBlue)
                        .frame(width: max(4, geo.size.width * CGFloat(modelsFraction)))

                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: max(4, geo.size.width * CGFloat(systemFraction)))

                    Rectangle()
                        .fill(Theme.successGreen.opacity(0.6))
                        .frame(width: max(4, geo.size.width * CGFloat(freeFraction)))
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)

            HStack {
                HStack(spacing: 4) {
                    Circle().fill(Theme.edgeBlue).frame(width: 8, height: 8)
                    Text("Models: \(modelManager.totalModelsSizeFormatted)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle().fill(Theme.successGreen.opacity(0.6)).frame(width: 8, height: 8)
                    Text("Free: \(modelManager.availableStorageFormatted)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var appleNativeSpeechCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Apple Native Speech")
                            .font(.headline)

                        Text("BUILT-IN")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(Theme.successGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.successGreen.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text("On-device Apple Neural Engine recognition. Zero download required.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if modelManager.activeModelId == "apple-native-speech" || (modelManager.activeModelId == nil && modelManager.downloadedModels.isEmpty) {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(Theme.successGreen)
                } else {
                    Button("Switch") {
                        do {
                            try modelManager.setActiveModel(id: "apple-native-speech")
                        } catch {
                            alertMessage = error.localizedDescription
                            showAlert = true
                        }
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var architecturalGuaranteeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundColor(Theme.successGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text("Zero Bundled Weights Guarantee")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("All LLM weights are downloaded on demand from Hugging Face. The app bundle contains strictly code and runtime bindings (0 MB weights).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var hfTokenSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("hf_...", text: $appConfig.huggingFaceToken)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Hugging Face User Access Token")
                } footer: {
                    Text("Required to download gated models such as Google Gemma 3n and Gemma 4 from the Hugging Face Hub.")
                }

                Section {
                    Link(destination: URL(string: "https://huggingface.co/settings/tokens")!) {
                        Label("Generate Access Token on Hugging Face", systemImage: "arrow.up.right")
                    }
                }
            }
            .navigationTitle("Hugging Face Access")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingTokenSheet = false
                    }
                }
            }
        }
    }
}
