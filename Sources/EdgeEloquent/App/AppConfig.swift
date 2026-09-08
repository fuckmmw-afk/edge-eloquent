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

    public static let defaultCloudflareURL = ""
    public static let defaultTimeout: Double = 15.0

    // MARK: - Published Properties

    @Published public var cloudflareWorkerURL: String {
        didSet { UserDefaults.standard.set(cloudflareWorkerURL, forKey: Keys.cloudflareURL) }
    }

    @Published public var cloudflareAPIToken: String {
        didSet { SecureCredentialStore.write(cloudflareAPIToken, account: Keys.cloudflareToken) }
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
        didSet { SecureCredentialStore.write(huggingFaceToken, account: Keys.huggingFaceToken) }
    }

    @Published public var autoCopyToClipboard: Bool {
        didSet { UserDefaults.standard.set(autoCopyToClipboard, forKey: Keys.autoCopyToClipboard) }
    }

    // MARK: - Initialization

    public init() {
        let defaults = UserDefaults.standard

        self.cloudflareWorkerURL = defaults.string(forKey: Keys.cloudflareURL) ?? Self.defaultCloudflareURL
        let legacyCloudflareToken = defaults.string(forKey: Keys.cloudflareToken) ?? ""
        let keychainCloudflareToken = SecureCredentialStore.read(account: Keys.cloudflareToken)
        self.cloudflareAPIToken = keychainCloudflareToken.isEmpty ? legacyCloudflareToken : keychainCloudflareToken
        if keychainCloudflareToken.isEmpty, !legacyCloudflareToken.isEmpty {
            SecureCredentialStore.write(legacyCloudflareToken, account: Keys.cloudflareToken)
        }
        defaults.removeObject(forKey: Keys.cloudflareToken)
        self.isLocalCleanupEnabled = defaults.object(forKey: Keys.isLocalCleanupEnabled) as? Bool ?? true
        self.isCloudflareEnhancementEnabled = defaults.object(forKey: Keys.isCloudflareEnhancementEnabled) as? Bool ?? false

        let rawMode = defaults.string(forKey: Keys.enhancementMode) ?? EnhancementMode.standard.rawValue
        self.enhancementMode = EnhancementMode(rawValue: rawMode) ?? .standard

        self.enableWebSearch = defaults.object(forKey: Keys.enableWebSearch) as? Bool ?? false
        self.requestTimeout = defaults.object(forKey: Keys.requestTimeout) as? Double ?? Self.defaultTimeout
        let legacyHuggingFaceToken = defaults.string(forKey: Keys.huggingFaceToken) ?? ""
        let keychainHuggingFaceToken = SecureCredentialStore.read(account: Keys.huggingFaceToken)
        self.huggingFaceToken = keychainHuggingFaceToken.isEmpty ? legacyHuggingFaceToken : keychainHuggingFaceToken
        if keychainHuggingFaceToken.isEmpty, !legacyHuggingFaceToken.isEmpty {
            SecureCredentialStore.write(legacyHuggingFaceToken, account: Keys.huggingFaceToken)
        }
        defaults.removeObject(forKey: Keys.huggingFaceToken)
        self.autoCopyToClipboard = defaults.object(forKey: Keys.autoCopyToClipboard) as? Bool ?? false

        // Remove the historical placeholder endpoint, which was never a deployed Worker.
        if self.cloudflareWorkerURL == "https://edge-eloquent-worker.workers.dev/api/enhance" {
            self.cloudflareWorkerURL = ""
            self.isCloudflareEnhancementEnabled = false
        }
    }

    // MARK: - Helper Methods

    /// Validates and returns the endpoint URL if syntactically valid.
    public var resolvedCloudflareURL: URL? {
        let trimmed = cloudflareWorkerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }

    /// Resets all settings to their factory defaults.
    public func resetToDefaults() {
        cloudflareWorkerURL = Self.defaultCloudflareURL
        cloudflareAPIToken = ""
        isLocalCleanupEnabled = true
        isCloudflareEnhancementEnabled = false
        enhancementMode = .standard
        enableWebSearch = false
        requestTimeout = Self.defaultTimeout
        huggingFaceToken = ""
        autoCopyToClipboard = false
    }
}
