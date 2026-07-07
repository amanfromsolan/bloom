import SwiftUI

struct TerminalCommands: Commands {
    @ObservedObject var store: TerminalSessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                store.createSession()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Folder") {
                store.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Tab") {
            Button(pinTitle) {
                guard let selection = store.selection else { return }
                if store.isPinned(selection) {
                    store.unpin([selection])
                } else {
                    store.pin([selection])
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(store.selection == nil)

            Button("Close Tab") {
                store.closeSelectedSession()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(store.selection == nil)

            Divider()

            Button("Previous Tab") {
                store.focusPreviousSession()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Next Tab") {
                store.focusNextSession()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Select Tab \(index)") {
                    store.focusSession(atShortcutIndex: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                .disabled(store.sessions.count < index)
            }
        }
    }

    private var pinTitle: String {
        guard let selection = store.selection, store.isPinned(selection) else {
            return "Pin Tab"
        }
        return "Unpin Tab"
    }
}
