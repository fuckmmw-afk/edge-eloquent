//
//  HomeRecordingView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Minimalist dictation interface matching Google AI Edge Gallery aesthetic.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Primary dictation screen providing live streaming transcription, waveform visualizer,
/// and post-stop processing card.
@MainActor
public struct HomeRecordingView: View {

    @ObservedObject public var coordinator: DictationCoordinator
    @ObservedObject public var modelManager: ModelManager
    @ObservedObject public var appConfig: AppConfig

    @State private var showingModelSheet: Bool = false
    @State private var copiedFeedback: Bool = false

    public init(
        coordinator: DictationCoordinator,
        modelManager: ModelManager
    ) {
        self.coordinator = coordinator
        self.modelManager = modelManager
        self.appConfig = .shared
    }

    public init(
        coordinator: DictationCoordinator,
        modelManager: ModelManager,
        appConfig: AppConfig
    ) {
        self.coordinator = coordinator
        self.modelManager = modelManager
        self.appConfig = appConfig
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.surfaceBackground
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    // Top Header: Active Model Pill & Status
                    headerBar

                    // Error Banner (if error occurred during capture or transcription)
                    if let errorMessage = coordinator.lastErrorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.subheadline)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recording Error")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.red)
                                Text(errorMessage)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                coordinator.lastErrorMessage = nil
                                coordinator.state = .idle
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                        }
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.2), lineWidth: 1))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Live Transcript Area
                    RealtimeTranscriptView(
                        finalizedText: coordinator.finalizedTranscript,
                        partialText: coordinator.realtimePartialTranscript,
                        isRecording: coordinator.state.isRecording,
                        placeholder: "Tap the record button below to begin on-device dictation..."
                    )

                    // Waveform / Audio Reactive Visualizer (active during recording)
                    WaveformVisualizerView(
                        levels: coordinator.liveWaveformLevels,
                        isRecording: coordinator.state.isRecording,
                        duration: coordinator.currentDuration
                    )

                    // Post-stop processing state & completed result card
                    if coordinator.state.isProcessing || coordinator.state.isCompleted {
                        postProcessingCard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    Spacer(minLength: 8)

                    // Primary Action Button [RECORD] / [STOP]
                    primaryActionButton
                        .padding(.bottom, Theme.largePadding)
                }
                .padding(.horizontal, Theme.standardPadding)
                .padding(.top, 8)
            }
            .navigationTitle("Dictation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showingModelSheet) {
                ModelManagerView(modelManager: modelManager, appConfig: appConfig)
            }
            .onAppear {
                coordinator.updateActiveEngineName()
            }
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            // Active model selector pill
            Button {
                showingModelSheet = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(modelStatusColor)
                        .frame(width: 8, height: 8)

                    Text(coordinator.activeEngineName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.cardBackground)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.subtleBorder, lineWidth: 1))
                .shadow(color: Theme.cardShadowColor, radius: 4, x: 0, y: 2)
            }

            Spacer()

            // Status indicator
            statusIndicator
        }
    }

    private var modelStatusColor: Color {
        if coordinator.state.isRecording {
            return Theme.recordingRed
        }
        if coordinator.state.isProcessing {
            return Theme.processingAmber
        }
        return Theme.successGreen
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch coordinator.state {
        case .idle:
            HStack(spacing: 4) {
                Image(systemName: "mic")
                    .font(.caption2)
                Text("Ready")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundColor(.secondary)

        case .recording:
            HStack(spacing: 4) {
                Circle()
                    .fill(Theme.recordingRed)
                    .frame(width: 6, height: 6)
                Text("Recording")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(Theme.recordingRed)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.recordingRed.opacity(0.12))
            .clipShape(Capsule())

        case .processing(let stage):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(stage.rawValue)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.processingAmber)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.processingAmber.opacity(0.12))
            .clipShape(Capsule())

        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                Text("Completed")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundColor(Theme.successGreen)

        case .error:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                Text("Error")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundColor(.red)
        }
    }

    private var postProcessingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator.state.isProcessing, case .processing(let stage) = coordinator.state {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.edgeBlue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.rawValue)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("Running on-device pipeline")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if let record = coordinator.activeRecord {
                HStack {
                    if record.isEnhanced {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                            Text("Cloudflare AI Enhanced")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        .foregroundColor(Theme.edgeBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.edgeBlue.opacity(0.12))
                        .clipShape(Capsule())
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                                .font(.caption2)
                            Text("Local Cleaned")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        .foregroundColor(Theme.successGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.successGreen.opacity(0.12))
                        .clipShape(Capsule())
                    }

                    Spacer()

                    Button {
                        coordinator.copyToClipboard(text: record.displayText)
                        copiedFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            copiedFeedback = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                            Text(copiedFeedback ? "Copied!" : "Copy")
                        }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(Theme.edgeBlue)
                    }

                    Button {
                        coordinator.clearResult()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }

                Text(record.displayText)
                    .font(.system(.body, design: .rounded))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var primaryActionButton: some View {
        Button {
            if coordinator.state.isRecording {
                coordinator.stopRecording()
            } else if !coordinator.state.isProcessing {
                coordinator.startRecording()
            }
        } label: {
            ZStack {
                // Pulsing outer ring during recording
                if coordinator.state.isRecording {
                    Circle()
                        .stroke(Theme.recordingRed.opacity(0.35), lineWidth: 6)
                        .frame(width: 88, height: 88)
                        .scaleEffect(1.15)
                        .animation(Theme.pulseAnimation, value: coordinator.state.isRecording)
                }

                // Main circular action surface
                Circle()
                    .fill(buttonBackgroundColor)
                    .frame(width: 76, height: 76)
                    .shadow(color: buttonShadowColor, radius: 10, x: 0, y: 5)

                // Icon inside button
                buttonIcon
            }
        }
        .disabled(coordinator.state.isProcessing)
        .accessibilityLabel(coordinator.state.isRecording ? "Stop Recording" : "Start Recording")
    }

    private var buttonBackgroundColor: Color {
        if coordinator.state.isRecording {
            return Theme.recordingRed
        }
        if coordinator.state.isProcessing {
            return Color.secondary.opacity(0.2)
        }
        return Theme.edgeBlue
    }

    private var buttonShadowColor: Color {
        if coordinator.state.isRecording {
            return Theme.recordingRed.opacity(0.4)
        }
        return Theme.edgeBlue.opacity(0.35)
    }

    @ViewBuilder
    private var buttonIcon: some View {
        if coordinator.state.isProcessing {
            ProgressView()
                .tint(.white)
        } else if coordinator.state.isRecording {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}
