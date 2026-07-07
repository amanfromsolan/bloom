import SwiftUI

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore
    @StateObject private var switcher = TabSwitcher()
    @ObservedObject private var commandCenter = CommandCenter.shared
    @Environment(\.openWindow) private var openWindow
    @State private var spaceEditor: SpaceEditorSheet.Mode?
    @SceneStorage("selectedSessionID") private var storedSelection: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Clear space for the traffic lights; drags the window.
                Color.clear
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())

                SidebarView(store: store, spaceEditor: $spaceEditor)
            }
            .frame(width: 248)

            // Terminal floats as an inset card on the frosted window.
            TerminalWorkspaceView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 12, y: 3)
                .overlay {
                    if switcher.isShowingHUD {
                        ZStack {
                            // Dim the terminal behind the HUD; purely visual,
                            // so it never swallows a stray click.
                            Color.black.opacity(0.35)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .allowsHitTesting(false)

                            TabSwitcherHUD(switcher: switcher, store: store)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: switcher.isShowingHUD)
                .padding(EdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TrafficLightInset())
        .background(
            SidebarMaterial()
                .overlay(Color.black.opacity(0.38))
                .ignoresSafeArea()
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if commandCenter.isOpen {
                ZStack(alignment: .top) {
                    // Scrim: dims the window and swallows clicks outside the
                    // palette to dismiss.
                    Color.black.opacity(0.4)
                        .contentShape(Rectangle())
                        .onTapGesture { commandCenter.close() }
                        .ignoresSafeArea()

                    // Mirror the root layout so the palette centers on the
                    // terminal column, not the whole window.
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: 248)
                            .allowsHitTesting(false)

                        // A fixed-height slot the card top-aligns into: the
                        // slot stays vertically centered, so the search bar
                        // never moves as results grow or shrink.
                        CommandCenterView(center: commandCenter)
                            .frame(height: 480, alignment: .top)
                            .padding(.top, 90)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        // Space editor as an owned in-window modal: macOS sheet windows
        // force their own chrome (border, corner radius), so we draw the
        // card and dimming scrim ourselves.
        .overlay {
            if let mode = spaceEditor {
                ZStack {
                    Color.black.opacity(0.5)
                        .contentShape(Rectangle())
                        .onTapGesture { spaceEditor = nil }
                        .ignoresSafeArea()
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.16)),
                            removal: .opacity.animation(.easeOut(duration: 0.07))
                        ))

                    SpaceEditorSheet(mode: mode) { name, icon in
                        switch mode {
                        case .create:
                            store.createSpace(name: name, icon: icon)
                        case .edit(let space):
                            store.updateSpace(space.id, name: name, icon: icon)
                        }
                    } onDismiss: {
                        spaceEditor = nil
                    }
                    // Pops in sharpening from a blur while scaling up;
                    // leaves with a near-instant fade.
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: ModalPopEffect(progress: 0),
                            identity: ModalPopEffect(progress: 1)
                        )
                        .animation(.spring(duration: 0.18, bounce: 0.24)),
                        removal: .opacity.animation(.easeOut(duration: 0.07))
                    ))
                }
            }
        }
        .onAppear {
            restoreSelection()
            switcher.attach(to: store)
            commandCenter.attach(to: store)
            // Screenshot/UI-test hook: sandboxed runners can't send ⌘,.
            if ProcessInfo.processInfo.environment["CMUX_OPEN_SETTINGS"] == "1" {
                openWindow(id: SettingsPanel.windowID)
            }
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

/// Entrance for owned modals: fades in from a blur while scaling up.
private struct ModalPopEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.8 + 0.2 * progress)
            .blur(radius: 10 * (1 - progress))
            .opacity(Double(progress))
    }
}

/// Shifts the traffic lights away from the window corner (doubling the stock
/// inset). AppKit resets their frames on titlebar layout, so the offset is
/// reapplied after resizes and fullscreen transitions.
private struct TrafficLightInset: NSViewRepresentable {
    static let extraOffset = CGPoint(x: 7, y: 6)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var window: NSWindow?
        private var defaultOrigins: [NSWindow.ButtonType: CGPoint] = [:]
        private var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.apply()
                    // AppKit may relayout the titlebar after the notification.
                    DispatchQueue.main.async { self?.apply() }
                })
            }
            apply()
        }

        private func apply() {
            guard let window else { return }
            let offset = TrafficLightInset.extraOffset
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type),
                      let superview = button.superview else { continue }
                if defaultOrigins[type] == nil {
                    defaultOrigins[type] = button.frame.origin
                }
                guard let base = defaultOrigins[type] else { continue }
                let dy = superview.isFlipped ? offset.y : -offset.y
                button.setFrameOrigin(CGPoint(x: base.x + offset.x, y: base.y + dy))
            }
        }
    }
}

/// Frosted backdrop that blurs whatever is behind the window.
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
