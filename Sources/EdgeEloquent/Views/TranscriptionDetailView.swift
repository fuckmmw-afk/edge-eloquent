//
//  TranscriptionDetailView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Presents full transcription details, comparison between raw and enhanced text, and export options.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Detailed inspection view for a saved transcription record.
@MainActor
public struct TranscriptionDetailView: View {

    public let record: TranscriptionRecord
    public let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingRawComparison: Bool = false
    @State private var copied: Bool = false

    public init(record: TranscriptionRecord, onDelete: @escaping () -> Void) {
        self.record = record
        self.onDelete = onDelete
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // Header Metadata Card
                metadataCard

                // Primary Text Card
                primaryTextCard

                // Raw vs Enhanced Comparison Toggle (if different)
                if record.isEnhanced && record.cleanTranscript != record.finalText {
                    comparisonCard
                }

                // Delete Action
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("Delete Transcription", systemImage: "trash")
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.standardCornerRadius))
                }
                .padding(.top, 8)
            }
            .padding(Theme.standardPadding)
        }
        .background(Theme.surfaceBackground)
        .navigationTitle("Dictation Detail")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
            #else
            ToolbarItem(placement: .automatic) {
            #endif
                Button {
                    copyText(record.displayText)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundColor(copied ? Theme.successGreen : Theme.edgeBlue)
                }
            }
        }
    }

    // MARK: - Subviews

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(formattedDate(record.date), systemImage: "calendar")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Label(record.durationLabel, systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text(record.modelUsed.isEmpty ? "On-Device Engine" : record.modelUsed)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())

                if record.isEnhanced {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text("Cloudflare AI Enhanced")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(Theme.edgeBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.edgeBlue.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var primaryTextCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(record.isEnhanced ? "FINAL ENHANCED PROSE" : "TRANSCRIPT")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(record.isEnhanced ? Theme.edgeBlue : .secondary)
                    .tracking(1.0)

                Spacer()

                Button {
                    copyText(record.displayText)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.edgeBlue)
                }
            }

            Text(record.displayText)
                .font(.system(.body, design: .rounded))
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var comparisonCard: some View {
        DisclosureGroup(isExpanded: $showingRawComparison) {
            VStack(alignment: .leading, spacing: 8) {
                Text(record.cleanTranscript)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
        } label: {
            Label("Raw Cleaned Speech (Pre-Cloudflare)", systemImage: "text.quote")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    // MARK: - Helpers

    private func copyText(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copied = false
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
