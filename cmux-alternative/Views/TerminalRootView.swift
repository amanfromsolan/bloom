import SwiftUI

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore
    @SceneStorage("selectedSessionID") private var storedSelection: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Clear space for the traffic lights; drags the window.
                Color.clear
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())

                SidebarView(store: store)
            }
            .frame(width: 248)
            .background(
                SidebarMaterial()
                    .overlay(Color.black.opacity(0.38))
            )

            Divider()
                .overlay(Color.white.opacity(0.07))

            TerminalWorkspaceView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            restoreSelection()
        }
        .onChange(of: store.selection) { _, selection in
            storedSelection = selection?.uuidString
        }
    }

    private func restoreSelection() {
        guard
            let storedSelection,
            let id = UUID(uuidString: storedSelection),
            store.sessions.contains(where: { $0.id == id })
        else {
            return
        }

        store.selection = id
    }
}

/// Frosted sidebar backdrop that blurs whatever is behind the window.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    TerminalRootView(store: .preview)
}
