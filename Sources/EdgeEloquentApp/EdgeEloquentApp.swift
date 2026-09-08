//
//  EdgeEloquentApp.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Application entry point enforcing zero-bundled-weights invariant and initializing root views.
//

import SwiftUI
import EdgeEloquent

@main
struct EdgeEloquentApp: App {

    init() {
        // Assert Zero Bundled Weights invariant on application launch
        do {
            try ModelManager.assertNoBundledWeights()
        } catch {
            assertionFailure("Security invariant failure: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
