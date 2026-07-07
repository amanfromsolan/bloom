import SwiftUI

/// Slim strip above the terminal that doubles as the window titlebar:
/// blends into the terminal background, drags the window, double-click renames.
struct TerminalHeaderView: View {
    let session: TerminalSession
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            Circle()
                .fill(session.accent.color.opacity(0.8))
                .frame(width: 6, height: 6)

            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)

            Text(compactDirectory)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.28))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) {
            onRename()
        }
    }

    private var compactDirectory: String {
        let home = NSHomeDirectory()
        let path = session.workingDirectory
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

#Preview {
    TerminalHeaderView(session: TerminalSessionStore.preview.sessions[0], onRename: {})
        .background(.black)
}
