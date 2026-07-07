import Combine
import Foundation

@MainActor
final class TerminalSessionStore: ObservableObject {
    /// Saved tabs above the divider: folders plus loose pinned sessions.
    @Published private(set) var pinnedFolders: [TerminalFolder]
    @Published private(set) var pinnedSessions: [TerminalSession]
    /// Throwaway tabs below the divider; auto-expire after `ephemeralTTLHours`.
    @Published private(set) var ephemeralSessions: [TerminalSession]

    @Published var selection: TerminalSession.ID? {
        didSet { touch(selection) }
    }
    /// Rows highlighted for multi-select actions (folder creation, bulk close).
    @Published var multiSelection: Set<TerminalSession.ID> = []

    private var expiryTimer: Timer?
    private let persistToDisk: Bool

    init(
        pinnedFolders: [TerminalFolder]? = nil,
        pinnedSessions: [TerminalSession]? = nil,
        ephemeralSessions: [TerminalSession]? = nil,
        persistToDisk: Bool = true
    ) {
        self.persistToDisk = persistToDisk

        if pinnedFolders != nil || pinnedSessions != nil || ephemeralSessions != nil {
            self.pinnedFolders = pinnedFolders ?? []
            self.pinnedSessions = pinnedSessions ?? []
            self.ephemeralSessions = ephemeralSessions ?? []
        } else if persistToDisk, let state = Self.loadState() {
            self.pinnedFolders = state.pinnedFolders
            self.pinnedSessions = state.pinnedSessions
            self.ephemeralSessions = state.ephemeralSessions
        } else {
            self.pinnedFolders = []
            self.pinnedSessions = []
            self.ephemeralSessions = [Self.makeSession()]
        }

        pruneExpiredEphemeralSessions()

        if sessions.isEmpty {
            self.ephemeralSessions = [Self.makeSession()]
        }

        selection = sessions.first?.id

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

    // MARK: - Derived collections

    var sessions: [TerminalSession] {
        pinnedSessions + pinnedFolders.flatMap(\.sessions) + ephemeralSessions
    }

    var selectedSession: TerminalSession? {
        guard let selection else {
            return sessions.first
        }
        return sessions.first { $0.id == selection }
    }

    func isPinned(_ sessionID: TerminalSession.ID) -> Bool {
        !ephemeralSessions.contains { $0.id == sessionID }
    }

    // MARK: - Creation

    func createSession() {
        let session = Self.makeSession(accentIndex: sessions.count)
        ephemeralSessions.append(session)
        selection = session.id
        multiSelection = [session.id]
        save()
    }

    func createFolder() {
        pinnedFolders.append(TerminalFolder(title: "Folder \(pinnedFolders.count + 1)"))
        save()
    }

    /// Moves the given sessions (from any zone) into a new pinned folder.
    func createFolder(with sessionIDs: Set<TerminalSession.ID>) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        pinnedFolders.append(TerminalFolder(title: "Folder \(pinnedFolders.count + 1)", sessions: moved))
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

    func pin(_ sessionIDs: Set<TerminalSession.ID>) {
        let moved = ephemeralSessions.filter { sessionIDs.contains($0.id) }
        guard !moved.isEmpty else { return }
        ephemeralSessions.removeAll { sessionIDs.contains($0.id) }
        pinnedSessions.append(contentsOf: moved)
        save()
    }

    func unpin(_ sessionIDs: Set<TerminalSession.ID>) {
        let moved = removeSessions(with: sessionIDs, includeEphemeral: false)
        guard !moved.isEmpty else { return }
        ephemeralSessions.append(contentsOf: moved)
        save()
    }

    func move(_ sessionIDs: Set<TerminalSession.ID>, toFolder folderID: TerminalFolder.ID) {
        guard pinnedFolders.contains(where: { $0.id == folderID }) else { return }
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        updateFolder(folderID) { folder in
            folder.sessions.append(contentsOf: moved)
        }
        save()
    }

    /// Removes matching sessions from every zone and returns them in display order.
    private func removeSessions(
        with sessionIDs: Set<TerminalSession.ID>,
        includeEphemeral: Bool = true
    ) -> [TerminalSession] {
        var moved: [TerminalSession] = []

        moved += pinnedSessions.filter { sessionIDs.contains($0.id) }
        pinnedSessions.removeAll { sessionIDs.contains($0.id) }

        for index in pinnedFolders.indices {
            moved += pinnedFolders[index].sessions.filter { sessionIDs.contains($0.id) }
            pinnedFolders[index].sessions.removeAll { sessionIDs.contains($0.id) }
        }

        if includeEphemeral {
            moved += ephemeralSessions.filter { sessionIDs.contains($0.id) }
            ephemeralSessions.removeAll { sessionIDs.contains($0.id) }
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
        let ordered = sessions
        guard let anchorIndex = ordered.firstIndex(where: { sessionIDs.contains($0.id) }) else { return }

        for id in sessionIDs {
            GhosttySurfaceManager.shared.closeSurface(for: id)
        }
        _ = removeSessions(with: sessionIDs)
        multiSelection.subtract(sessionIDs)

        if let selection, sessionIDs.contains(selection) {
            let remaining = sessions
            if remaining.isEmpty {
                self.selection = nil
            } else {
                self.selection = remaining[min(anchorIndex, remaining.count - 1)].id
            }
        }
        save()
    }

    func deleteFolder(_ folderID: TerminalFolder.ID) {
        guard let index = pinnedFolders.firstIndex(where: { $0.id == folderID }) else { return }
        // Folder rows disappear but their tabs survive as loose pinned tabs.
        pinnedSessions.append(contentsOf: pinnedFolders[index].sessions)
        pinnedFolders.remove(at: index)
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
        updateFolder(folder.id) { item in
            item.title = trimmed
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

    // MARK: - Focus navigation

    func focusNextSession() {
        let flattened = sessions
        guard let selection, let index = flattened.firstIndex(where: { $0.id == selection }) else {
            self.selection = flattened.first?.id
            return
        }
        self.selection = flattened[(index + 1) % flattened.count].id
    }

    func focusPreviousSession() {
        let flattened = sessions
        guard let selection, let index = flattened.firstIndex(where: { $0.id == selection }) else {
            self.selection = flattened.first?.id
            return
        }
        let nextIndex = index == 0 ? flattened.count - 1 : index - 1
        self.selection = flattened[nextIndex].id
    }

    func focusSession(atShortcutIndex shortcutIndex: Int) {
        let index = shortcutIndex - 1
        let flattened = sessions
        guard flattened.indices.contains(index) else { return }
        selection = flattened[index].id
    }

    // MARK: - Ephemeral expiry

    static let ephemeralTTLDefaultsKey = "ephemeralTTLHours"

    func pruneExpiredEphemeralSessions() {
        let hours = UserDefaults.standard.object(forKey: Self.ephemeralTTLDefaultsKey) as? Int ?? 24
        guard hours > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(hours) * 3600)
        let expired = ephemeralSessions.filter { $0.lastActivity < cutoff && $0.id != selection }
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

    private func updateFolder(_ id: TerminalFolder.ID, mutate: (inout TerminalFolder) -> Void) {
        guard let index = pinnedFolders.firstIndex(where: { $0.id == id }) else { return }
        mutate(&pinnedFolders[index])
    }

    private func update(_ id: TerminalSession.ID, mutate: (inout TerminalSession) -> Void) {
        if let index = pinnedSessions.firstIndex(where: { $0.id == id }) {
            mutate(&pinnedSessions[index])
            return
        }
        for folderIndex in pinnedFolders.indices {
            if let index = pinnedFolders[folderIndex].sessions.firstIndex(where: { $0.id == id }) {
                mutate(&pinnedFolders[folderIndex].sessions[index])
                return
            }
        }
        if let index = ephemeralSessions.firstIndex(where: { $0.id == id }) {
            mutate(&ephemeralSessions[index])
        }
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
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
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private func save() {
        guard persistToDisk else { return }
        let state = PersistedState(
            pinnedFolders: pinnedFolders,
            pinnedSessions: pinnedSessions,
            ephemeralSessions: ephemeralSessions
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}

extension TerminalSessionStore {
    static var preview: TerminalSessionStore {
        TerminalSessionStore(
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
            ],
            persistToDisk: false
        )
    }
}
