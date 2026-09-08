//
//  SettingsView.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Settings view managing Cloudflare Worker endpoint, cleanup options, and system attributions.
//

import SwiftUI

/// App settings and configuration interface.
public struct SettingsView: View {

    @ObservedObject public var appConfig: AppConfig

    @State private var testingConnection: Bool = false
    @State private var connectionStatus: ConnectionStatus? = nil
    @State private var showingResetConfirmation: Bool = false

    private enum ConnectionStatus {
        case success
        case failure(String)
    }

    public init(appConfig: AppConfig = .shared) {
        self.appConfig = appConfig
    }

    public var body: some View {
        NavigationStack {
            Form {
                // Section 1: Cloudflare Edge Post-Processor
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Worker Endpoint URL")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("https://...", text: $appConfig.cloudflareWorkerURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Authorization Token (Optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        SecureField("Bearer token...", text: $appConfig.cloudflareAPIToken)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    // Test connection button
                    HStack {
                        Button {
                            testWorkerConnection()
                        } label: {
                            if testingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Test Endpoint Health", systemImage: "network")
                            }
                        }
                        .disabled(testingConnection || appConfig.resolvedCloudflareURL == nil)

                        Spacer()

                        if let status = connectionStatus {
                            switch status {
                            case .success:
                                Label("Online", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(Theme.successGreen)
                            case .failure:
                                Label("Offline", systemImage: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    Toggle("Enable Cloudflare Enhancement", isOn: $appConfig.isCloudflareEnhancementEnabled)

                    if appConfig.isCloudflareEnhancementEnabled {
                        Picker("Enhancement Mode", selection: $appConfig.enhancementMode) {
                            ForEach(EnhancementMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        Toggle("Web Search Citations", isOn: $appConfig.enableWebSearch)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Request Timeout")
                                Spacer()
                                Text("\(Int(appConfig.requestTimeout))s")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $appConfig.requestTimeout, in: 5...30, step: 1)
                        }
                    }
                } header: {
                    Text("Cloudflare Edge Enhancement")
                } footer: {
                    Text("Enhances punctuation, formatting, and adds factual citations. Strictly text-only; audio buffers NEVER leave the device.")
                }

                // Section 2: On-Device Processing
                Section {
                    Toggle("Local Speech Cleanup", isOn: $appConfig.isLocalCleanupEnabled)

                    Toggle("Auto-Copy to Clipboard", isOn: $appConfig.autoCopyToClipboard)
                } header: {
                    Text("On-Device Processing")
                } footer: {
                    Text("Local cleanup filters vocal fillers ('um', 'uh', 'like'), stutters, and immediate repetitions deterministically on-device.")
                }

                // Section 3: Attributions & Reset
                Section {
                    NavigationLink {
                        AboutAttributionView()
                    } label: {
                        Label("About & Attributions", systemImage: "info.circle")
                    }

                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset All Settings to Defaults", systemImage: "arrow.counterclockwise")
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Application Info")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Reset Settings?",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset to Defaults", role: .destructive) {
                    appConfig.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will restore default endpoint URLs, timeout values, and toggles.")
            }
        }
    }

    // MARK: - Connection Test

    private func testWorkerConnection() {
        guard let url = appConfig.resolvedCloudflareURL else { return }
        testingConnection = true
        connectionStatus = nil

        Task {
            let config = CloudflareConfiguration(
                endpointURL: url,
                apiToken: appConfig.cloudflareAPIToken.isEmpty ? nil : appConfig.cloudflareAPIToken,
                timeoutInterval: 5.0
            )
            let service = CloudflareBrainService(configuration: config)
            let online = await service.isAvailable

            await MainActor.run {
                self.testingConnection = false
                self.connectionStatus = online ? .success : .failure("Unavailable")
            }
        }
    }
}
