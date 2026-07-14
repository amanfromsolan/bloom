import Darwin
import Testing
@testable import Enso

/// TabProcess.detect turns shell-integration title events into the sidebar's
/// per-tab process badge. Titles come in three shapes — a preexec command
/// line, an idle prompt (shell name or cwd), and a foreign title an app set
/// itself — and the badge is only trustworthy if commands match, every idle
/// prompt shape clears, and an agent's own retitling keeps its icon alive.
@MainActor
struct TabProcessTests {
    // MARK: - Command lines (shell preexec)

    @Test func commandLineDetectsAgent() {
        #expect(TabProcess.detect(after: nil, title: "claude --continue") == .claude)
        #expect(TabProcess.detect(after: nil, title: "codex resume abc123") == .codex)
        #expect(TabProcess.detect(after: nil, title: "opencode") == .opencode)
    }

    /// Every agent renders through the adaptive-artwork badge so the
    /// sidebar and header can pick the size/tint variant themselves.
    @Test func agentsCarryTheirAssetBaseName() {
        #expect(TabProcess.claude.badge == .agent("AgentClaude"))
        #expect(TabProcess.opencode.badge == .agent("AgentOpenCode"))
    }

    @Test func commandPathsResolveToTheirBasename() {
        #expect(TabProcess.detect(after: nil, title: "/opt/homebrew/bin/claude") == .claude)
        #expect(TabProcess.detect(after: nil, title: "~/bin/nvim notes.md") == .editor)
    }

    @Test func newCommandReplacesPreviousDetection() {
        #expect(TabProcess.detect(after: .claude, title: "htop") == .monitor)
    }

    @Test func unknownCommandKeepsCurrentDetection() {
        // An unrecognized non-path word is indistinguishable from a foreign
        // title, so the current detection survives.
        #expect(TabProcess.detect(after: .editor, title: "frobnicate --all") == .editor)
    }

    @Test func aliasedCommandIsInvisibleToTitleDetection() {
        // The gap the foreground resolver exists to close: preexec reports
        // the alias as typed, so the table can never match it.
        #expect(TabProcess.detect(after: nil, title: "c --continue") == nil)
    }

    // MARK: - Idle prompts (issue #34: the badge used to latch here)

    /// Shell integration reports the cwd as the idle title: zsh prints "~",
    /// "~/a/b", "/x/y", or "…/a/b/c" for deep paths; bash uses \w. Every
    /// shape must clear the badge — before #34 only bare "~" and absolute
    /// paths did, so any tab whose cwd lived under home kept a stale icon.
    @Test(arguments: [
        "~",
        "~/dev/enso",
        "/etc",
        "/Users/dev/project",
        "…/dev-projects/enso/macos",
        "…",
    ])
    func idlePromptClearsDetection(title: String) {
        #expect(TabProcess.detect(after: .claude, title: title) == nil)
    }

    @Test func idleShellNameClearsDetection() {
        #expect(TabProcess.detect(after: .codex, title: "zsh") == nil)
        #expect(TabProcess.detect(after: .codex, title: "-zsh") == nil)
        #expect(TabProcess.detect(after: .git, title: "fish") == nil)
    }

    /// Login shells rewrite argv[0] with a leading dash, and some shells
    /// report that as the idle title ("-fish"). Normalization must strip it
    /// before the idle-shell lookup, for every shell — not just the two
    /// dashed names the old set happened to list.
    @Test(arguments: ["-fish", "-bash", "-sh", "dash", "ksh", "tcsh"])
    func loginShellTitleClearsDetection(title: String) {
        #expect(TabProcess.detect(after: .claude, title: title) == nil)
    }

    // MARK: - Foreign titles (apps retitling themselves)

    /// Claude Code retitles constantly while running; those foreign titles
    /// must keep the badge alive until the shell prompts again.
    @Test func foreignTitleKeepsCurrentDetection() {
        #expect(TabProcess.detect(after: .claude, title: "✳ Fixing the sidebar badge") == .claude)
    }

    @Test func foreignTitleAloneDetectsNothing() {
        #expect(TabProcess.detect(after: nil, title: "✳ Some agent status") == nil)
    }

    // MARK: - Lifecycle

    /// The whole point of the badge: launch, retitle, exit, next command —
    /// the icon follows the foreground process the entire way.
    @Test func badgeTracksTheForegroundProcessAcrossALifecycle() {
        var process: TabProcess?
        process = TabProcess.detect(after: process, title: "~/dev/enso") // fresh prompt
        #expect(process == nil)
        process = TabProcess.detect(after: process, title: "claude") // preexec
        #expect(process == .claude)
        process = TabProcess.detect(after: process, title: "✳ Reticulating splines") // agent retitle
        #expect(process == .claude)
        process = TabProcess.detect(after: process, title: "~/dev/enso") // agent exited
        #expect(process == nil)
        process = TabProcess.detect(after: process, title: "htop") // next command
        #expect(process == .monitor)
    }
}

/// The foreground path takes the resolver's identity-based resolution, not
/// raw names: `.idle`/`.shellExited` clear unconditionally, `.running`
/// walks the table best-first, `.unresolved` makes no claim.
struct TabProcessForegroundDetectionTests {
    @Test func firstTableHitWins() {
        #expect(TabProcess.detect(after: nil, foreground: .running(["claude", "2.1.209"])) == .claude)
        #expect(TabProcess.detect(after: .claude, foreground: .running(["ssh"])) == .remote)
    }

    @Test func identityBasedIdleClears() {
        // "Idle" is the resolver's explicit leader-pid == shell-pid signal,
        // never inferred from a shell-looking candidate name.
        #expect(TabProcess.detect(after: .claude, foreground: .idle) == nil)
    }

    @Test func deadShellClears() {
        // A tab whose shell died can never prompt again; its badge must not
        // survive the shell (previously the empty-candidates bail latched it).
        #expect(TabProcess.detect(after: .claude, foreground: .shellExited) == nil)
    }

    @Test func shellNamedCandidatesDoNotClear() {
        // A non-exec wrapper script (`bash ~/bin/cl` running claude) makes
        // bash the foreground group leader. Shell names used to hit
        // idleShells and clear a live badge; with idle decided by identity,
        // they walk the table like any other candidate.
        #expect(TabProcess.detect(after: .claude, foreground: .running(["cl", "claude", "bash", "bash"])) == .claude)
        #expect(TabProcess.detect(after: .claude, foreground: .running(["cl", "mytool", "bash", "bash"])) == .unknown)
    }

    @Test func dashPrefixedCandidatesAreNormalizedForTheTable() {
        // Login shells rewrite argv[0] with a leading dash; any candidate
        // reaching detect un-stripped must still match the table.
        #expect(TabProcess.detect(after: nil, foreground: .running(["-ssh"])) == .remote)
    }

    @Test func unknownForegroundReplacesStaleBadge() {
        // Changed behavior: foreground data is authoritative, unlike
        // foreign titles. If the live non-shell foreground misses the
        // table, the old table badge is stale by definition — show the
        // running dot instead of keeping it. (A running claude is safe:
        // its argv[0] stays "claude" and wins before the "2.1.209" proc
        // title is ever consulted.)
        #expect(TabProcess.detect(after: .claude, foreground: .running(["2.1.209"])) == .unknown)
    }

    @Test func unknownForegroundFromCleanSlateShowsRunningDot() {
        // A live non-shell process with no artwork still deserves the
        // running-blue dot instead of reading as idle.
        #expect(TabProcess.detect(after: nil, foreground: .running(["mytool"])) == .unknown)
        #expect(TabProcess.unknown.badge == .dot)
    }

    @Test func unresolvedKeepsCurrent() {
        // A session the resolver never mapped carries no evidence either way.
        #expect(TabProcess.detect(after: .git, foreground: .unresolved) == .git)
        #expect(TabProcess.detect(after: nil, foreground: .unresolved) == nil)
    }

    @Test func runningWithoutNamesKeepsCurrent() {
        // The leader vanished between reads: something ran, but there is no
        // name evidence against the current badge.
        #expect(TabProcess.detect(after: .git, foreground: .running([])) == .git)
    }
}

/// Canned process tree standing in for libproc/sysctl, so the resolver's
/// pid walking and candidate building run against known processes.
private final class FakeProcessTable: ProcessTableReading {
    var children: [pid_t: [pid_t]] = [:]
    var argvs: [pid_t: [String]] = [:]
    var environments: [pid_t: [String: String]] = [:]
    var foregroundGroups: [pid_t: pid_t] = [:]
    var startTimes: [pid_t: UInt64] = [:]
    var names: [pid_t: String] = [:]

    func childPIDs(of pid: pid_t) -> [pid_t] { children[pid] ?? [] }
    func arguments(of pid: pid_t) -> [String]? { argvs[pid] }
    func environmentValue(of pid: pid_t, key: String) -> String? { environments[pid]?[key] }
    func foregroundProcessGroup(of pid: pid_t) -> pid_t? { foregroundGroups[pid] }
    func startTime(of pid: pid_t) -> UInt64? { startTimes[pid] }
    func name(of pid: pid_t) -> String? { names[pid] }
}

@MainActor
struct ForegroundProcessResolverTests {
    private let marker = "test-session-marker"
    private let table = FakeProcessTable()

    /// The tree libghostty builds on macOS: app → login(1) → shell. login
    /// runs as root and /bin/zsh is a platform binary, so both read as
    /// argv/env-opaque — exactly like production. Only the shell's bsdinfo
    /// (start time, foreground group) and name are visible.
    private func installShell(pid shell: pid_t) {
        let app = getpid()
        let login: pid_t = 900
        table.children[app] = [login]
        table.children[login] = [shell]
        table.startTimes[shell] = 1_000
        table.names[shell] = "zsh"
    }

    /// A third-party foreground process: argv, env, and name all readable.
    private func installForeground(pid: pid_t, shell: pid_t, argv: [String], name: String) {
        table.foregroundGroups[shell] = pid
        table.argvs[pid] = argv
        table.environments[pid] = [ForegroundProcessResolver.sessionMarkerKey: marker]
        table.names[pid] = name
    }

    @Test func aliasedClaudeResolvesFromArgvNotProcName() {
        // Claude Code sets its proc title to a bare version string; the
        // shell-expanded argv[0] is what identifies it.
        installShell(pid: 901)
        installForeground(
            pid: 902,
            shell: 901,
            argv: ["/Users/me/.local/bin/claude", "--continue"],
            name: "2.1.209"
        )

        let resolver = ForegroundProcessResolver(table: table)
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .running(["claude", "2.1.209"]))
        #expect(TabProcess.detect(after: nil, foreground: resolution) == .claude)
    }

    @Test func interpreterRunningScriptLeadsWithScriptName() {
        // Node-based CLIs (gemini) should read as the script, not "node".
        installShell(pid: 901)
        installForeground(
            pid: 902,
            shell: 901,
            argv: ["node", "/opt/homebrew/bin/gemini"],
            name: "node"
        )

        let resolver = ForegroundProcessResolver(table: table)
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .running(["gemini", "node", "node"]))
        #expect(TabProcess.detect(after: nil, foreground: resolution) == .gemini)
    }

    @Test func interpreterFlagsAreSkippedWhenFindingTheScript() {
        // `node --enable-source-maps /opt/…/gemini` must read "gemini",
        // not "--enable-source-maps".
        installShell(pid: 901)
        installForeground(
            pid: 902,
            shell: 901,
            argv: ["node", "--enable-source-maps", "/opt/homebrew/bin/gemini"],
            name: "node"
        )

        let resolver = ForegroundProcessResolver(table: table)
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .running(["gemini", "node", "node"]))
    }

    @Test func interpreterWithOnlyFlagsFallsBackToItsOwnName() {
        // A REPL launched with flags (`node --experimental-repl-await`)
        // has no script to surface; the interpreter itself is the answer.
        installShell(pid: 901)
        installForeground(
            pid: 902,
            shell: 901,
            argv: ["node", "--experimental-repl-await"],
            name: "node"
        )

        let resolver = ForegroundProcessResolver(table: table)
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .running(["node", "node"]))
        #expect(TabProcess.detect(after: nil, foreground: resolution) == .runtime)
    }

    @Test func wrapperScriptSurfacesScriptAndWrappedChild() {
        // A non-exec wrapper (`~/bin/cl` containing `claude "$@"`) makes
        // bash the foreground group leader while claude runs as its child.
        // The resolver must surface the script name and walk one level of
        // children — never report the wrapper's shell as idle.
        installShell(pid: 901)
        installForeground(
            pid: 910,
            shell: 901,
            argv: ["bash", "/Users/me/bin/cl", "--continue"],
            name: "bash"
        )
        table.children[910] = [911]
        table.argvs[911] = ["/Users/me/.local/bin/claude", "--continue"]
        table.names[911] = "2.1.209"

        let resolver = ForegroundProcessResolver(table: table)
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .running(["cl", "claude", "bash", "bash"]))
        #expect(TabProcess.detect(after: nil, foreground: resolution) == .claude)
    }

    @Test func wrapperScriptChildWithHiddenArgvUsesProcName() {
        // The wrapped program can be a platform binary (argv-opaque); the
        // kernel's proc_name still identifies it.
        installShell(pid: 901)
        installForeground(pid: 910, shell: 901, argv: ["zsh", "/Users/me/bin/v"], name: "zsh")
        table.children[910] = [911]
        table.names[911] = "vim"

        let resolver = ForegroundProcessResolver(table: table)
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .running(["v", "vim", "zsh", "zsh"]))
        #expect(TabProcess.detect(after: nil, foreground: resolution) == .editor)
    }

    @Test func loginShellArgvIsNormalizedBeforeUnwrapping() {
        // argv[0] can carry the login-shell dash ("-bash"); it must still
        // be recognized as a shell interpreter so the script is surfaced.
        installShell(pid: 901)
        installForeground(pid: 910, shell: 901, argv: ["-bash", "/Users/me/bin/cl"], name: "bash")
        table.children[910] = [911]
        table.argvs[911] = ["/Users/me/.local/bin/claude"]

        let resolver = ForegroundProcessResolver(table: table)
        #expect(resolver.resolveForeground(forSessionMarker: marker)
            == .running(["cl", "claude", "bash", "bash"]))
    }

    @Test func platformBinaryResolvesByNameOnceShellIsKnown() {
        // vim's argv/env are hidden, but after any marker-carrying process
        // has mapped the shell, proc_name alone identifies later commands.
        installShell(pid: 901)
        installForeground(pid: 902, shell: 901, argv: ["/Users/me/.local/bin/claude"], name: "2.1.209")
        let resolver = ForegroundProcessResolver(table: table)
        #expect(resolver.resolveForeground(forSessionMarker: marker) == .running(["claude", "2.1.209"]))

        // claude exits; the user opens vim (platform binary, env-opaque).
        table.foregroundGroups[901] = 903
        table.names[903] = "vim"
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .running(["vim"]))
        #expect(TabProcess.detect(after: .claude, foreground: resolution) == .editor)
    }

    @Test func shellAsItsOwnForegroundGroupIsIdle() {
        // Idle is identity, not name: the resolver reports .idle when the
        // foreground leader IS the session's shell pid (changed from
        // returning the shell's name for TabProcess to string-match).
        installShell(pid: 901)
        installForeground(pid: 902, shell: 901, argv: ["/Users/me/.local/bin/claude"], name: "2.1.209")
        let resolver = ForegroundProcessResolver(table: table)
        #expect(resolver.resolveForeground(forSessionMarker: marker) == .running(["claude", "2.1.209"]))

        // Back at the prompt: the shell itself is the foreground group.
        table.foregroundGroups[901] = 901
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .idle)
        #expect(TabProcess.detect(after: .claude, foreground: resolution) == nil)
    }

    @Test func unmappedShellIsUnresolved() {
        // Idle from birth: nothing readable ever carried the marker, so the
        // session stays unmapped and the resolver makes no claim.
        installShell(pid: 901)
        table.foregroundGroups[901] = 901
        let resolver = ForegroundProcessResolver(table: table)
        #expect(resolver.resolveForeground(forSessionMarker: marker) == .unresolved)
    }

    @Test func nonPlatformShellMapsFromItsOwnEnvironment() {
        // A homebrew fish exposes its environment directly; mapping must
        // not wait for a foreground process. At its own prompt it reads
        // .idle (identity match) — proof the mapping landed, since an
        // unmapped session would be .unresolved.
        installShell(pid: 901)
        table.names[901] = "fish"
        table.environments[901] = [ForegroundProcessResolver.sessionMarkerKey: marker]
        table.foregroundGroups[901] = 901
        let resolver = ForegroundProcessResolver(table: table)
        #expect(resolver.resolveForeground(forSessionMarker: marker) == .idle)
    }

    @Test func recycledShellPidReportsShellExited() {
        // The cache pins the shell to its start time; a recycled pid with a
        // different start time must not answer for the dead session — and
        // the death itself must be reported so the tab's badge can clear
        // (changed from an indistinct empty answer).
        installShell(pid: 901)
        installForeground(pid: 902, shell: 901, argv: ["/Users/me/.local/bin/claude"], name: "2.1.209")
        let resolver = ForegroundProcessResolver(table: table)
        #expect(resolver.resolveForeground(forSessionMarker: marker) == .running(["claude", "2.1.209"]))

        // The shell dies; an unrelated process is born with the same pid.
        table.startTimes[901] = 2_000
        table.environments[902] = nil
        table.foregroundGroups[901] = 904
        table.names[904] = "htop"
        let resolution = resolver.resolveForeground(forSessionMarker: marker)
        #expect(resolution == .shellExited)
        #expect(TabProcess.detect(after: .claude, foreground: resolution) == nil)

        // Once dropped, the session is back to unmapped: no false claims.
        #expect(resolver.resolveForeground(forSessionMarker: marker) == .unresolved)
    }

    @Test func deadShellPidReportsShellExited() {
        // Same as recycling, but the pid is simply gone.
        installShell(pid: 901)
        installForeground(pid: 902, shell: 901, argv: ["/Users/me/.local/bin/claude"], name: "2.1.209")
        let resolver = ForegroundProcessResolver(table: table)
        #expect(resolver.resolveForeground(forSessionMarker: marker) == .running(["claude", "2.1.209"]))

        table.startTimes[901] = nil
        table.environments[902] = nil
        #expect(resolver.resolveForeground(forSessionMarker: marker) == .shellExited)
    }
}
