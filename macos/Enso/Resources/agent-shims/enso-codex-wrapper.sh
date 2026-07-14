#!/bin/bash
# Enso codex wrapper — installed as `codex` in Enso's shim dir.
#
# Codex offers no way to choose a session id upfront, so inside an Enso
# terminal (ENSO_TAB_ID set) this wrapper injects per-invocation hooks
# (`--enable hooks --dangerously-bypass-hook-trust -c hooks.X=...`, nothing
# written to ~/.codex) whose relay reports the real session id to the tab's
# map file in ENSO_SESSIONS_DIR. Only session entrypoints are injected: bare
# `codex`, `codex <prompt>`, `codex exec|e`, `codex resume`, `codex fork`.
# Everything else, and every internal failure, execs the real codex
# untouched — installing this wrapper can never break `codex`.
#
# Contract: no `set -e`/`set -u`, never write to stdout, always end in exec,
# exit 127 with a single stderr line only when no real binary exists.

enso_self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# Resolve the real codex by walking PATH minus our own shim dir; a user's
# own earlier-in-PATH codex wrapper is honored.
enso_find_real() {
    local d candidate
    local IFS=:
    for d in ${PATH:-}; do
        [[ -n "$d" && "$d" != "$enso_self_dir" ]] || continue
        [[ -n "${ENSO_SHIM_DIR:-}" && "$d" == "${ENSO_SHIM_DIR%/}" ]] && continue
        candidate="$d/codex"
        [[ -e "$candidate" && "$candidate" -ef "$0" ]] && continue
        if [[ -f "$candidate" && -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

REAL="$(enso_find_real)" || { echo "enso: codex not found in PATH" >&2; exit 127; }

# Recursion guard: a shim chain that bounces back here stops injecting.
enso_depth="${ENSO_SHIM_DEPTH:-0}"
case "$enso_depth" in ''|*[!0-9]*) enso_depth=0 ;; esac
if [[ "$enso_depth" -ge 3 ]]; then
    exec "$REAL" "$@"
fi
export ENSO_SHIM_DEPTH="$((enso_depth + 1))"

# Passthrough guards: not an Enso tab, opted out, or nowhere to record.
if [[ -z "${ENSO_TAB_ID:-}" || -z "${ENSO_SESSIONS_DIR:-}" || "${ENSO_AGENT_SESSIONS_DISABLED:-}" == "1" ]]; then
    exec "$REAL" "$@"
fi
if [[ ! -d "${ENSO_SESSIONS_DIR}" || ! -w "${ENSO_SESSIONS_DIR}" ]]; then
    exec "$REAL" "$@"
fi
# A codex spawned from INSIDE a running agent (its shell tool inherits this
# environment) must not overwrite the tab's session record with its own.
# ENSO_AGENT_ACTIVE marks sessions our wrappers started; CODEX_SANDBOX marks
# codex's own sandboxed subprocesses.
if [[ -n "${ENSO_AGENT_ACTIVE:-}" || -n "${CODEX_SANDBOX:-}" ]]; then
    exec "$REAL" "$@"
fi

enso_json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# Appends one map event; failures are silently ignored (fail open).
# $3.. is the ORIGINAL user argv (pre-injection), recorded NUL-delimited in
# base64 so the app can replay the launch shape on restore; configDir
# remembers a custom CODEX_HOME so restore resumes against the right rollout
# root. Both are best-effort — an encoding failure records the event without
# them and never blocks the exec.
enso_record() {
    local event="$1" session_id="${2-}"
    shift 2 || true
    local argv_b64=""
    if [[ $# -gt 0 ]]; then
        argv_b64="$( { printf '%s\0' "$@" | base64 | tr -d '\n'; } 2>/dev/null || true)"
    fi
    local config_dir_field=""
    if [[ -n "${CODEX_HOME:-}" ]]; then
        config_dir_field=",\"configDir\":\"$(enso_json_escape "$CODEX_HOME")\""
    fi
    printf '{"v":1,"event":"%s","agent":"codex","sessionId":"%s","cwd":"%s","argvB64":"%s"%s,"ts":%s}\n' \
        "$event" \
        "$(enso_json_escape "$session_id")" \
        "$(enso_json_escape "$PWD")" \
        "$argv_b64" \
        "$config_dir_field" \
        "$(date +%s 2>/dev/null || printf '0')" \
        >> "${ENSO_SESSIONS_DIR}/${ENSO_TAB_ID}.jsonl" 2>/dev/null || true
}

# Global options that take a value, so the scanner never mistakes the value
# for a subcommand (codex 0.144.1).
enso_option_consumes_value() {
    case "$1" in
        -c|--config|-m|--model|-p|--profile|-C|--cd|--remote|\
        -a|--ask-for-approval|-s|--sandbox|--output-last-message|\
        --enable|--disable)
            return 0 ;;
    esac
    return 1
}

# Subcommands that START a codex session and therefore get hook injection.
enso_is_session_subcommand() {
    case "$1" in
        exec|e|resume|fork) return 0 ;;
    esac
    return 1
}

# codex 0.144.1 subcommands that do NOT start a session: plain passthrough.
enso_is_passthrough_subcommand() {
    case "$1" in
        review|login|logout|mcp|plugin|mcp-server|app-server|\
        remote-control|app|completion|update|doctor|sandbox|debug|apply|a|\
        archive|delete|unarchive|cloud|exec-server|features|help)
            return 0 ;;
    esac
    return 1
}

enso_uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# `codex exec --ephemeral` persists nothing, so there is nothing to record
# or restore. Checked up front because the flag follows the subcommand the
# main scanner decides on.
enso_has_ephemeral() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --) return 1 ;;
            --ephemeral) return 0 ;;
        esac
    done
    return 1
}

enso_mode=inject
enso_entry_event=launch
enso_user_session_id=""

# Left-to-right argv scan, stopping at `--`. Bare codex and `codex <prompt>`
# are interactive sessions; exec/e runs one non-interactively; resume/fork
# continue one (record the id, still inject hooks — that is safe and is how
# the resumed session's map entry stays fresh).
enso_scan_args() {
    local -a args=("$@")
    local i=0 arg next
    while [[ $i -lt ${#args[@]} ]]; do
        arg="${args[$i]}"
        case "$arg" in
            --)
                return 0
                ;;
            -h|--help|-V|--version)
                enso_mode=passthrough
                return 0
                ;;
            -*)
                if [[ "$arg" != *=* ]] && enso_option_consumes_value "$arg"; then
                    i=$((i + 2))
                    continue
                fi
                # Unknown option followed by a bare token: that token may be
                # a value we'd misread as a subcommand — fail open.
                if [[ "$arg" != *=* ]]; then
                    next="${args[$((i + 1))]:-}"
                    if [[ -n "$next" && "$next" != -* ]]; then
                        enso_mode=passthrough
                        return 0
                    fi
                fi
                ;;
            *)
                if enso_is_session_subcommand "$arg"; then
                    if [[ "$arg" == "resume" || "$arg" == "fork" ]]; then
                        enso_entry_event=user-session
                        # First UUID-shaped token after the subcommand is the
                        # resumed id; flags and `--last` are not UUID-shaped.
                        local j=$((i + 1))
                        while [[ $j -lt ${#args[@]} ]]; do
                            next="${args[$j]}"
                            [[ "$next" == "--" ]] && break
                            if [[ "$next" =~ $enso_uuid_re ]]; then
                                enso_user_session_id="$next"
                                break
                            fi
                            # `exec resume <id>` keeps scanning; skip flags.
                            j=$((j + 1))
                        done
                    fi
                    return 0
                fi
                if enso_is_passthrough_subcommand "$arg"; then
                    enso_mode=passthrough
                    return 0
                fi
                # First bare token is a prompt -> interactive session.
                return 0
                ;;
        esac
        i=$((i + 1))
    done
    return 0
}

# Hook-support probe, cached per binary (path + mtime + size).
enso_supports_hooks() {
    local stamp cache verdict
    stamp="$(stat -f '%m-%z' "$REAL" 2>/dev/null || true)"
    if [[ -n "$stamp" ]]; then
        cache="${ENSO_SESSIONS_DIR}/.features-codex-$(printf '%s' "$REAL" | cksum 2>/dev/null | tr -c '0-9\n' '-' | tr -d '\n')-${stamp}"
        case "$(cat "$cache" 2>/dev/null)" in
            yes) return 0 ;;
            no) return 1 ;;
        esac
    fi
    verdict=no
    if "$REAL" --help 2>/dev/null | grep -q -- '--dangerously-bypass-hook-trust'; then
        verdict=yes
    fi
    if [[ -n "$stamp" && -n "${cache:-}" ]]; then
        printf '%s' "$verdict" >| "$cache" 2>/dev/null || true
    fi
    [[ "$verdict" == "yes" ]]
}

if enso_has_ephemeral "$@"; then
    exec "$REAL" "$@"
fi

enso_scan_args "$@"

if [[ "$enso_mode" == "passthrough" ]]; then
    exec "$REAL" "$@"
fi

# Everything below starts (or resumes) a session; mark the process tree so
# nested codex runs inside it stay out of the tab's map, and record the
# entry even when hook injection turns out to be unavailable — a resumed
# id is still worth remembering on hook-less codex versions.
export ENSO_AGENT_ACTIVE=1
enso_record "$enso_entry_event" "$enso_user_session_id" "$@"

enso_relay="${ENSO_SHIM_DIR:-$enso_self_dir}/enso-hook-relay"
if [[ ! -x "$enso_relay" ]] || ! enso_supports_hooks; then
    exec "$REAL" "$@"
fi

# TOML ''' literal strings; the relay path is double-quoted inside because
# codex runs the hook command through a shell and the path has spaces. The
# relay answers instantly — codex runs hooks synchronously and BLOCKS on
# them, so anything slower would hang every launch.
enso_hook_cmd="\"$enso_relay\" codex"
exec "$REAL" \
    --enable hooks \
    --dangerously-bypass-hook-trust \
    -c "hooks.SessionStart=[{hooks=[{type=\"command\",command='''$enso_hook_cmd''',timeout=10000}]}]" \
    -c "hooks.Stop=[{hooks=[{type=\"command\",command='''$enso_hook_cmd''',timeout=10000}]}]" \
    "$@"
