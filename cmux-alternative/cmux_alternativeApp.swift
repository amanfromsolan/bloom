//
//  cmux_alternativeApp.swift
//  cmux-alternative
//
//  Created by aman on 09/06/26.
//

import SwiftUI

@main
struct cmux_alternativeApp: App {
    @StateObject private var sessionStore = TerminalSessionStore()

    init() {
        // Start libghostty before any view reads the theme background.
        GhosttyRuntime.shared.ensureStarted()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: sessionStore)
                .frame(minWidth: 920, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            TerminalCommands(store: sessionStore)
        }

        Settings {
            SettingsView()
        }
    }
}

private struct SettingsView: View {
    @AppStorage(TerminalSessionStore.ephemeralTTLDefaultsKey)
    private var ephemeralTTLHours = 24

    var body: some View {
        Form {
            Picker("Close unpinned tabs after", selection: $ephemeralTTLHours) {
                Text("12 hours").tag(12)
                Text("24 hours").tag(24)
                Text("48 hours").tag(48)
                Text("Never").tag(0)
            }
            .pickerStyle(.inline)

            Text("Tabs below the sidebar divider are temporary. Pin a tab (drag it above the divider) to keep it forever.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
    }
}
