//
//  AppConfig.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Manages user settings, Cloudflare Worker configuration, local cleanup toggles,
//  and Hugging Face access credentials with persistent UserDefaults storage.
//

import Foundation
import SwiftUI
import Combine

/// Central application configuration and preferences store.
@MainActor
public final class AppConfig: ObservableObject {

    public static let shared = AppConfig()

    // MARK: - UserDefaults Storage Keys

    private enum Keys {
        static let cloudflareURL = "edge_eloquent.cf_worker_url"
        static let cloudflareToken = "edge_eloquent.cf_token"
        static let isLocalCleanupEnabled = "edge_eloquent.enable_local_cleanup"
        static let isCloudflareEnhancementEnabled = "edge_eloquent.enable_cf_enhancement"
        static let enhancementMode = "edge_eloquent.cf_enhancement_mode"
        static let enableWebSearch = "edge_eloquent.enable_web_search"
        static let requestTimeout = "edge_eloquent.cf_timeout"
        static let huggingFaceToken = "edge_eloquent.hf_access_token"
        static let autoCopyToClipboard = "edge_eloquent.auto_copy_clipboard"
    }

    // MARK: - Defaults

    public static let defaultCloudflareURL = "https://edge-eloquent-worker.workers.dev/api/enhance"
    public static let defaultTimeout: Double = 15.0

    // MARK: - Published Properties

    @Published public var cloudflareWorkerURL: String {
        didSet { UserDefaults.standard.set(cloudflareWorkerURL, forKey: Keys.cloudflareURL) }
    }

    @Published public var cloudflareAPIToken: String {
        didSet { UserDefaults.standard.set(cloudflareAPIToken, forKey: Keys.cloudflareToken) }
    }

    @Published public var isLocalCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(isLocalCleanupEnabled, forKey: Keys.isLocalCleanupEnabled) }
    }

    @Published public var isCloudflareEnhancementEnabled: Bool {
        didSet { UserDefaults.standard.set(isCloudflareEnhancementEnabled, forKey: Keys.isCloudflareEnhancementEnabled) }
    }

    @Published public var enhancementMode: EnhancementMode {
        didSet { UserDefaults.standard.set(enhancementMode.rawValue, forKey: Keys.enhancementMode) }
    }

    @Published public var enableWebSearch: Bool {
        didSet { UserDefaults.standard.set(enableWebSearch, forKey: Keys.enableWebSearch) }
    }

    @Published public var requestTimeout: Double {
        didSet { UserDefaults.standard.set(requestTimeout, forKey: Keys.requestTimeout) }
    }

    @Published public var huggingFaceToken: String {
        didSet { UserDefaults.standard.set(huggingFaceToken, forKey: Keys.huggingFaceToken) }
    }

    @Published public var autoCopyToClipboard: Bool {
        didSet { UserDefaults.standard.set(autoCopyToClipboard, forKey: Keys.autoCopyToClipboard) }
    }

    // MARK: - Initialization

    public init() {
        let defaults = UserDefaults.standard

        self.cloudflareWorkerURL = defaults.string(forKey: Keys.cloudflareURL) ?? Self.defaultCloudflareURL
        self.cloudflareAPIToken = defaults.string(forKey: Keys.cloudflareToken) ?? ""
        self.isLocalCleanupEnabled = defaults.object(forKey: Keys.isLocalCleanupEnabled) as? Bool ?? true
        self.isCloudflareEnhancementEnabled = defaults.object(forKey: Keys.isCloudflareEnhancementEnabled) as? Bool ?? true

        let rawMode = defaults.string(forKey: Keys.enhancementMode) ?? EnhancementMode.standard.rawValue
        self.enhancementMode = EnhancementMode(rawValue: rawMode) ?? .standard

        self.enableWebSearch = defaults.object(forKey: Keys.enableWebSearch) as? Bool ?? true
        self.requestTimeout = defaults.object(forKey: Keys.requestTimeout) as? Double ?? Self.defaultTimeout
        self.huggingFaceToken = defaults.string(forKey: Keys.huggingFaceToken) ?? ""
        self.autoCopyToClipboard = defaults.object(forKey: Keys.autoCopyToClipboard) as? Bool ?? false
    }

    // MARK: - Helper Methods

    /// Validates and returns the endpoint URL if syntactically valid.
    public var resolvedCloudflareURL: URL? {
        let trimmed = cloudflareWorkerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
    }

    /// Resets all settings to their factory defaults.
    public func resetToDefaults() {
        cloudflareWorkerURL = Self.defaultCloudflareURL
        cloudflareAPIToken = ""
        isLocalCleanupEnabled = true
        isCloudflareEnhancementEnabled = true
        enhancementMode = .standard
        enableWebSearch = true
        requestTimeout = Self.defaultTimeout
        huggingFaceToken = ""
        autoCopyToClipboard = false
    }
}
