import SwiftUI

/// Slim strip above the terminal that doubles as the window titlebar:
/// blends into the terminal background, drags the window, double-click
/// renames. Shows the tab name plus a live breadcrumb of the shell's cwd.
struct TerminalHeaderView: View {
    let session: TerminalSession
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Circle()
                .fill(session.accent.color.opacity(0.8))
                .frame(width: 6, height: 6)

            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)

            breadcrumb

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

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        let trail = PathTrail(path: session.workingDirectory)

        return HStack(spacing: 4) {
            Image(systemName: trail.rootIcon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(trail.segments.isEmpty ? 0.42 : 0.3))

            if let rootLabel = trail.rootLabel {
                Text(rootLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.42))
            }

            ForEach(Array(trail.segments.enumerated()), id: \.offset) { index, segment in
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))

                Text(segment)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(
                        index == trail.segments.count - 1 ? 0.42 : 0.28
                    ))
                    .lineLimit(1)
            }
        }
    }
}

/// Splits an absolute path into a friendly root (home / disk) plus trailing
/// components, collapsing deep paths around an ellipsis.
struct PathTrail {
    let rootIcon: String
    let rootLabel: String?
    let segments: [String]

    init(path: String) {
        let home = NSHomeDirectory()

        if path == home || path == "~" {
            rootIcon = "house.fill"
            rootLabel = "Home"
            segments = []
            return
        }

        var components: [String]
        if path.hasPrefix(home + "/") {
            rootIcon = "house.fill"
            rootLabel = nil
            components = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        } else {
            rootIcon = "internaldrive.fill"
            rootLabel = path == "/" ? "Macintosh HD" : nil
            components = path.split(separator: "/").map(String.init)
        }

        // Deep paths read as noise; keep the last two and hint at the rest.
        if components.count > 3 {
            components = ["…"] + components.suffix(2)
        }
        segments = components
    }
}

#Preview {
    TerminalHeaderView(session: TerminalSessionStore.preview.sessions[0], onRename: {})
        .background(.black)
}
