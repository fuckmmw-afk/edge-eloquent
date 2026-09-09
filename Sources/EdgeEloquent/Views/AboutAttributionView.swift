//
//  AboutAttributionView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Attribution, licenses, and architecture credits to Google AI Edge Gallery and LiteRT-LM.
//

import SwiftUI

/// App attribution and license acknowledgments view.
@MainActor
public struct AboutAttributionView: View {

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Header brand card
                brandCard

                // Privacy Guarantees
                privacyCard

                // Google AI Edge Gallery Attribution
                googleEdgeGalleryCard

                // Open Source Components
                componentsCard

                // App info footer
                footerView
            }
            .padding(Theme.standardPadding)
        }
        .background(Theme.surfaceBackground)
        .navigationTitle("About & Attributions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Subviews

    private var brandCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(Theme.edgeBlue)

            Text("Edge Eloquent")
                .font(.title2)
                .fontWeight(.bold)

            Text("Minimalist On-Device Dictation & Audio Intelligence")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("Version 1.0.4 (Build 2026.09)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(Theme.successGreen)
                Text("Strict Audio Air-Gap Invariant")
                    .font(.headline)
            }

            Text("Your microphone audio is processed strictly on your Apple Silicon device using local neural network weights or Apple's native speech recognizer. Raw audio, PCM buffers, and WAV files NEVER leave the local device boundary.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineSpacing(4)
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var googleEdgeGalleryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundColor(Theme.edgeBlue)
                Text("Google AI Edge Architecture")
                    .font(.headline)
            }

            Text("Adapted from Google AI Edge Gallery (google-ai-edge/gallery) and Google's official LiteRT-LM runtime (google-ai-edge/LiteRT-LM).")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                linkRow(
                    title: "Google AI Edge Gallery",
                    subtitle: "github.com/google-ai-edge/gallery",
                    urlString: "https://github.com/google-ai-edge/gallery"
                )
                linkRow(
                    title: "LiteRT-LM Swift Runtime",
                    subtitle: "github.com/google-ai-edge/LiteRT-LM",
                    urlString: "https://github.com/google-ai-edge/LiteRT-LM"
                )
                linkRow(
                    title: "Google Gemma Models",
                    subtitle: "huggingface.co/google",
                    urlString: "https://huggingface.co/google"
                )
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private var componentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RUNTIME COMPONENTS")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .tracking(1.0)

            componentRow(name: "LiteRT-LM C++ / Swift FFI", role: "On-device Gemma 4 / 3n inference")
            componentRow(name: "Apple Silicon Metal MSL", role: "Autoregressive LLM GPU acceleration")
            componentRow(name: "ARM NEON Vectorization", role: "Conformer acoustic feature extraction")
            componentRow(name: "AVAudioEngine Pipeline", role: "16kHz mono low-latency tap capture")
            componentRow(name: "Cloudflare Workers AI", role: "Strictly text-only post-processing")
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    private func linkRow(title: String, subtitle: String, urlString: String) -> some View {
        Link(destination: URL(string: urlString)!) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func componentRow(name: String, role: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(role)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var footerView: some View {
        Text("Built with Apple SwiftUI. Strictly private on-device intelligence.")
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }
}
