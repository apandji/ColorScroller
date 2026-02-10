//
//  ColorScrollerApp.swift
//  ColorScroller
//
//  Created by Jenica on 2/4/26.
//

import SwiftUI

@main
struct ColorScrollerApp: App {

    init() {
        // Pre-warm audio engine asynchronously so it doesn't block
        // the initial layout pass (avoids gesture gate timeout).
        // AVAudioEngine must run on main actor, but Task defers it
        // until after the first render cycle completes.
        Task { @MainActor in
            TonePlayer.shared.prepareIfNeeded()
        }

        // Debug: dump all CloudKit records to console on launch
        BehaviorLogger.shared.fetchAllCloudKitRecords()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
