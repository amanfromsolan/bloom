import AppKit
import Combine
import SwiftUI

/// The ⌘T/⌘P command center: one fuzzy palette over tabs, spaces, and
/// commands. Empty query shows recent tabs and spaces with "New Tab" as the
/// default Enter action; typing filters across everything at once. The first
/// nine rows get ⌘1–9 quick-select shortcuts.
@MainActor
final class CommandCenter: ObservableObject {
    static let shared = CommandCenter()

    @Published private(set) var isOpen = false
    @Published var query = "" {
        didSet { rebuild() }
    }
    @Published private(set) var items: [PaletteItem] = []
    @Published var highlightedIndex = 0

    private weak var store: TerminalSessionStore?
    // Freed from deinit, which is nonisolated under strict concurrency.
    nonisolated(unsafe) private var monitor: Any?

    private init() {}

    func attach(to store: TerminalSessionStore) {
        self.store = store
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard store != nil, !isOpen else { return }
        query = ""
        highlightedIndex = 0
        rebuild()
        isOpen = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        // Hand the keyboard back to the visible terminal.
        if let store, let selection = store.selection,
           let surface = GhosttySurfaceManager.shared.existingView(for: selection) {
            surface.window?.makeFirstResponder(surface)
        }
    }

    func execute(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        close()
        item.perform()
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // esc
            close()
            return nil
        case 125: // down
            moveHighlight(1)
            return nil
        case 126: // up
            moveHighlight(-1)
            return nil
        case 36, 76: // return / keypad enter
            execute(highlightedIndex)
            return nil
        default:
            break
        }

        // ⌘1–9 executes the corresponding visible row directly.
        if event.modifierFlags.contains(.command),
           let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
           (1...9).contains(digit) {
            execute(digit - 1)
            return nil
        }

        return event
    }

    private func moveHighlight(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlightedIndex = (highlightedIndex + delta + items.count) % items.count
    }

    // MARK: - Results

    private func rebuild() {
        guard let store else {
            items = []
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Default sheet: New Tab first (Enter does the obvious thing),
            // then recent tabs everywhere, then spaces.
            items = [newTabItem(in: store)]
                + tabItems(in: store).prefix(6)
                + spaceItems(in: store)
        } else {
            let candidates = tabItems(in: store)
                + spaceItems(in: store)
                + commandItems(in: store)
            items = candidates
                .compactMap { item -> (PaletteItem, Int)? in
                    guard let score = Self.fuzzyScore(query: trimmed, in: item.title) else { return nil }
                    return (item, score)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        highlightedIndex = 0
    }

    private func tabItems(in store: TerminalSessionStore) -> [PaletteItem] {
        store.recencyOrderedSessionsAcrossSpaces().map { session, space in
            PaletteItem(
                id: "tab-\(session.id)",
                icon: .accent(session.accent.color),
                title: session.title,
                context: space.name,
                verb: "Switch"
            ) { [weak store] in
                store?.reveal(session.id)
            }
        }
    }

    private func spaceItems(in store: TerminalSessionStore) -> [PaletteItem] {
        store.spaces.map { space in
            PaletteItem(
                id: "space-\(space.id)",
                icon: .space(space.icon),
                title: space.name,
                context: "Space",
                verb: "Go"
            ) { [weak store] in
                store?.setActiveSpace(space.id)
            }
        }
    }

    private func newTabItem(in store: TerminalSessionStore) -> PaletteItem {
        PaletteItem(
            id: "cmd-new-tab",
            icon: .symbol("plus"),
            title: "New Tab",
            context: "Command",
            verb: "Open"
        ) { [weak store] in
            store?.createSession()
        }
    }

    private func commandItems(in store: TerminalSessionStore) -> [PaletteItem] {
        var commands = [newTabItem(in: store)]

        commands.append(PaletteItem(
            id: "cmd-new-folder",
            icon: .symbol("folder.badge.plus"),
            title: "New Folder",
            context: "Command",
            verb: "Run"
        ) { [weak store] in
            store?.createFolder()
        })

        commands.append(PaletteItem(
            id: "cmd-new-space",
            icon: .symbol("rectangle.stack.badge.plus"),
            title: "New Space",
            context: "Command",
            verb: "Run"
        ) { [weak store] in
            store?.createSpace(name: "", icon: .dot)
        })

        if let selection = store.selection {
            let pinned = store.isPinned(selection)
            commands.append(PaletteItem(
                id: "cmd-toggle-pin",
                icon: .symbol(pinned ? "pin.slash" : "pin"),
                title: pinned ? "Unpin Tab" : "Pin Tab",
                context: "Command",
                verb: "Run"
            ) { [weak store] in
                guard let store, let selection = store.selection else { return }
                if store.isPinned(selection) {
                    store.unpin([selection], inSpace: store.activeSpaceID)
                } else {
                    store.pin([selection], inSpace: store.activeSpaceID)
                }
            })

            commands.append(PaletteItem(
                id: "cmd-close-tab",
                icon: .symbol("xmark"),
                title: "Close Tab",
                context: "Command",
                verb: "Run"
            ) { [weak store] in
                store?.closeSelectedSession()
            })

            for space in store.spaces where space.id != store.activeSpaceID {
                commands.append(PaletteItem(
                    id: "cmd-move-\(space.id)",
                    icon: .space(space.icon),
                    title: "Move Tab to \(space.name)",
                    context: "Command",
                    verb: "Run"
                ) { [weak store] in
                    guard let store, let selection = store.selection else { return }
                    store.unpin([selection], inSpace: space.id)
                    store.reveal(selection)
                })
            }
        }

        commands.append(PaletteItem(
            id: "cmd-settings",
            icon: .symbol("gearshape"),
            title: "Settings",
            context: "Command",
            verb: "Run"
        ) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })

        return commands
    }

    /// Case-insensitive subsequence match with bonuses for prefix, word
    /// starts, and consecutive runs. Returns nil when the query doesn't match.
    static func fuzzyScore(query: String, in candidate: String) -> Int? {
        let query = Array(query.lowercased())
        let candidate = Array(candidate.lowercased())
        guard !query.isEmpty else { return 0 }

        var score = 0
        var queryIndex = 0
        var lastMatch = -1

        for (index, char) in candidate.enumerated() where queryIndex < query.count {
            guard char == query[queryIndex] else { continue }
            if index == 0 {
                score += 5
            } else if candidate[index - 1] == " " || candidate[index - 1] == "-" {
                score += 3
            }
            if lastMatch == index - 1 {
                score += 2
            }
            score += 1
            lastMatch = index
            queryIndex += 1
        }

        return queryIndex == query.count ? score : nil
    }
}

struct PaletteItem: Identifiable {
    enum Icon {
        case accent(Color)
        case space(SidebarSpace.Icon)
        case symbol(String)
    }

    let id: String
    let icon: Icon
    let title: String
    let context: String?
    let verb: String
    let perform: () -> Void
}

// MARK: - View

struct CommandCenterView: View {
    @ObservedObject var center: CommandCenter
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))

                TextField("Search tabs, spaces, commands…", text: $center.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.92))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 1)

            if center.items.isEmpty {
                Text("No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(center.items.enumerated()), id: \.element.id) { index, item in
                                row(item, at: index)
                                    .id(item.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: center.highlightedIndex) { _, index in
                        guard center.items.indices.contains(index) else { return }
                        proxy.scrollTo(center.items[index].id)
                    }
                }
            }
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        )
        .onAppear {
            // A beat later so focus wins over the terminal NSView, which is
            // first responder when the palette opens.
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
    }

    private func row(_ item: PaletteItem, at index: Int) -> some View {
        let isHighlighted = index == center.highlightedIndex

        return HStack(spacing: 12) {
            HStack(spacing: 9) {
                iconView(item.icon, isHighlighted: isHighlighted)
                    .frame(width: 16)

                Text(item.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(isHighlighted ? 0.95 : 0.6))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if let context = item.context {
                Text(context)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(isHighlighted ? 0.55 : 0.35))
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }

            HStack(spacing: 8) {
                if isHighlighted {
                    HStack(spacing: 4) {
                        Text(item.verb)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }

                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(isHighlighted ? 0.55 : 0.3))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.07))
                        )
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHighlighted ? Color.white.opacity(0.09) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                center.highlightedIndex = index
            }
        }
        .onTapGesture {
            center.execute(index)
        }
    }

    @ViewBuilder
    private func iconView(_ icon: PaletteItem.Icon, isHighlighted: Bool) -> some View {
        switch icon {
        case .accent(let color):
            Circle()
                .fill(color.opacity(isHighlighted ? 0.95 : 0.55))
                .frame(width: 7, height: 7)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(isHighlighted ? 0.8 : 0.45))
        case .space(let spaceIcon):
            switch spaceIcon {
            case .dot:
                Circle()
                    .fill(.white.opacity(isHighlighted ? 0.85 : 0.4))
                    .frame(width: 6, height: 6)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isHighlighted ? 0.85 : 0.45))
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: 12))
                    .opacity(isHighlighted ? 1 : 0.55)
            }
        }
    }
}
