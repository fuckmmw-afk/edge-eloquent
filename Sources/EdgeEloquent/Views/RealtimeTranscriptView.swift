//
//  RealtimeTranscriptView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Renders realtime streaming transcription tokens and finalized text with smooth autoscrolling.
//

import SwiftUI

/// Live transcription text display component featuring token highlighting and autoscrolling.
public struct RealtimeTranscriptView: View {

    public let finalizedText: String
    public let partialText: String
    public let isRecording: Bool
    public let placeholder: String

    @State private var isBlinkingCursor: Bool = false

    public init(
        finalizedText: String,
        partialText: String,
        isRecording: Bool,
        placeholder: String = "Tap the record button and begin speaking..."
    ) {
        self.finalizedText = finalizedText
        self.partialText = partialText
        self.isRecording = isRecording
        self.placeholder = placeholder
    }

    private var hasContent: Bool {
        !finalizedText.isEmpty || !partialText.isEmpty
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    if !hasContent {
                        emptyPlaceholderView
                    } else {
                        transcriptContent
                    }

                    // Invisible anchor view for autoscrolling
                    Color.clear
                        .frame(height: 1)
                        .id("bottomAnchor")
                }
                .padding(Theme.standardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: partialText) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: finalizedText) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
        .frame(minHeight: 180, maxHeight: .infinity)
        .edgeCardStyle()
    }

    // MARK: - Subviews

    private var emptyPlaceholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: isRecording ? "waveform.badge.mic" : "mic.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(isRecording ? Theme.recordingRed : .secondary.opacity(0.6))
                .symbolEffect(.pulse, isActive: isRecording)

            Text(isRecording ? "Listening for speech..." : placeholder)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header stats badge
            HStack {
                Text(isRecording ? "LIVE TRANSCRIPTION" : "TRANSCRIPT")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(isRecording ? Theme.recordingRed : .secondary)
                    .tracking(1.0)

                Spacer()

                Text("\(wordCount) words")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
            .padding(.bottom, 4)

            // Body text rendering
            Text(attributedTranscript)
                .font(.system(.body, design: .rounded))
                .lineSpacing(6)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)

            if isRecording {
                // Live typing indicator dot
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.recordingRed)
                        .frame(width: 6, height: 6)
                        .opacity(isBlinkingCursor ? 0.2 : 1.0)
                        .animation(Theme.pulseAnimation, value: isBlinkingCursor)
                        .onAppear { isBlinkingCursor = true }

                    Text("Streaming on-device")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Helpers

    private var wordCount: Int {
        let full = "\(finalizedText) \(partialText)"
        let words = full.split { $0.isWhitespace || $0.isNewline }
        return words.count
    }

    private var attributedTranscript: AttributedString {
        var string = AttributedString(finalizedText)
        string.foregroundColor = .primary

        if !partialText.isEmpty {
            var partialPart = AttributedString(finalizedText.isEmpty ? partialText : " \(partialText)")
            partialPart.foregroundColor = Theme.edgeBlue
            partialPart.inlinePresentationIntent = .stronglyEmphasized
            string.append(partialPart)
        }

        return string
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
        }
    }
}
