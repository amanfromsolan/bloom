import Darwin
import Foundation

/// The process-table syscalls the resolver needs, behind a protocol so the
/// pid-walking and candidate-building logic is testable without live
/// processes.
protocol ProcessTableReading {
    /// Direct children of a process.
    func childPIDs(of pid: pid_t) -> [pid_t]
    /// argv as captured at exec time (KERN_PROCARGS2); nil when the process
    /// is gone or macOS hides it (platform binaries, other users' processes).
    func arguments(of pid: pid_t) -> [String]?
    /// One exec-time environment variable; same source and caveats as argv.
    func environmentValue(of pid: pid_t, key: String) -> String?
    /// Foreground process group of the process's controlling terminal —
    /// tcgetpgrp without the pty fd, which libghostty keeps to itself.
    func foregroundProcessGroup(of pid: pid_t) -> pid_t?
    /// Process start time, used to detect pid reuse behind a cache.
    func startTime(of pid: pid_t) -> UInt64?
    /// The kernel's short process name; readable even where argv is not.
    func name(of pid: pid_t) -> String?
}

/// What the resolver found in a session's pty foreground — the input to
/// `TabProcess.detect(after:foreground:)`.
enum ForegroundResolution: Equatable {
    /// The session's shell isn't mapped yet: nothing readable has ever
    /// carried its marker, so the resolver makes no claim either way.
    case unresolved
    /// The foreground process group leader IS the session's own shell —
    /// nothing is running. Decided by pid identity, never by a shell-looking
    /// name, which a wrapper script (`bash ~/bin/cl`) would spoof.
    case idle
    /// The session's shell died (pid gone or recycled), so whatever badge
    /// the tab shows is stale and should clear.
    case shellExited
    /// Something other than the shell holds the foreground; command-name
    /// candidates, best-first. Can be empty when the leader vanished
    /// mid-read.
    case running([String])
}

/// Resolves what is actually running in a session's pty. Shell titles come
/// from preexec with the command *as typed*, so `alias c="claude"` never
/// matches the command table; the pty's foreground process group is ground
/// truth that sees through aliases, wrappers, and scripts.
///
/// libghostty owns the pty and exposes neither its fd nor the shell pid, so
/// every surface is spawned with a per-tab marker in its environment
/// (`ENSO_TAB_ID`, shared with the agent-session shims, which read it but
/// never reassign it — unlike `ENSO_SESSION_ID`, which the claude wrapper
/// overwrites with its own conversation id at every launch). macOS hides
/// the environment of platform binaries
/// like /bin/zsh from KERN_PROCARGS2, so the shell can't be recognized
/// directly — but any third-party foreground process (claude, codex, node…)
/// inherits the marker and is readable. The first such process betrays which
/// shell belongs to the session; from then on the shell is cached and every
/// lookup — including env-opaque platform binaries like vim — resolves via
/// proc_bsdinfo's e_tpgid and proc_name.
@MainActor
final class ForegroundProcessResolver {
    static let shared = ForegroundProcessResolver()

    /// Injected into every surface's environment at spawn (lowercased tab
    /// UUID, matching the agent-shim convention); how a session's processes
    /// are recognized among this app's descendants.
    static let sessionMarkerKey = "ENSO_TAB_ID"

    /// Canonical marker value for a tab: the lowercased UUID (the agent
    /// shims read it in this shape too). The one definition every injector
    /// and lookup shares, so the convention can't drift.
    static func marker(forTab id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// Interpreters whose first non-flag argument is the program actually
    /// running — a node-based CLI like gemini should read as "gemini", not
    /// "node".
    private static let interpreters: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl",
    ]

    /// Shells get the same script-unwrap treatment, but only when the
    /// foreground leader is NOT the session's own shell (identity decides
    /// idle before names are ever read): a shell leading a foreground group
    /// is a wrapper script, and the program it wraps runs as its child.
    private static let shellInterpreters: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash",
    ]

    /// A cached shell, pinned to its start time so a recycled pid can never
    /// impersonate it.
    private struct ShellIdentity {
        let pid: pid_t
        let startTime: UInt64
    }

    private let table: ProcessTableReading

    /// Session marker → shell. A shell lives as long as its surface, so
    /// discovery normally runs once per session.
    private var shells: [String: ShellIdentity] = [:]

    init(table: ProcessTableReading? = nil) {
        self.table = table ?? DarwinProcessTable()
    }

    /// What the session's pty foreground holds right now. Idle vs running
    /// is decided by identity (leader pid == the session's shell pid), not
    /// by name, and a mapping that validation drops is reported as
    /// `.shellExited` — distinct from a session that was never mapped —
    /// so a dead tab's badge can still clear.
    func resolveForeground(forSessionMarker marker: String) -> ForegroundResolution {
        if shells[marker] == nil {
            discoverShells()
            guard let shell = validatedShell(forMarker: marker) else { return .unresolved }
            return resolution(forShell: shell)
        }
        // Previously mapped: losing validation means the tab's shell died
        // (pid gone or recycled), not that the session is merely unknown.
        guard let shell = validatedShell(forMarker: marker) else { return .shellExited }
        return resolution(forShell: shell)
    }

    private func resolution(forShell shell: pid_t) -> ForegroundResolution {
        guard let group = table.foregroundProcessGroup(of: shell) else { return .unresolved }
        if group == shell { return .idle }
        return .running(candidates(forLeader: group))
    }

    /// Command-name candidates for a foreground group leader, best-first:
    /// the script when an interpreter is running one (skipping flags, so
    /// `node --enable-source-maps …/gemini` reads "gemini"), then — when the
    /// leader is a wrapper script's shell — its children's names (the
    /// wrapped program, e.g. claude, runs there and is readable), then the
    /// invoked binary (argv[0] — alias-expanded by the shell, unlike the
    /// title), then the kernel's name as a last resort (Claude Code sets its
    /// proc title to a bare version string, so it can't lead; for platform
    /// binaries with hidden argv it's all there is).
    private func candidates(forLeader group: pid_t) -> [String] {
        var candidates: [String] = []
        if let argv = table.arguments(of: group), let invoked = argv.first {
            let command = Self.commandName(invoked)
            let unwraps = Self.interpreters.contains(command) || Self.shellInterpreters.contains(command)
            if unwraps, let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                candidates.append(Self.commandName(script))
            }
            if Self.shellInterpreters.contains(command) {
                // The leader is a wrapper script (idle was ruled out by pid
                // identity above): walk one level of children for the real
                // program it launched.
                for child in table.childPIDs(of: group) {
                    if let childArgv = table.arguments(of: child), let childInvoked = childArgv.first {
                        candidates.append(Self.commandName(childInvoked))
                    } else if let name = table.name(of: child) {
                        candidates.append(Self.normalized(name))
                    }
                }
            }
            candidates.append(command)
        }
        if let name = table.name(of: group) {
            candidates.append(Self.normalized(name))
        }
        return candidates
    }

    /// The cached shell, dropped when its pid died or was recycled.
    private func validatedShell(forMarker marker: String) -> pid_t? {
        guard let shell = shells[marker] else { return nil }
        guard table.startTime(of: shell.pid) == shell.startTime else {
            shells[marker] = nil
            return nil
        }
        return shell.pid
    }

    /// Walks this app's shells (spawned two levels down on macOS: app →
    /// login(1) → shell) and maps every one whose foreground process carries
    /// a readable session marker. The shell's own environment is checked
    /// first for the rare non-platform shell; /bin/zsh and friends only
    /// become attributable once something third-party runs in them.
    private func discoverShells() {
        let children = table.childPIDs(of: getpid())
        for shell in children + children.flatMap(table.childPIDs(of:)) {
            guard let start = table.startTime(of: shell) else { continue }

            var marker = table.environmentValue(of: shell, key: Self.sessionMarkerKey)
            if marker == nil, let group = table.foregroundProcessGroup(of: shell), group != shell {
                marker = table.environmentValue(of: group, key: Self.sessionMarkerKey)
            }
            guard let marker, shells[marker] == nil else { continue }
            shells[marker] = ShellIdentity(pid: shell, startTime: start)
        }
    }

    /// "/Users/x/.local/bin/claude" → "claude"; "-/bin/zsh" → "zsh".
    private static func commandName(_ argument: String) -> String {
        normalized((argument as NSString).lastPathComponent)
    }

    /// Login shells rewrite argv[0] with a leading dash ("-fish"); strip it
    /// so every candidate matches the command table as written.
    private static func normalized(_ name: String) -> String {
        let lowered = name.lowercased()
        return lowered.hasPrefix("-") ? String(lowered.dropFirst()) : lowered
    }
}

/// The live process table, backed by libproc and sysctl.
struct DarwinProcessTable: ProcessTableReading {
    func childPIDs(of pid: pid_t) -> [pid_t] {
        // First call sizes the buffer; padded a little against races.
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 8)
        let written = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    func arguments(of pid: pid_t) -> [String]? {
        execImage(of: pid)?.arguments
    }

    func environmentValue(of pid: pid_t, key: String) -> String? {
        guard let environment = execImage(of: pid)?.environment else { return nil }
        let prefix = key + "="
        guard let entry = environment.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(entry.dropFirst(prefix.count))
    }

    func foregroundProcessGroup(of pid: pid_t) -> pid_t? {
        guard let info = bsdInfo(of: pid) else { return nil }
        // e_tdev of ~0 means no controlling terminal.
        guard info.e_tdev != UInt32.max, info.e_tpgid > 0 else { return nil }
        return pid_t(info.e_tpgid)
    }

    func startTime(of pid: pid_t) -> UInt64? {
        guard let info = bsdInfo(of: pid) else { return nil }
        return info.pbi_start_tvsec << 32 | info.pbi_start_tvusec
    }

    func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, &info, size) == size else { return nil }
        return info
    }

    /// KERN_PROCARGS2: an argc word, the exec path, null padding, then argv
    /// and the exec-time environment as consecutive C strings. macOS omits
    /// the environment entirely for platform binaries (/bin/zsh comes back
    /// argv-only), which is why shells are discovered through their
    /// foreground process rather than directly.
    private func execImage(of pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        var argc = Int32(0)
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer.prefix(MemoryLayout<Int32>.size)) }
        var offset = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard offset < size else { return nil }
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            let string = String(decoding: buffer[start..<offset], as: UTF8.self)
            offset += 1
            return string
        }

        guard nextString() != nil else { return nil } // exec path
        while offset < size, buffer[offset] == 0 { offset += 1 } // padding

        var arguments: [String] = []
        for _ in 0..<max(0, argc) {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }
        // Shells rewrite their argv in place as a process title ("-/bin/zsh"),
        // leaving a gap of nulls before the untouched environment strings.
        while offset < size, buffer[offset] == 0 { offset += 1 }
        var environment: [String] = []
        while let entry = nextString(), !entry.isEmpty {
            environment.append(entry)
        }
        return (arguments, environment)
    }
}
