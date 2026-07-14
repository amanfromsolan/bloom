#!/bin/bash
# Enso hook relay — the command claude/codex lifecycle hooks invoke.
#
# Reads the hook JSON payload from stdin, appends it to the tab's map file
# (ENSO_TAB_ID / ENSO_SESSIONS_DIR are inherited from the terminal), prints
# an empty JSON object, and exits 0. Codex runs hooks synchronously and
# BLOCKS until they return, so this must be instant and can never fail:
# every step is best-effort and the exit code is always 0.

agent="${1:-unknown}"
case "$agent" in
    *[!a-zA-Z0-9_-]*|'') agent=unknown ;;
esac

# Hook payloads are JSON; raw newlines can only be inter-token formatting
# (they are invalid inside JSON strings), so stripping them keeps the
# payload valid while making it a single JSONL-safe line.
payload="$(cat 2>/dev/null | tr -d '\n\r' || true)"

if [[ -n "${ENSO_TAB_ID:-}" && -n "${ENSO_SESSIONS_DIR:-}" && -d "${ENSO_SESSIONS_DIR:-}" ]]; then
    case "$payload" in
        \{*)
            printf '{"v":1,"event":"hook","agent":"%s","payload":%s,"ts":%s}\n' \
                "$agent" \
                "$payload" \
                "$(date +%s 2>/dev/null || printf '0')" \
                >> "${ENSO_SESSIONS_DIR}/${ENSO_TAB_ID}.jsonl" 2>/dev/null || true
            ;;
    esac
fi

printf '%s' '{}'
exit 0
