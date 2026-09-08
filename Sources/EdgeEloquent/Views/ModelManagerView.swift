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

                    // LiteRT Audio Models Section
                    gemmaModelsSection

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
            }
        }
    }


    // MARK: - Subviews & Actions

    private var gemmaModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ON-DEVICE GEMMA MODELS")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .tracking(1.0)

                Spacer()

                Text("LiteRT-LM Runtime")
                    .font(.caption2)
                    .foregroundColor(Theme.edgeBlue)
            }

            ForEach(modelManager.supportedModels) { model in
                modelCard(for: model)
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
                        UserDefaults.standard.set("apple-native-speech", forKey: ModelManager.activeModelUserDefaultsKey)
                        modelManager.refreshModelStates()
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
