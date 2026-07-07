import SwiftUI

/// Subtle update card pinned above the space indicators at the bottom of the
/// sidebar. Appears only when there is something to say (update found, manual
/// check feedback, progress, restart prompt) and walks the whole flow inline:
/// available → downloading → ready to restart.
struct UpdateCardView: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        ZStack {
            if controller.phase != .idle {
                UpdateCardBody(
                    phase: controller.phase,
                    onInstall: { controller.installNow() },
                    onRestart: { controller.restartNow() },
                    onRetry: { controller.checkForUpdates() },
                    onDismiss: { controller.dismiss() }
                )
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.12), value: controller.phase)
    }
}

private struct UpdateCardBody: View {
    let phase: UpdateController.Phase
    let onInstall: () -> Void
    let onRestart: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @State private var closeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                trailing
            }

            if let fraction = progressFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07))
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Per-phase content

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .checking, .installing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        case .available, .downloading, .extracting:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.9))
        case .readyToRestart:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.9))
        case .upToDate:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange.opacity(0.8))
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch phase {
        case .idle: ""
        case .checking: "Checking for updates…"
        case .available: "Update available"
        case .downloading: "Downloading update…"
        case .extracting: "Preparing update…"
        case .readyToRestart: "Ready to install"
        case .installing: "Installing…"
        case .upToDate: "You're up to date"
        case .failed: "Update failed"
        }
    }

    private var subtitle: String? {
        switch phase {
        case .available(let version), .readyToRestart(let version):
            "Bloom \(version)"
        case .failed(let message):
            message
        default:
            nil
        }
    }

    private var progressFraction: Double? {
        switch phase {
        case .downloading(let fraction): fraction ?? 0
        case .extracting(let fraction): fraction
        default: nil
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .available:
            HStack(spacing: 6) {
                CardActionButton(label: "Update", action: onInstall)
                closeButton
            }
        case .readyToRestart:
            HStack(spacing: 6) {
                CardActionButton(label: "Restart", action: onRestart)
                closeButton
            }
        case .failed:
            HStack(spacing: 6) {
                CardActionButton(label: "Retry", action: onRetry)
                closeButton
            }
        case .upToDate:
            closeButton
        default:
            EmptyView()
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(closeHovered ? 0.7 : 0.3))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(closeHovered ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { closeHovered = $0 }
        .help("Dismiss")
    }
}

private struct CardActionButton: View {
    let label: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.accentColor.opacity(hovered ? 1 : 0.8))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

#Preview("States", traits: .fixedLayout(width: 248, height: 420)) {
    VStack(spacing: 12) {
        ForEach(
            [
                UpdateController.Phase.checking,
                .available(version: "0.4.0"),
                .downloading(fraction: 0.62),
                .extracting(fraction: 0.3),
                .readyToRestart(version: "0.4.0"),
                .installing,
                .upToDate,
                .failed(message: "The update could not be verified."),
            ],
            id: \.self
        ) { phase in
            UpdateCardBody(
                phase: phase,
                onInstall: {},
                onRestart: {},
                onRetry: {},
                onDismiss: {}
            )
        }
    }
    .padding(.vertical)
    .frame(width: 248)
    .background(Color(red: 0.09, green: 0.09, blue: 0.11))
}
