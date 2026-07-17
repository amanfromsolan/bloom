import Foundation
import Testing
@testable import Enso

/// Folder working-directory memory (#25): a folder is, in practice, a
/// project, so it must remember its last tab's cwd — surviving manual
/// closes, ephemeral expiry, and app relaunch — and hand it to the next
/// tab created inside it.
@MainActor
struct TerminalSessionStoreTests {
    /// A real directory on disk so the stale-path check passes.
    private func makeTempDirectory(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsoStoreTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// `select` pins the store's initial selection; the store `touch`es the
    /// selected tab on launch, so tests about `lastActivity` ordering must
    /// control which tab that is.
    private func makeStore(folder: TerminalFolder, select: TerminalSession.ID? = nil) -> TerminalSessionStore {
        TerminalSessionStore(
            spaces: [SidebarSpace(name: "Main", pinnedFolders: [folder], lastSelection: select)],
            persistToDisk: false
        )
    }

    private func folder(_ id: TerminalFolder.ID, in store: TerminalSessionStore) -> TerminalFolder? {
        store.spaces.flatMap(\.pinnedFolders).first { $0.id == id }
    }

    @Test func emptiedFolderSpawnsNewTabInRememberedDirectory() throws {
        let projectDir = try makeTempDirectory("project")
        let session = TerminalSession(title: "main", workingDirectory: projectDir)
        let folderID = TerminalFolder.ID()
        let store = makeStore(folder: TerminalFolder(id: folderID, title: "enso", sessions: [session]))

        store.close(sessionID: session.id)
        #expect(folder(folderID, in: store)?.sessions.isEmpty == true)
        #expect(folder(folderID, in: store)?.lastWorkingDirectory == projectDir)

        store.createSession(inFolder: folderID)
        #expect(store.selectedSession?.workingDirectory == projectDir)
    }

    @Test func mostRecentlyActiveTabWinsWhenFolderEmpties() throws {
        let oldDir = try makeTempDirectory("old")
        let recentDir = try makeTempDirectory("recent")
        let older = TerminalSession(
            title: "old", workingDirectory: oldDir, lastActivity: .now.addingTimeInterval(-3600)
        )
        let recent = TerminalSession(title: "recent", workingDirectory: recentDir, lastActivity: .now)
        let folderID = TerminalFolder.ID()
        let store = makeStore(
            folder: TerminalFolder(id: folderID, title: "enso", sessions: [older, recent]),
            select: recent.id
        )

        store.close(sessionIDs: [older.id, recent.id])
        #expect(folder(folderID, in: store)?.lastWorkingDirectory == recentDir)
    }

    @Test func cwdChangeKeepsFolderMemoryLive() throws {
        let startDir = try makeTempDirectory("start")
        let nestedDir = try makeTempDirectory("nested")
        let session = TerminalSession(title: "main", workingDirectory: startDir)
        let folderID = TerminalFolder.ID()
        let store = makeStore(folder: TerminalFolder(id: folderID, title: "enso", sessions: [session]))

        // The breadcrumb cwd (OSC 7), not the spawn cwd, is what the folder
        // remembers — captured on every change, not only on removal.
        store.updateWorkingDirectory(session.id, to: nestedDir)
        #expect(folder(folderID, in: store)?.lastWorkingDirectory == nestedDir)

        store.close(sessionID: session.id)
        store.createSession(inFolder: folderID)
        #expect(store.selectedSession?.workingDirectory == nestedDir)
    }

    @Test func staleRememberedDirectoryFallsBackToDefault() {
        let folderID = TerminalFolder.ID()
        let store = makeStore(folder: TerminalFolder(
            id: folderID,
            title: "enso",
            lastWorkingDirectory: "/definitely/not/a/real/path-\(UUID().uuidString)"
        ))

        store.createSession(inFolder: folderID)
        #expect(store.selectedSession?.workingDirectory == NSHomeDirectory())
    }

    @Test func liveTabsStillWinOverRememberedDirectory() throws {
        let liveDir = try makeTempDirectory("live")
        let rememberedDir = try makeTempDirectory("remembered")
        let session = TerminalSession(title: "main", workingDirectory: liveDir)
        let folderID = TerminalFolder.ID()
        let store = makeStore(folder: TerminalFolder(
            id: folderID, title: "enso", sessions: [session], lastWorkingDirectory: rememberedDir
        ))

        store.createSession(inFolder: folderID)
        #expect(store.selectedSession?.workingDirectory == liveDir)
    }

    // MARK: - Eager restore candidates (#45 / #53)

    @Test func eagerRestoreCandidatesAreMostRecentFirstAndSkipSelectedAndFiltered() throws {
        let dir = try makeTempDirectory("candidates")
        let selected = TerminalSession(title: "selected", workingDirectory: dir, lastActivity: .now)
        let stale = TerminalSession(
            title: "stale", workingDirectory: dir, lastActivity: .now.addingTimeInterval(-7200)
        )
        let fresh = TerminalSession(
            title: "fresh", workingDirectory: dir, lastActivity: .now.addingTimeInterval(-60)
        )
        let plainShell = TerminalSession(
            title: "shell", workingDirectory: dir, lastActivity: .now.addingTimeInterval(-30)
        )
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [selected, stale, fresh, plainShell]),
            select: selected.id
        )

        let restorable: Set = [selected.id, stale.id, fresh.id]
        let candidates = store.eagerRestoreCandidates { restorable.contains($0) }
        // Selected is excluded even though restorable; the plain shell tab
        // never makes the list; the rest come most recently used first.
        #expect(candidates.map(\.id) == [fresh.id, stale.id])
    }

    @Test func eagerRestoreCandidatesAreCapped() throws {
        let dir = try makeTempDirectory("capped")
        // tab-0 is selected (and skipped); tab-1 onward are candidates in
        // strictly decreasing recency.
        let sessions = (0..<(TerminalSessionStore.maxEagerRestores + 3)).map { index in
            TerminalSession(
                title: "tab-\(index)",
                workingDirectory: dir,
                lastActivity: .now.addingTimeInterval(-Double(index))
            )
        }
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: sessions),
            select: sessions[0].id
        )

        let candidates = store.eagerRestoreCandidates { _ in true }
        // The cap keeps the most recently used tabs; the least recent two
        // stay lazy.
        #expect(candidates.map(\.id)
            == sessions[1...TerminalSessionStore.maxEagerRestores].map(\.id))
    }

    // MARK: - Persistence compatibility

    /// State files written before the field existed must keep decoding.
    @Test func folderDecodesWithoutLastWorkingDirectoryKey() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"enso","sessions":[]}
        """
        let folder = try JSONDecoder().decode(TerminalFolder.self, from: Data(json.utf8))
        #expect(folder.title == "enso")
        #expect(folder.lastWorkingDirectory == nil)
    }

    @Test func folderRoundTripsLastWorkingDirectory() throws {
        let original = TerminalFolder(title: "enso", lastWorkingDirectory: "/tmp/project")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalFolder.self, from: data)
        #expect(decoded.lastWorkingDirectory == "/tmp/project")
    }
}
