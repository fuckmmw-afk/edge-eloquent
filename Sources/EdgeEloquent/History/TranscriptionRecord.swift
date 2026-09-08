// Sources/EdgeEloquent/History/TranscriptionRecord.swift
// Edge Eloquent - On-Device Audio Intelligence
import Foundation

/// A persistent record of a single transcription session.
///
/// Contains the raw transcribed audio text, optional model enhancement result,
/// execution metadata, and timestamps.
///
/// Strictly stored locally on the device with zero cloud sync, no accounts, and no export telemetry.
public struct TranscriptionRecord: Identifiable, Codable, Equatable, Hashable, Sendable {

    /// Unique identifier for this transcription record.
    public let id: UUID

    /// Timestamp when the transcription was performed.
    public let date: Date

    /// The raw transcription text produced by the acoustic/speech-to-text model.
    public var cleanTranscript: String

    /// The final, post-processed or user-edited text (enhanced or identical to clean transcript).
    public var finalText: String

    /// Identifier of the model used during transcription or refinement (e.g. "gemma-3n-E2B-it", "whisperKit").
    public var modelUsed: String

    /// Total audio duration in seconds.
    public var durationSeconds: Double

    /// Indicates whether the transcript underwent an AI enhancement / polishing pass.
    public var isEnhanced: Bool

    /// Creates a new transcription record.
    /// - Parameters:
    ///   - id: Unique identifier (defaults to a new UUID).
    ///   - date: Timestamp (defaults to the current date).
    ///   - cleanTranscript: Raw transcribed speech text.
    ///   - finalText: Final polished or edited text.
    ///   - modelUsed: Model identifier string (optional metadata, defaults to empty string).
    ///   - durationSeconds: Audio duration in seconds (optional metadata, defaults to 0.0).
    ///   - isEnhanced: Whether enhancement was applied (defaults to false).
    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        cleanTranscript: String,
        finalText: String,
        modelUsed: String = "",
        durationSeconds: Double = 0.0,
        isEnhanced: Bool = false
    ) {
        self.id = id
        self.date = date
        self.cleanTranscript = cleanTranscript
        self.finalText = finalText
        self.modelUsed = modelUsed
        self.durationSeconds = durationSeconds
        self.isEnhanced = isEnhanced
    }

    // MARK: - Convenience Helpers

    /// Formatted duration string for display (e.g., "0s", "12s", "1m 05s", "10m 30s").
    public var durationLabel: String {
        let totalSeconds = max(0, Int(durationSeconds.rounded()))
        guard totalSeconds >= 60 else { return "\(totalSeconds)s" }
        return String(format: "%dm %02ds", totalSeconds / 60, totalSeconds % 60)
    }

    /// The preferred text for UI display: `finalText` if non-empty, otherwise `cleanTranscript`.
    public var displayText: String {
        finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cleanTranscript : finalText
    }

    /// Returns a copy of this record with an updated final text.
    public func withFinalText(_ newText: String, isEnhanced: Bool? = nil) -> TranscriptionRecord {
        var copy = self
        copy.finalText = newText
        if let isEnhanced = isEnhanced {
            copy.isEnhanced = isEnhanced
        }
        return copy
    }
}
