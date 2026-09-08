//
//  ContentView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Root navigation interface hosting Dictation, History, Models, and Settings.
//

import SwiftUI

/// Main container providing bottom tab navigation across the four primary screens:
/// 1. Dictation (Minimalist Home)
/// 2. History (Sandbox Local Records)
/// 3. Models (Hugging Face Download & Lifecycle Manager)
/// 4. Settings (Cloudflare Endpoint & Local Cleanup)
public struct ContentView: View {

    @StateObject private var appConfig = AppConfig.shared
    @StateObject private var historyStore = TranscriptionHistoryStore.shared
    @StateObject private var modelManager = ModelManager()
    @StateObject private var coordinator: DictationCoordinator

    @State private var selectedTab: Int = 0

    public init() {
        let config = AppConfig.shared
        let store = TranscriptionHistoryStore.shared
        let manager = ModelManager()
        _appConfig = StateObject(wrappedValue: config)
        _historyStore = StateObject(wrappedValue: store)
        _modelManager = StateObject(wrappedValue: manager)
        _coordinator = StateObject(wrappedValue: DictationCoordinator(
            modelManager: manager,
            historyStore: store,
            appConfig: config
        ))
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            HomeRecordingView(
                coordinator: coordinator,
                modelManager: modelManager,
                appConfig: appConfig
            )
            .tabItem {
                Label("Dictation", systemImage: "mic.fill")
            }
            .tag(0)

            HistoryView(historyStore: historyStore)
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }
                .tag(1)

            ModelManagerView(
                modelManager: modelManager,
                appConfig: appConfig
            )
            .tabItem {
                Label("Models", systemImage: "cpu")
            }
            .tag(2)

            SettingsView(appConfig: appConfig)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .tint(Theme.edgeBlue)
    }
}
