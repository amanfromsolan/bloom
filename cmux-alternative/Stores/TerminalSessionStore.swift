import Combine
import Foundation

@MainActor
final class TerminalSessionStore: ObservableObject {
    /// Swipeable sidebar spaces; always at least one.
    @Published private(set) var spaces: [SidebarSpace]
    @Published private(set) var activeSpaceID: SidebarSpace.ID

    @Published var selection: TerminalSession.ID? {
        didSet { touch(selection) }
    }
    /// Rows highlighted for multi-select actions (folder creation, bulk close).
    @Published var multiSelection: Set<TerminalSession.ID> = []

    private var expiryTimer: Timer?
    private let persistToDisk: Bool

    init(spaces: [SidebarSpace]? = nil, persistToDisk: Bool = true) {
        self.persistToDisk = persistToDisk

        var loaded: [SidebarSpace]
        if let spaces {
            loaded = spaces
        } else if persistToDisk, let state = Self.loadState() {
            loaded = state.spaces
        } else {
            loaded = []
        }

        if loaded.isEmpty {
            loaded = [SidebarSpace(name: "Main", ephemeralSessions: [Self.makeSession()])]
        }

        self.spaces = loaded
        self.activeSpaceID = loaded[0].id

        pruneExpiredEphemeralSessions()

        if activeSpace.sessions.isEmpty, let first = self.spaces.first(where: { !$0.sessions.isEmpty }) {
            self.activeSpaceID = first.id
        }
        selection = activeSpace.lastSelection ?? activeSpace.sessions.first?.id

        if persistToDisk {
            let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.pruneExpiredEphemeralSessions()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        }
    }

    // MARK: - Spaces

    var activeSpace: SidebarSpace {
        spaces.first { $0.id == activeSpaceID } ?? spaces[0]
    }

    func setActiveSpace(_ spaceID: SidebarSpace.ID) {
        guard spaceID != activeSpaceID, spaces.contains(where: { $0.id == spaceID }) else { return }
        withSpace(activeSpaceID) { $0.lastSelection = selection }
        activeSpaceID = spaceID
        selection = activeSpace.lastSelection.flatMap { last in
            activeSpace.sessions.contains { $0.id == last } ? last : nil
        } ?? activeSpace.sessions.first?.id
        multiSelection = selection.map { [$0] } ?? []
        save()
    }

    @discardableResult
    func createSpace(name: String, icon: SidebarSpace.Icon) -> SidebarSpace.ID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = SidebarSpace(
            name: trimmed.isEmpty ? "Space \(spaces.count + 1)" : trimmed,
            icon: icon,
            ephemeralSessions: [Self.makeSession()]
        )
        spaces.append(space)
        setActiveSpace(space.id)
        save()
        return space.id
    }

    func renameSpace(_ spaceID: SidebarSpace.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withSpace(spaceID) { $0.name = trimmed }
        save()
    }

    func updateSpace(_ spaceID: SidebarSpace.ID, name: String, icon: SidebarSpace.Icon) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        withSpace(spaceID) { space in
            if !trimmed.isEmpty {
                space.name = trimmed
            }
            space.icon = icon
        }
        save()
    }

    func deleteSpace(_ spaceID: SidebarSpace.ID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let removed = spaces[index]
        for session in removed.sessions {
            GhosttySurfaceManager.shared.closeSurface(for: session.id)
        }
        spaces.remove(at: index)
        if activeSpaceID == spaceID {
            let fallback = spaces[min(index, spaces.count - 1)]
            activeSpaceID = fallback.id
            selection = fallback.lastSelection ?? fallback.sessions.first?.id
        }
        save()
    }

    // MARK: - Derived collections

    /// Every session across all spaces (surface bookkeeping, title sync).
    var sessions: [TerminalSession] {
        spaces.flatMap(\.sessions)
    }

    var selectedSession: TerminalSession? {
        guard let selection else { return nil }
        return sessions.first { $0.id == selection }
    }

    func isPinned(_ sessionID: TerminalSession.ID) -> Bool {
        !spaces.contains { $0.ephemeralSessions.contains { $0.id == sessionID } }
    }

    // MARK: - Creation

    func createSession(inSpace spaceID: SidebarSpace.ID? = nil) {
        let targetID = spaceID ?? activeSpaceID
        let session = Self.makeSession(accentIndex: sessions.count)
        withSpace(targetID) { space in
            space.ephemeralSessions.append(session)
        }
        if targetID != activeSpaceID {
            setActiveSpace(targetID)
        }
        selection = session.id
        multiSelection = [session.id]
        save()
    }

    func createFolder(inSpace spaceID: SidebarSpace.ID? = nil) {
        withSpace(spaceID ?? activeSpaceID) { space in
            space.pinnedFolders.append(TerminalFolder(title: "Folder \(space.pinnedFolders.count + 1)"))
        }
        save()
    }

    /// Moves the given sessions into a new pinned folder in the given space.
    func createFolder(with sessionIDs: Set<TerminalSession.ID>, inSpace spaceID: SidebarSpace.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        withSpace(spaceID) { space in
            space.pinnedFolders.append(
                TerminalFolder(title: "Folder \(space.pinnedFolders.count + 1)", sessions: moved)
            )
        }
        save()
    }

    private static func makeSession(accentIndex: Int = 0) -> TerminalSession {
        TerminalSession(
            title: "Terminal",
            workingDirectory: NSHomeDirectory(),
            status: .running,
            accent: .cycling(index: accentIndex)
        )
    }

    // MARK: - Pinning / moving

    func pin(_ sessionIDs: Set<TerminalSession.ID>, inSpace spaceID: SidebarSpace.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        withSpace(spaceID) { space in
            space.pinnedSessions.append(contentsOf: moved)
        }
        save()
    }

    func unpin(_ sessionIDs: Set<TerminalSession.ID>, inSpace spaceID: SidebarSpace.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        withSpace(spaceID) { space in
            space.ephemeralSessions.append(contentsOf: moved)
        }
        save()
    }

    func move(_ sessionIDs: Set<TerminalSession.ID>, toFolder folderID: TerminalFolder.ID) {
        guard spaces.contains(where: { $0.pinnedFolders.contains { $0.id == folderID } }) else { return }
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        for spaceIndex in spaces.indices {
            if let folderIndex = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == folderID }) {
                spaces[spaceIndex].pinnedFolders[folderIndex].sessions.append(contentsOf: moved)
                break
            }
        }
        save()
    }

    /// Reorders: moves sessions so they sit immediately before the target row,
    /// in whatever container (loose pinned, folder, ephemeral) the target lives.
    func insert(_ sessionIDs: Set<TerminalSession.ID>, before targetID: TerminalSession.ID) {
        guard !sessionIDs.contains(targetID) else { return }
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }

        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedSessions.firstIndex(where: { $0.id == targetID }) {
                spaces[spaceIndex].pinnedSessions.insert(contentsOf: moved, at: index)
                save()
                return
            }
            for folderIndex in spaces[spaceIndex].pinnedFolders.indices {
                if let index = spaces[spaceIndex].pinnedFolders[folderIndex].sessions.firstIndex(where: { $0.id == targetID }) {
                    spaces[spaceIndex].pinnedFolders[folderIndex].sessions.insert(contentsOf: moved, at: index)
                    save()
                    return
                }
            }
            if let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == targetID }) {
                spaces[spaceIndex].ephemeralSessions.insert(contentsOf: moved, at: index)
                save()
                return
            }
        }

        // Target vanished mid-drag; don't lose the sessions.
        withSpace(activeSpaceID) { space in
            space.ephemeralSessions.append(contentsOf: moved)
        }
        save()
    }

    /// Removes matching sessions from every space and returns them in display order.
    private func removeSessions(with sessionIDs: Set<TerminalSession.ID>) -> [TerminalSession] {
        var moved: [TerminalSession] = []
        for index in spaces.indices {
            moved += spaces[index].pinnedSessions.filter { sessionIDs.contains($0.id) }
            spaces[index].pinnedSessions.removeAll { sessionIDs.contains($0.id) }

            for folderIndex in spaces[index].pinnedFolders.indices {
                moved += spaces[index].pinnedFolders[folderIndex].sessions.filter { sessionIDs.contains($0.id) }
                spaces[index].pinnedFolders[folderIndex].sessions.removeAll { sessionIDs.contains($0.id) }
            }

            moved += spaces[index].ephemeralSessions.filter { sessionIDs.contains($0.id) }
            spaces[index].ephemeralSessions.removeAll { sessionIDs.contains($0.id) }
        }
        return moved
    }

    // MARK: - Closing

    func closeSelectedSession() {
        guard let selection else { return }
        close(sessionID: selection)
    }

    func close(sessionID: TerminalSession.ID) {
        close(sessionIDs: [sessionID])
    }

    func close(sessionIDs: Set<TerminalSession.ID>) {
        let orderedActive = activeSpace.sessions
        let anchorIndex = orderedActive.firstIndex { sessionIDs.contains($0.id) }

        for id in sessionIDs {
            GhosttySurfaceManager.shared.closeSurface(for: id)
        }
        _ = removeSessions(with: sessionIDs)
        multiSelection.subtract(sessionIDs)

        if let selection, sessionIDs.contains(selection) {
            let remaining = activeSpace.sessions
            if remaining.isEmpty {
                self.selection = nil
            } else {
                self.selection = remaining[min(anchorIndex ?? 0, remaining.count - 1)].id
            }
        }
        save()
    }

    func deleteFolder(_ folderID: TerminalFolder.ID) {
        for spaceIndex in spaces.indices {
            guard let index = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == folderID }) else {
                continue
            }
            // Folder rows disappear but their tabs survive as loose pinned tabs.
            spaces[spaceIndex].pinnedSessions.append(contentsOf: spaces[spaceIndex].pinnedFolders[index].sessions)
            spaces[spaceIndex].pinnedFolders.remove(at: index)
            break
        }
        save()
    }

    // MARK: - Renaming / status

    func rename(_ session: TerminalSession, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(session.id) { item in
            item.title = trimmed
        }
        save()
    }

    func rename(_ folder: TerminalFolder, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == folder.id }) {
                spaces[spaceIndex].pinnedFolders[index].title = trimmed
                break
            }
        }
        save()
    }

    func markSelectedNeedsAttention() {
        guard let selection else { return }
        update(selection) { item in
            item.status = .attention
            item.lastActivity = .now
        }
    }

    // MARK: - Focus navigation (within the active space)

    func focusNextSession() {
        let flattened = activeSpace.sessions
        guard !flattened.isEmpty else { return }
        guard let selection, let index = flattened.firstIndex(where: { $0.id == selection }) else {
            self.selection = flattened.first?.id
            return
        }
        self.selection = flattened[(index + 1) % flattened.count].id
    }

    func focusPreviousSession() {
        let flattened = activeSpace.sessions
        guard !flattened.isEmpty else { return }
        guard let selection, let index = flattened.firstIndex(where: { $0.id == selection }) else {
            self.selection = flattened.first?.id
            return
        }
        let nextIndex = index == 0 ? flattened.count - 1 : index - 1
        self.selection = flattened[nextIndex].id
    }

    func focusSession(atShortcutIndex shortcutIndex: Int) {
        let index = shortcutIndex - 1
        let flattened = activeSpace.sessions
        guard flattened.indices.contains(index) else { return }
        selection = flattened[index].id
    }

    // MARK: - Ephemeral expiry

    static let ephemeralTTLDefaultsKey = "ephemeralTTLHours"

    func pruneExpiredEphemeralSessions() {
        let hours = UserDefaults.standard.object(forKey: Self.ephemeralTTLDefaultsKey) as? Int ?? 24
        guard hours > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(hours) * 3600)
        let expired = spaces.flatMap(\.ephemeralSessions).filter {
            $0.lastActivity < cutoff && $0.id != selection
        }
        guard !expired.isEmpty else { return }
        close(sessionIDs: Set(expired.map(\.id)))
    }

    private func touch(_ sessionID: TerminalSession.ID?) {
        guard let sessionID else { return }
        update(sessionID) { item in
            item.lastActivity = .now
        }
    }

    // MARK: - Mutation helpers

    private func withSpace(_ id: SidebarSpace.ID, _ mutate: (inout SidebarSpace) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        mutate(&spaces[index])
    }

    private func update(_ id: TerminalSession.ID, mutate: (inout TerminalSession) -> Void) {
        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedSessions.firstIndex(where: { $0.id == id }) {
                mutate(&spaces[spaceIndex].pinnedSessions[index])
                return
            }
            for folderIndex in spaces[spaceIndex].pinnedFolders.indices {
                if let index = spaces[spaceIndex].pinnedFolders[folderIndex].sessions.firstIndex(where: { $0.id == id }) {
                    mutate(&spaces[spaceIndex].pinnedFolders[folderIndex].sessions[index])
                    return
                }
            }
            if let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == id }) {
                mutate(&spaces[spaceIndex].ephemeralSessions[index])
                return
            }
        }
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var spaces: [SidebarSpace]
    }

    /// Pre-spaces state file layout, migrated on first load.
    private struct LegacyPersistedState: Codable {
        var pinnedFolders: [TerminalFolder]
        var pinnedSessions: [TerminalSession]
        var ephemeralSessions: [TerminalSession]
    }

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-alternative", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.json")
    }

    private static func loadState() -> PersistedState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            return state
        }
        if let legacy = try? JSONDecoder().decode(LegacyPersistedState.self, from: data) {
            return PersistedState(spaces: [
                SidebarSpace(
                    name: "Main",
                    pinnedFolders: legacy.pinnedFolders,
                    pinnedSessions: legacy.pinnedSessions,
                    ephemeralSessions: legacy.ephemeralSessions
                )
            ])
        }
        return nil
    }

    private func save() {
        guard persistToDisk else { return }
        withSpace(activeSpaceID) { $0.lastSelection = selection }
        guard let data = try? JSONEncoder().encode(PersistedState(spaces: spaces)) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}

extension TerminalSessionStore {
    static var preview: TerminalSessionStore {
        TerminalSessionStore(
            spaces: [
                SidebarSpace(
                    name: "Work",
                    icon: .symbol("hammer.fill"),
                    pinnedFolders: [
                        TerminalFolder(
                            title: "cmux-alternative",
                            sessions: [
                                TerminalSession(title: "main", workingDirectory: "~", accent: .blue),
                                TerminalSession(title: "agent", workingDirectory: "~", accent: .green)
                            ]
                        )
                    ],
                    pinnedSessions: [
                        TerminalSession(title: "scratch", workingDirectory: "~", accent: .orange)
                    ],
                    ephemeralSessions: [
                        TerminalSession(title: "Terminal", workingDirectory: "~", accent: .pink)
                    ]
                ),
                SidebarSpace(
                    name: "Play",
                    icon: .emoji("🎮"),
                    ephemeralSessions: [
                        TerminalSession(title: "games", workingDirectory: "~", accent: .violet)
                    ]
                )
            ],
            persistToDisk: false
        )
    }
}
