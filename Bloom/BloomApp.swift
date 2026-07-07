//
//  BloomApp.swift
//  Bloom
//
//  Created by aman on 09/06/26.
//

import SwiftUI

@main
struct BloomApp: App {
    @StateObject private var sessionStore = TerminalSessionStore()

    init() {
        // macOS ships with font smoothing off since Big Sur, which renders
        // small light-on-dark UI text thin and brittle. Opt this app back in
        // (CoreText reads the app's preference domain at startup).
        if UserDefaults.standard.object(forKey: "AppleFontSmoothing") == nil {
            UserDefaults.standard.set(2, forKey: "AppleFontSmoothing")
        }

        // Start libghostty before any view reads the theme background.
        GhosttyRuntime.shared.ensureStarted()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: sessionStore)
                .frame(minWidth: 920, minHeight: 560)
                .preferredColorScheme(.dark)
                .onAppear {
                    TabAutoNamer.shared.configure(store: sessionStore)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            TerminalCommands(store: sessionStore)
        }

        // Settings as its own fixed-size window (⌘,). A custom Window scene
        // instead of Settings {} so the design keeps its own chrome.
        Window("Settings", id: SettingsPanel.windowID) {
            SettingsPanelView(panel: SettingsPanel.shared)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
