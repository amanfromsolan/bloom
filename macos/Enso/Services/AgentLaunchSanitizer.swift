import Foundation

/// Filters a recorded agent launch argv down to the options that are safe to
/// replay on restore (ported from cmux's AgentLaunchSanitizer, trimmed to the
/// agents Enso ships). Three tiers per policy:
///
/// - preserved: allowlisted options (with their values) that shape the
///   session — model, permission mode, MCP config — and survive the replay.
/// - dropped: session-selection and one-shot options (--resume, --continue,
///   --session-id, --last, …) that the restore command re-supplies itself;
///   dropping them is what makes a restore-of-a-restore idempotent.
/// - rejected: options that mean the launch was never an interactive session
///   (-p/--print, --no-session-persistence) — the whole restore is abandoned.
///
/// Positional prompts are never replayed: scanning stops at the first
/// non-option token (after the resume subcommand's own id, for codex), and a
/// known non-session subcommand rejects the restore outright.
enum AgentLaunchSanitizer {
    struct Policy {
        /// Options whose next token is a value (consumed together).
        var valueOptions: Set<String>
        /// Options whose value is optional; a following token is consumed
        /// only when it plausibly is one (no leading dash, no whitespace).
        var optionalValueOptions: Set<String> = []
        /// Value options that keep consuming bare tokens until the next dash.
        var variadicOptions: Set<String> = []
        /// Leading subcommands that make the launch non-restorable (nil).
        var nonRestorableCommands: Set<String>
        /// Options removed from the replay (values consumed too).
        var droppedOptions: Set<String>
        /// `=`-joined spellings of dropped options.
        var droppedOptionPrefixes: [String] = []
        /// Options that abandon the entire restore (nil).
        var rejectOptions: Set<String> = []
        /// Subcommand whose own trailing positional (the session id) is
        /// stripped instead of ending the scan — `codex resume <id> …`.
        var resumeSubcommand: String?
    }

    /// claude 2.1.208. cmux-ecosystem flags (--teammate-mode, --tmux,
    /// --remote-control-session-name-prefix) are deliberately absent — they
    /// are not real claude options.
    static let claudePolicy = Policy(
        valueOptions: [
            "--add-dir", "--agent", "--agents", "--allowedTools",
            "--allowed-tools", "--append-system-prompt", "--betas",
            "--debug-file", "--disallowedTools", "--disallowed-tools",
            "--effort", "--fallback-model", "--file", "--from-pr",
            "--input-format", "--json-schema", "--max-budget-usd",
            "--mcp-config", "--model", "-m", "--name", "-n",
            "--output-format", "--permission-mode", "--plugin-dir",
            "--plugin-url", "--resume", "-r", "--session-id",
            "--setting-sources", "--settings", "--system-prompt", "--tools",
            "--worktree", "-w",
        ],
        optionalValueOptions: ["--debug"],
        variadicOptions: [
            "--add-dir", "--allowedTools", "--allowed-tools", "--betas",
            "--disallowedTools", "--disallowed-tools", "--file",
            "--mcp-config", "--tools",
        ],
        nonRestorableCommands: [
            "agents", "auth", "auto-mode", "api-key", "config", "daemon",
            "doctor", "gateway", "install", "mcp", "plugin", "plugins",
            "project", "rc", "remote-control", "setup-token", "ultrareview",
            "update", "upgrade",
        ],
        droppedOptions: [
            "--continue", "-c", "--file", "--fork-session", "--from-pr",
            "--resume", "-r", "--session-id", "--worktree", "-w",
        ],
        droppedOptionPrefixes: [
            "--file=", "--fork-session=", "--from-pr=", "--resume=",
            "--session-id=", "--worktree=",
        ],
        rejectOptions: ["--print", "-p", "--no-session-persistence"]
    )

    /// codex 0.144.1. `exec`/`fork` launches are one-shot shapes and reject;
    /// `resume` strips itself plus its id (the restore re-supplies both).
    static let codexPolicy = Policy(
        valueOptions: [
            "--config", "-c", "--model", "-m", "--profile", "-p", "--cd",
            "-C", "--ask-for-approval", "-a", "--sandbox", "-s", "--remote",
            "--remote-auth-token-env", "--output-last-message", "--enable",
            "--disable", "--image", "-i", "--add-dir", "--local-provider",
        ],
        variadicOptions: ["--image", "-i"],
        nonRestorableCommands: [
            "exec", "e", "review", "login", "logout", "mcp", "plugin",
            "mcp-server", "app-server", "remote-control", "app", "completion",
            "update", "doctor", "sandbox", "debug", "apply", "a", "fork",
            "archive", "delete", "unarchive", "cloud", "exec-server",
            "features", "help",
        ],
        droppedOptions: [
            "--last", "--all", "--image", "-i", "--remote",
            "--remote-auth-token-env",
        ],
        droppedOptionPrefixes: ["--remote=", "--remote-auth-token-env="],
        resumeSubcommand: "resume"
    )

    /// The preserved replay options, or nil when the launch must not be
    /// restored at all (reject option or non-session subcommand).
    static func preservedArguments(_ args: [String], policy: Policy) -> [String]? {
        var result: [String] = []
        var index = 0
        var skippingResumePositional = false

        while index < args.count {
            let arg = args[index]
            if arg == "--" { break }

            if !arg.hasPrefix("-") || arg == "-" {
                if let resume = policy.resumeSubcommand, arg == resume {
                    skippingResumePositional = true
                    index += 1
                    continue
                }
                if skippingResumePositional {
                    skippingResumePositional = false
                    index += 1
                    continue
                }
                if policy.nonRestorableCommands.contains(arg) { return nil }
                // The prompt (and anything after it) is never replayed.
                break
            }

            if matches(arg, options: policy.rejectOptions) { return nil }

            if policy.droppedOptionPrefixes.contains(where: { arg.hasPrefix($0) }) {
                index += 1
                continue
            }

            let width = optionWidth(args, index: index, policy: policy)
            if matches(arg, options: policy.droppedOptions) {
                index += width
                continue
            }

            result.append(contentsOf: args[index..<min(args.count, index + width)])
            index += width
        }

        return result
    }

    /// Whether `arg` is `option` or an `option=value` spelling of it.
    private static func matches(_ arg: String, options: Set<String>) -> Bool {
        if options.contains(arg) { return true }
        guard let equals = arg.firstIndex(of: "=") else { return false }
        return options.contains(String(arg[..<equals]))
    }

    /// Tokens consumed by the option at `index`, including itself.
    private static func optionWidth(_ args: [String], index: Int, policy: Policy) -> Int {
        let arg = args[index]
        if arg.contains("=") { return 1 }
        if policy.optionalValueOptions.contains(arg) {
            guard index + 1 < args.count, looksLikeOptionalValue(args[index + 1]) else { return 1 }
            return 2
        }
        guard policy.valueOptions.contains(arg), index + 1 < args.count else { return 1 }
        if policy.variadicOptions.contains(arg) {
            var end = index + 1
            while end < args.count, !args[end].hasPrefix("-") {
                end += 1
            }
            return max(1, end - index)
        }
        return 2
    }

    private static func looksLikeOptionalValue(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("-")
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// One shell word: tokens made only of safe characters pass through
    /// unquoted, everything else is single-quote wrapped with '\'' escaping
    /// (cmux's shellQuoted). Every replayed token goes through this.
    static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=./:@%"
        )
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
