import AppKit
import SwiftUI

struct GhosttyTerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    let store: TerminalSessionStore

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.018, green: 0.019, blue: 0.023, alpha: 1).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let sessionID = session.id
        let surfaceView = GhosttySurfaceManager.shared.view(for: session)

        surfaceView.onTitleChange = { [weak store] title in
            guard let store, let current = store.sessions.first(where: { $0.id == sessionID }) else { return }
            store.rename(current, to: title)
        }
        surfaceView.onSurfaceClose = { [weak store] in
            store?.close(sessionID: sessionID)
        }

        guard surfaceView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        surfaceView.frame = container.bounds
        surfaceView.autoresizingMask = [.width, .height]
        container.addSubview(surfaceView)

        DispatchQueue.main.async {
            container.window?.makeFirstResponder(surfaceView)
        }
    }
}
