//
//  AudioSessionCoordinator.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Multimodal Speech Intelligence.
//  Coordinates AVAudioSession activation, permissions, system interruptions, and hardware route changes.
//

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Permission status enumeration for microphone access.
public enum AudioPermissionStatus: String, Sendable, Equatable {
    case undetermined
    case granted
    case denied
}

/// Lifecycle and activation state of the audio session.
public enum AudioSessionState: Sendable, Equatable {
    case idle
    case requestingPermission
    case permissionDenied
    case ready
    case recording
    case paused
    case interrupted
    case failed(String)
}

/// System interruption classifications.
public enum AudioInterruptionType: Sendable, Equatable {
    case began
    case ended(shouldResume: Bool)
}

/// Audio hardware routing change classifications.
public enum AudioRouteChangeReason: Sendable, Equatable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case routeConfigurationChange
    case unknown
}

/// Delegate protocol notifying listeners of session state, interruptions, and hardware routing shifts.
public protocol AudioSessionCoordinatorDelegate: AnyObject, Sendable {
    func audioSessionDidChangeState(_ coordinator: AudioSessionCoordinator, state: AudioSessionState)
    func audioSessionDidReceiveInterruption(_ coordinator: AudioSessionCoordinator, interruption: AudioInterruptionType)
    func audioSessionDidReceiveRouteChange(_ coordinator: AudioSessionCoordinator, reason: AudioRouteChangeReason, currentRoute: String)
    func audioSessionDidFail(_ coordinator: AudioSessionCoordinator, error: Error)
}

/// Coordinates system-wide AVAudioSession configuration, permissions, interruptions, and route changes.
public final class AudioSessionCoordinator: @unchecked Sendable {
    // MARK: - Properties

    private let stateLock = NSLock()
    private var _state: AudioSessionState = .idle
    private var isObservingNotifications: Bool = false

    /// Weak delegate for audio session events.
    public weak var delegate: AudioSessionCoordinatorDelegate?

    /// Optional callback invoked when an interruption begins.
    public var onInterruptionBegan: (@Sendable () -> Void)?

    /// Optional callback invoked when an interruption ends.
    public var onInterruptionEnded: (@Sendable (Bool) -> Void)?

    /// Current operational state of the session coordinator.
    public var state: AudioSessionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    /// Target sampling rate requested from hardware (default: 16,000 Hz).
    public let preferredSampleRate: Double

    /// Target I/O buffer duration in seconds (default: 0.02s / 20ms).
    public let preferredIOBufferDuration: TimeInterval

    // MARK: - Initialization

    /// Initializes a new AudioSessionCoordinator.
    ///
    /// - Parameters:
    ///   - preferredSampleRate: Hardware sampling rate hint in Hz (default: 16,000.0).
    ///   - preferredIOBufferDuration: Buffer duration in seconds (default: 0.02s).
    public init(
        preferredSampleRate: Double = 16000.0,
        preferredIOBufferDuration: TimeInterval = 0.02
    ) {
        self.preferredSampleRate = preferredSampleRate
        self.preferredIOBufferDuration = preferredIOBufferDuration
    }

    deinit {
        stopObservingNotifications()
    }

    // MARK: - Permission Handling

    /// Checks the current authorization status for microphone access.
    public func checkRecordPermission() -> AudioPermissionStatus {
        #if os(iOS) || os(visionOS)
        if #available(iOS 17.0, visionOS 1.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        }
        #else
        return .granted
        #endif
    }

    /// Requests recording permission from the user asynchronously.
    ///
    /// - Returns: Boolean indicating whether permission was granted.
    public func requestRecordPermission() async -> Bool {
        if ProcessInfo.processInfo.environment["CI"] != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            transitionState(to: .ready)
            return true
        }
        transitionState(to: .requestingPermission)

        #if os(iOS) || os(visionOS)
        let granted: Bool
        if #available(iOS 17.0, visionOS 1.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }

        if granted {
            transitionState(to: .ready)
        } else {
            transitionState(to: .permissionDenied)
        }
        return granted
        #else
        transitionState(to: .ready)
        return true
        #endif
    }

    // MARK: - Session Configuration & Activation

    /// Configures the shared AVAudioSession for spoken audio dictation.
    ///
    /// Category: `.playAndRecord`
    /// Mode: `.default` (preserves the raw microphone signal for model inference)
    /// Options: `[.duckOthers, .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]`
    public func configureSession() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()

        let options: AVAudioSession.CategoryOptions = [
            .duckOthers,
            .defaultToSpeaker,
            .allowBluetooth
        ]

        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: options
            )
        } catch {
            try session.setCategory(.playAndRecord, mode: .default)
        }

        try? session.setPreferredSampleRate(preferredSampleRate)
        try? session.setPreferredIOBufferDuration(preferredIOBufferDuration)

        startObservingNotifications()
        transitionState(to: .ready)
        #else
        transitionState(to: .ready)
        #endif
    }

    /// Activates the audio session for active recording.
    public func activateSession() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        transitionState(to: .recording)
    }

    /// Deactivates the audio session gracefully, notifying other apps they may resume audio.
    public func deactivateSession() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        transitionState(to: .ready)
    }

    /// Marks the session as actively recording.
    public func markRecording() {
        transitionState(to: .recording)
    }

    /// Marks the session as paused.
    public func markPaused() {
        transitionState(to: .paused)
    }

    /// Resets the session back to idle.
    public func reset() {
        transitionState(to: .idle)
    }

    // MARK: - Notification Observers

    private func startObservingNotifications() {
        guard !isObservingNotifications else { return }
        #if os(iOS) || os(visionOS)
        let center = NotificationCenter.default

        center.addObserver(
            self,
            selector: #selector(handleInterruption(notification:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        center.addObserver(
            self,
            selector: #selector(handleRouteChange(notification:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        #endif
        isObservingNotifications = true
    }

    private func stopObservingNotifications() {
        guard isObservingNotifications else { return }
        #if os(iOS) || os(visionOS)
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        #endif
        isObservingNotifications = false
    }

    // MARK: - Notification Handlers

    #if os(iOS) || os(visionOS)
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            transitionState(to: .interrupted)
            delegate?.audioSessionDidReceiveInterruption(self, interruption: .began)
            onInterruptionBegan?()

        case .ended:
            var shouldResume = false
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            }

            if shouldResume {
                transitionState(to: .ready)
            } else {
                transitionState(to: .idle)
            }

            delegate?.audioSessionDidReceiveInterruption(self, interruption: .ended(shouldResume: shouldResume))
            onInterruptionEnded?(shouldResume)

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let rawReason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        let reason: AudioRouteChangeReason
        switch rawReason {
        case .newDeviceAvailable:
            reason = .newDeviceAvailable
        case .oldDeviceUnavailable:
            reason = .oldDeviceUnavailable
        case .categoryChange:
            reason = .categoryChange
        case .override:
            reason = .override
        case .wakeFromSleep:
            reason = .wakeFromSleep
        case .routeConfigurationChange:
            reason = .routeConfigurationChange
        case .unknown:
            reason = .unknown
        case .noSuitableRouteForCategory:
            reason = .unknown
        @unknown default:
            reason = .unknown
        }

        let routeDescription = AVAudioSession.sharedInstance().currentRoute.description
        delegate?.audioSessionDidReceiveRouteChange(self, reason: reason, currentRoute: routeDescription)
    }
    #endif

    // MARK: - State Management

    private func transitionState(to newState: AudioSessionState) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()

        delegate?.audioSessionDidChangeState(self, state: newState)
    }
}
