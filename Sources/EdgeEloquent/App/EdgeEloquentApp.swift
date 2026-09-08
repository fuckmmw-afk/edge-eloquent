//
//  EdgeEloquentApp.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Application entry point enforcing zero-bundled-weights invariant and initializing root views.
//

import SwiftUI

@main
public struct EdgeEloquentApp: App {

    public init() {
        // Assert Zero Bundled Weights invariant on application launch
        do {
            try ModelManager.assertNoBundledWeights()
        } catch {
            assertionFailure("Security invariant failure: \(error.localizedDescription)")
        }
    }

    public var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
