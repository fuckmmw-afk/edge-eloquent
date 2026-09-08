//
//  HistoryView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Displays local past dictation records with search, details inspection, and swipe deletion.
//

import SwiftUI

/// Past dictation history list view stored strictly on-device in local sandbox storage.
public struct HistoryView: View {

    @ObservedObject public var historyStore: TranscriptionHistoryStore

    @State private var searchText: String = ""
    @State private var showingClearConfirmation: Bool = false

    public init(historyStore: TranscriptionHistoryStore = .shared) {
        self.historyStore = historyStore
    }

    private var filteredRecords: [TranscriptionRecord] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return historyStore.records
        }
        return historyStore.records.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchText) ||
            $0.modelUsed.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if historyStore.records.isEmpty {
                    emptyHistoryView
                } else {
                    List {
                        ForEach(filteredRecords) { record in
                            NavigationLink {
                                TranscriptionDetailView(record: record) {
                                    historyStore.deleteRecord(id: record.id)
                                }
                            } label: {
                                historyRow(for: record)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                        .onDelete(perform: deleteRecords)
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Search past dictations...")
                }
            }
            .background(Theme.surfaceBackground)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !historyStore.records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showingClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear Dictation History?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All Records", role: .destructive) {
                    historyStore.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all transcription records stored on this device.")
            }
        }
    }

    // MARK: - Subviews

    private var emptyHistoryView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Dictations Yet")
                .font(.headline)
                .foregroundColor(.primary)

            Text("Your past dictations will appear here. Audio never leaves your device, and records are stored strictly in local sandbox storage.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func historyRow(for record: TranscriptionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header metadata
            HStack {
                Text(formattedRelativeDate(record.date))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                Text(record.durationLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if record.isEnhanced {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                        Text("AI")
                            .font(.caption2)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(Theme.edgeBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.edgeBlue.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            // Transcript excerpt
            Text(record.displayText)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // Model badge
            HStack {
                Text(record.modelUsed.isEmpty ? "On-Device Engine" : record.modelUsed)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())

                Spacer()
            }
        }
        .padding(Theme.standardPadding)
        .edgeCardStyle()
    }

    // MARK: - Actions & Helpers

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            let record = filteredRecords[index]
            historyStore.deleteRecord(id: record.id)
        }
    }

    private func formattedRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
