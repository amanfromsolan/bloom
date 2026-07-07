import AppKit
import Combine
@preconcurrency import Sparkle

/// Drives Sparkle updates with Bloom's own UI instead of Sparkle's dialogs.
///
/// Scheduled checks run in the background (SUEnableAutomaticChecks); when an
/// update exists the sidebar shows ``UpdateCardView`` and every step —
/// download, extract, restart — is user-driven from that card. Sparkle's
/// `SPUUserDriver` is `@MainActor`, so callbacks mutate `phase` directly.
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    enum Phase: Hashable {
        case idle
        /// Manual check in flight (background checks stay invisible until found).
        case checking
        case available(version: String)
        /// `fraction` is nil until the expected content length is known.
        case downloading(fraction: Double?)
        case extracting(fraction: Double)
        case readyToRestart(version: String)
        case installing
        /// Transient confirmation after a manual check finds nothing.
        case upToDate
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle

    let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"

    private var updater: SPUUpdater?
    /// Pending Sparkle replies; the card's buttons consume them.
    private var updateChoice: (@Sendable (SPUUserUpdateChoice) -> Void)?
    private var restartChoice: (@Sendable (SPUUserUpdateChoice) -> Void)?
    private var pendingVersion = ""
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var autoDismiss: Task<Void, Never>?

    func start() {
        guard updater == nil else { return }
        #if DEBUG
        // Day-to-day dev runs never hit the public appcast; opt in with
        // BLOOM_SPARKLE=1 to exercise the real update flow from Xcode.
        guard ProcessInfo.processInfo.environment["BLOOM_SPARKLE"] == "1" else { return }
        #endif
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: nil
        )
        do {
            try updater.start()
            self.updater = updater
        } catch {
            // Never surface startup failures in the card; updates just stay off.
        }
    }

    /// Manual "Check for Updates…" from the menu or command palette.
    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    // MARK: - Card actions

    func installNow() {
        updateChoice?(.install)
        updateChoice = nil
    }

    func restartNow() {
        phase = .installing
        restartChoice?(.install)
        restartChoice = nil
    }

    func dismiss() {
        autoDismiss?.cancel()
        updateChoice?(.dismiss)
        updateChoice = nil
        restartChoice?(.dismiss)
        restartChoice = nil
        phase = .idle
    }

    private func flashUpToDate() {
        phase = .upToDate
        autoDismiss?.cancel()
        autoDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.phase == .upToDate else { return }
            self.phase = .idle
        }
    }
}

// MARK: - SPUUserDriver

extension UpdateController: @preconcurrency SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    ) {
        // Never show Sparkle's permission dialog: scheduled checks on,
        // automatic downloads off so installs stay user-driven.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping @Sendable () -> Void) {
        phase = .checking
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        pendingVersion = appcastItem.displayVersionString
        updateChoice = reply
        phase = .available(version: pendingVersion)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping @Sendable () -> Void
    ) {
        acknowledgement()
        flashUpToDate()
    }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping @Sendable () -> Void
    ) {
        acknowledgement()
        phase = .failed(message: error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping @Sendable () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        phase = .downloading(fraction: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard expectedBytes > 0 else { return }
        phase = .downloading(fraction: min(1, Double(receivedBytes) / Double(expectedBytes)))
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting(fraction: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        phase = .extracting(fraction: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        restartChoice = reply
        phase = .readyToRestart(version: pendingVersion)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping @Sendable () -> Void
    ) {
        phase = .installing
        if !applicationTerminated {
            retryTerminatingApplication()
        }
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping @Sendable () -> Void
    ) {
        acknowledgement()
        phase = .idle
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        updateChoice = nil
        restartChoice = nil
        // Sparkle ends every session through here; keep states the user still
        // needs to read (up-to-date flash, errors) on screen.
        switch phase {
        case .upToDate, .failed, .installing:
            break
        default:
            phase = .idle
        }
    }
}
