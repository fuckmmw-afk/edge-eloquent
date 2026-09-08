//
//  ModelCardView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Renders an individual audio-capable model card with download controls, progress, and activation actions.
//

import SwiftUI

/// Card view representing a supported edge speech model with download, activation, and storage actions.
public struct ModelCardView: View {

    public let model: SupportedAudioModel
    public let state: ModelState
    public let progress: DownloadProgress?
    public let onDownload: () -> Void
    public let onPause: () -> Void
    public let onCancel: () -> Void
    public let onActivate: () -> Void
    public let onDelete: () -> Void

    @State private var showDeleteConfirmation: Bool = false

    public init(
        model: SupportedAudioModel,
        state: ModelState,
        progress: DownloadProgress? = nil,
        onDownload: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.model = model
        self.state = state
        self.progress = progress
        self.onDownload = onDownload
        self.onPause = onPause
        self.onCancel = onCancel
        self.onActivate = onActivate
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Title & Status Badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(model.hfRepo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                statusBadge
            }

            // Description
            Text(model.modelDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Metadata Chips
            HStack(spacing: 8) {
                specChip(icon: "memorychip", title: model.minRAMDescription)
                specChip(icon: "internaldrive", title: model.formattedExpectedSize)
                specChip(icon: "text.word.spacing", title: "\(model.contextWindowTokens / 1000)K ctx")

                if model.supportsThinking {
                    specChip(icon: "brain.head.profile", title: "Thinking")
                }
            }

            // Download Progress Bar (when downloading)
            if state.isDownloading, let p = progress {
                VStack(spacing: 6) {
                    ProgressView(value: p.fractionCompleted)
                        .tint(Theme.edgeBlue)

                    HStack {
                        Text(p.formattedBytesTransfer)
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(p.formattedSpeed)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(Theme.edgeBlue)
                    }
                }
                .padding(.vertical, 4)
            }

            // Actions row
            HStack {
                actionButtons

                Spacer()

                if state.isDownloaded && !state.isActive {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundColor(.red.opacity(0.8))
                            .padding(8)
                            .background(Color.red.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .confirmationDialog(
                        "Delete \(model.name)?",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Model (\(model.formattedExpectedSize))", role: .destructive) {
                            onDelete()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will remove the downloaded weights from your device. You can re-download them at any time.")
                    }
                }
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .active:
            HStack(spacing: 4) {
                Circle().fill(Theme.successGreen).frame(width: 8, height: 8)
                Text("ACTIVE")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(Theme.successGreen)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.successGreen.opacity(0.12))
            .clipShape(Capsule())

        case .ready:
            Text("READY")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())

        case .downloading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("DOWNLOADING")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.edgeBlue)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.edgeBlue.opacity(0.12))
            .clipShape(Capsule())

        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("LOADING")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.processingAmber)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.processingAmber.opacity(0.12))
            .clipShape(Capsule())

        case .notDownloaded:
            Text("NOT INSTALLED")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())

        case .error(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text("ERROR")
                    .font(.caption2)
                    .fontWeight(.bold)
            }
            .foregroundColor(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.12))
            .clipShape(Capsule())
            .help(msg)
        }
    }

    private func specChip(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(title)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .active:
            Label("Active Model", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(Theme.successGreen)

        case .ready:
            Button(action: onActivate) {
                Label("Activate", systemImage: "bolt.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.edgeBlue)
                    .clipShape(Capsule())
            }

        case .downloading:
            HStack(spacing: 8) {
                Button(action: onPause) {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

        case .notDownloaded, .error:
            Button(action: onDownload) {
                Label("Download (\(model.formattedExpectedSize))", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.edgeBlue)
                    .clipShape(Capsule())
            }

        case .loading:
            Text("Preparing weights...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
