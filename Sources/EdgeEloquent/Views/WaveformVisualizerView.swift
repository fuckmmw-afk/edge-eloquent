//
//  WaveformVisualizerView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Renders dynamic, audio-reactive waveform bars reflecting real-time RMS microphone amplitude.
//

import SwiftUI

/// Audio-reactive waveform bar visualizer with duration counter.
public struct WaveformVisualizerView: View {

    public let levels: [Float]
    public let isRecording: Bool
    public let duration: TimeInterval

    private let barCount = 32

    public init(
        levels: [Float],
        isRecording: Bool,
        duration: TimeInterval
    ) {
        self.levels = levels
        self.isRecording = isRecording
        self.duration = duration
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Live elapsed duration
            if isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.recordingRed)
                        .frame(width: 8, height: 8)

                    Text(formattedDuration(duration))
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Theme.cardBackground)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.subtleBorder, lineWidth: 1))
                .transition(.scale.combined(with: .opacity))
            }

            // Audio reactive bars
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barGradient(for: index))
                        .frame(width: 3.5, height: barHeight(for: index))
                        .animation(.linear(duration: 0.08), value: normalizedLevel(for: index))
                }
            }
            .frame(height: 48)
            .padding(.horizontal, Theme.standardPadding)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Level Mapping

    private func normalizedLevel(for index: Int) -> Float {
        guard isRecording else { return 0.08 }
        guard !levels.isEmpty else { return 0.1 }

        // Sample levels across the bar count
        let step = max(1, levels.count / barCount)
        let sampledIndex = min(levels.count - 1, index * step)
        let level = levels[sampledIndex]
        return max(0.08, min(1.0, level))
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(normalizedLevel(for: index))
        let minHeight: CGFloat = 4.0
        let maxHeight: CGFloat = 44.0
        return minHeight + (maxHeight - minHeight) * level
    }

    private func barGradient(for index: Int) -> LinearGradient {
        if isRecording {
            return LinearGradient(
                colors: [Theme.recordingRed, Theme.recordingRed.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [Color.secondary.opacity(0.3), Color.secondary.opacity(0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let tenths = Int((interval.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}
