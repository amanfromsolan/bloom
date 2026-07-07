import AppKit

/// Keeps one live GhosttySurfaceView per session so switching sessions in
/// the sidebar reattaches the same running shell instead of spawning a new one.
@MainActor
final class GhosttySurfaceManager {
    static let shared = GhosttySurfaceManager()

    private var views: [TerminalSession.ID: GhosttySurfaceView] = [:]

    private init() {}

    func view(for session: TerminalSession) -> GhosttySurfaceView {
        if let existing = views[session.id] {
            return existing
        }
        let view = GhosttySurfaceView(workingDirectory: session.workingDirectory)
        views[session.id] = view
        return view
    }

    /// The live view for a session, if one was already created.
    func existingView(for sessionID: TerminalSession.ID) -> GhosttySurfaceView? {
        views[sessionID]
    }

    func closeSurface(for sessionID: TerminalSession.ID) {
        guard let view = views.removeValue(forKey: sessionID) else { return }
        view.removeFromSuperview()
        view.shutdown()
    }
}
