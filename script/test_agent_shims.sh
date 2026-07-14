#!/usr/bin/env bash
# Smoke tests for the Enso agent shims (macos/Enso/Resources/agent-shims).
# Uses FAKE claude/codex binaries only — the real CLIs are never invoked.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM_SRC="$ROOT/macos/Enso/Resources/agent-shims"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILED=1; }

check() { # check <description> <condition...>
    local desc="$1"
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# --- fixture layout -------------------------------------------------------

SHIM_BIN="$TMP/shims/bin"
SESSIONS="$TMP/sessions"
FAKE_BIN="$TMP/fakebin"
OUT="$TMP/out"
mkdir -p "$SHIM_BIN" "$SESSIONS" "$FAKE_BIN" "$OUT"

cp "$SHIM_SRC/enso-claude-wrapper.sh" "$SHIM_BIN/claude"
cp "$SHIM_SRC/enso-codex-wrapper.sh" "$SHIM_BIN/codex"
cp "$SHIM_SRC/enso-hook-relay.sh" "$SHIM_BIN/enso-hook-relay"
chmod 755 "$SHIM_BIN/claude" "$SHIM_BIN/codex" "$SHIM_BIN/enso-hook-relay"

# Fake claude: --help advertises the features the wrapper probes for; any
# other invocation dumps argv (one arg per line) to FAKE_ARGV_FILE.
cat > "$FAKE_BIN/claude" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: claude [options] [prompt]"
    echo "  --session-id <uuid>   use a specific session id"
    echo "  --settings <json>     inline settings"
    exit 0
fi
: > "${FAKE_ARGV_FILE:?}"
for arg in "$@"; do printf '%s\n' "$arg" >> "$FAKE_ARGV_FILE"; done
printf '%s\n' "${ENSO_AGENT_ACTIVE:-}" > "$FAKE_ARGV_FILE.env"
exit 0
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: codex [options] [prompt]"
    echo "  --enable <feature>                enable a feature"
    echo "  --dangerously-bypass-hook-trust   trust hooks from all sources"
    exit 0
fi
: > "${FAKE_ARGV_FILE:?}"
for arg in "$@"; do printf '%s\n' "$arg" >> "$FAKE_ARGV_FILE"; done
exit 0
EOF
chmod 755 "$FAKE_BIN/claude" "$FAKE_BIN/codex"

TAB_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
MAP_FILE="$SESSIONS/$TAB_ID.jsonl"
BASE_PATH="$SHIM_BIN:$FAKE_BIN:/usr/bin:/bin"

# The suite itself may run inside an agent (CLAUDECODE etc. ambient), which
# would trip the wrappers' nested-run guard; every invocation scrubs those.
SCRUB=(-u CLAUDECODE -u CODEX_SANDBOX -u ENSO_AGENT_ACTIVE -u ENSO_SHIM_DEPTH)

# run <wrapper-name> <argv-file> [args...]; stdout/stderr captured in $OUT.
run() {
    local wrapper="$1" argv_file="$2"
    shift 2
    env "${SCRUB[@]}" PATH="$BASE_PATH" \
        ENSO_TAB_ID="$TAB_ID" \
        ENSO_SHIM_DIR="$SHIM_BIN" \
        ENSO_SESSIONS_DIR="$SESSIONS" \
        FAKE_ARGV_FILE="$argv_file" \
        "$SHIM_BIN/$wrapper" "$@" > "$OUT/stdout" 2> "$OUT/stderr"
}

argv_line() { sed -n "${2}p" "$1"; }
argv_count() { wc -l < "$1" | tr -d ' '; }
stdout_empty() { [[ ! -s "$OUT/stdout" ]]; }
map_lines() { [[ -f "$MAP_FILE" ]] && wc -l < "$MAP_FILE" | tr -d ' ' || echo 0; }

json_valid_map() {
    [[ -f "$MAP_FILE" ]] || return 1
    python3 - "$MAP_FILE" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        json.loads(line)
EOF
}

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# --- claude: session-id + settings injection ------------------------------

run claude "$OUT/argv1" "write me a haiku"
check "claude injection: wrapper exit 0" test $? -eq 0
check "claude injection: stdout empty" stdout_empty
check "claude injection: --session-id first" test "$(argv_line "$OUT/argv1" 1)" = "--session-id"
INJECTED_ID="$(argv_line "$OUT/argv1" 2)"
check "claude injection: fresh lowercase uuid" grep -qE "$UUID_RE" <<<"$INJECTED_ID"
check "claude injection: --settings third" test "$(argv_line "$OUT/argv1" 3)" = "--settings"
SETTINGS_JSON="$(argv_line "$OUT/argv1" 4)"
check "claude injection: settings is valid JSON with our hooks" \
    python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert "SessionStart" in s["hooks"] and "SessionEnd" in s["hooks"]' "$SETTINGS_JSON"
check "claude injection: prompt preserved" test "$(argv_line "$OUT/argv1" 5)" = "write me a haiku"
check "claude injection: map file lines valid JSON" json_valid_map
check "claude injection: launch event recorded with injected id" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
assert any(e["event"] == "launch" and e["agent"] == "claude" and e["sessionId"] == sys.argv[2] for e in events)
' "$MAP_FILE" "$INJECTED_ID"

# A second launch must mint a DIFFERENT id (never a stable tab-derived one).
run claude "$OUT/argv1b" "again"
check "claude injection: fresh id per launch" test "$(argv_line "$OUT/argv1b" 2)" != "$INJECTED_ID"

# --- claude: user --resume passthrough ------------------------------------

BEFORE=$(map_lines)
run claude "$OUT/argv2" --resume abc-123
check "claude --resume: stdout empty" stdout_empty
check "claude --resume: argv untouched" \
    test "$(argv_count "$OUT/argv2")" = "2" -a "$(argv_line "$OUT/argv2" 1)" = "--resume" -a "$(argv_line "$OUT/argv2" 2)" = "abc-123"
check "claude --resume: user-session recorded" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
assert events[-1]["event"] == "user-session" and events[-1]["sessionId"] == "abc-123"
' "$MAP_FILE"
check "claude --resume: exactly one new map line" test "$(map_lines)" = "$((BEFORE + 1))"

# --continue must also suppress injection.
run claude "$OUT/argv2b" --continue
check "claude --continue: argv untouched" \
    test "$(argv_count "$OUT/argv2b")" = "1" -a "$(argv_line "$OUT/argv2b" 1)" = "--continue"

# --- claude: subcommand passthrough ---------------------------------------

BEFORE=$(map_lines)
run claude "$OUT/argv3" mcp list
check "claude mcp list: stdout empty" stdout_empty
check "claude mcp list: argv untouched" \
    test "$(argv_count "$OUT/argv3")" = "2" -a "$(argv_line "$OUT/argv3" 1)" = "mcp" -a "$(argv_line "$OUT/argv3" 2)" = "list"
check "claude mcp list: nothing recorded" test "$(map_lines)" = "$BEFORE"

# --- claude: user --settings collision ------------------------------------

run claude "$OUT/argv4" --settings '{"x":1}' "hi"
check "claude settings collision: stdout empty" stdout_empty
check "claude settings collision: session id still injected" \
    test "$(argv_line "$OUT/argv4" 1)" = "--session-id"
check "claude settings collision: exactly one --settings (the user's)" \
    test "$(grep -cx -- '--settings' "$OUT/argv4")" = "1"
check "claude settings collision: user settings value preserved" grep -qxF '{"x":1}' "$OUT/argv4"
check "claude settings collision: our hooks JSON absent" bash -c "! grep -q SessionStart '$OUT/argv4'"

# --- claude: recursion guard ----------------------------------------------

BEFORE=$(map_lines)
env PATH="$BASE_PATH" ENSO_TAB_ID="$TAB_ID" ENSO_SHIM_DIR="$SHIM_BIN" \
    ENSO_SESSIONS_DIR="$SESSIONS" ENSO_SHIM_DEPTH=3 FAKE_ARGV_FILE="$OUT/argv5" \
    "$SHIM_BIN/claude" "hi" > "$OUT/stdout" 2> "$OUT/stderr"
check "claude depth cap: stdout empty" stdout_empty
check "claude depth cap: plain passthrough" \
    test "$(argv_count "$OUT/argv5")" = "1" -a "$(argv_line "$OUT/argv5" 1)" = "hi"
check "claude depth cap: nothing recorded" test "$(map_lines)" = "$BEFORE"

# --- claude: inert without ENSO env ---------------------------------------

env PATH="$BASE_PATH" FAKE_ARGV_FILE="$OUT/argv6" \
    "$SHIM_BIN/claude" "hi" > "$OUT/stdout" 2> "$OUT/stderr"
check "claude no-env: stdout empty" stdout_empty
check "claude no-env: plain passthrough" \
    test "$(argv_count "$OUT/argv6")" = "1" -a "$(argv_line "$OUT/argv6" 1)" = "hi"

# --- claude: missing real binary ------------------------------------------

env "${SCRUB[@]}" PATH="$SHIM_BIN:/usr/bin:/bin" ENSO_TAB_ID="$TAB_ID" ENSO_SHIM_DIR="$SHIM_BIN" \
    ENSO_SESSIONS_DIR="$SESSIONS" \
    "$SHIM_BIN/claude" "hi" > "$OUT/stdout" 2> "$OUT/stderr"
STATUS=$?
check "claude missing binary: exit 127" test "$STATUS" = "127"
check "claude missing binary: stderr one-liner" test -s "$OUT/stderr"
check "claude missing binary: stdout empty" stdout_empty

# --- hook relay ------------------------------------------------------------

BEFORE=$(map_lines)
printf '{"hook_event_name":"SessionStart","session_id":"feed-1","cwd":"/tmp"}' \
    | env ENSO_TAB_ID="$TAB_ID" ENSO_SESSIONS_DIR="$SESSIONS" \
        "$SHIM_BIN/enso-hook-relay" claude > "$OUT/stdout" 2> "$OUT/stderr"
check "relay: exit 0" test $? -eq 0
check "relay: stdout is {}" test "$(cat "$OUT/stdout")" = "{}"
check "relay: hook event appended and valid" json_valid_map
check "relay: payload embedded intact" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
last = events[-1]
assert last["event"] == "hook" and last["agent"] == "claude"
assert last["payload"]["session_id"] == "feed-1"
' "$MAP_FILE"
check "relay: exactly one new map line" test "$(map_lines)" = "$((BEFORE + 1))"

# Relay without env must still answer {} instantly and record nothing.
BEFORE=$(map_lines)
printf '{"x":1}' | "$SHIM_BIN/enso-hook-relay" claude > "$OUT/stdout" 2> "$OUT/stderr"
check "relay no-env: stdout is {}" test "$(cat "$OUT/stdout")" = "{}"
check "relay no-env: nothing recorded" test "$(map_lines)" = "$BEFORE"

# --- codex: hook injection for session entrypoints -------------------------

run codex "$OUT/argv7"
check "codex bare: stdout empty" stdout_empty
check "codex bare: --enable hooks first" \
    test "$(argv_line "$OUT/argv7" 1)" = "--enable" -a "$(argv_line "$OUT/argv7" 2)" = "hooks"
check "codex bare: bypass-hook-trust third" \
    test "$(argv_line "$OUT/argv7" 3)" = "--dangerously-bypass-hook-trust"
check "codex bare: SessionStart TOML with ''' quoting" \
    bash -c "grep -q \"hooks.SessionStart=\" '$OUT/argv7' && grep -q \"command='''\" '$OUT/argv7'"
check "codex bare: Stop hook wired" grep -q "hooks.Stop=" "$OUT/argv7"
check "codex bare: launch recorded" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
assert events[-1]["event"] == "launch" and events[-1]["agent"] == "codex"
' "$MAP_FILE"

# --- codex: subcommand passthrough ----------------------------------------

BEFORE=$(map_lines)
run codex "$OUT/argv8" login
check "codex login: argv untouched" \
    test "$(argv_count "$OUT/argv8")" = "1" -a "$(argv_line "$OUT/argv8" 1)" = "login"
check "codex login: nothing recorded" test "$(map_lines)" = "$BEFORE"

# --- codex: resume records the id and still injects ------------------------

RESUME_ID="11111111-2222-3333-4444-555555555555"
run codex "$OUT/argv9" resume "$RESUME_ID"
check "codex resume: hooks injected" test "$(argv_line "$OUT/argv9" 1)" = "--enable"
check "codex resume: subcommand+id preserved at tail" \
    bash -c "tail -2 '$OUT/argv9' | head -1 | grep -qx resume && tail -1 '$OUT/argv9' | grep -qx '$RESUME_ID'"
check "codex resume: user-session recorded with id" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
assert events[-1]["event"] == "user-session" and events[-1]["sessionId"] == sys.argv[2]
' "$MAP_FILE" "$RESUME_ID"

# --- codex: --ephemeral persists nothing ------------------------------------

BEFORE=$(map_lines)
run codex "$OUT/argv10" exec --ephemeral "do the thing"
check "codex --ephemeral: argv untouched" \
    test "$(argv_count "$OUT/argv10")" = "3" -a "$(argv_line "$OUT/argv10" 1)" = "exec"
check "codex --ephemeral: nothing recorded" test "$(map_lines)" = "$BEFORE"

# --- codex: missing real binary ---------------------------------------------

env "${SCRUB[@]}" PATH="$SHIM_BIN:/usr/bin:/bin" ENSO_TAB_ID="$TAB_ID" ENSO_SHIM_DIR="$SHIM_BIN" \
    ENSO_SESSIONS_DIR="$SESSIONS" \
    "$SHIM_BIN/codex" > "$OUT/stdout" 2> "$OUT/stderr"
STATUS=$?
check "codex missing binary: exit 127" test "$STATUS" = "127"
check "codex missing binary: stdout empty" stdout_empty

# --- nested agent runs stay out of the map ----------------------------------
# A claude/codex spawned from inside a running agent (Bash tool) inherits the
# tab env; it must pass through without recording, or it would overwrite the
# tab's real session record.

run_nested() {
    local wrapper="$1" argv_file="$2" extra_key="$3" extra_val="$4"
    shift 4
    env "${SCRUB[@]}" PATH="$BASE_PATH" \
        ENSO_TAB_ID="$TAB_ID" \
        ENSO_SHIM_DIR="$SHIM_BIN" \
        ENSO_SESSIONS_DIR="$SESSIONS" \
        FAKE_ARGV_FILE="$argv_file" \
        "$extra_key=$extra_val" \
        "$SHIM_BIN/$wrapper" "$@" > "$OUT/stdout" 2> "$OUT/stderr"
}

BEFORE=$(map_lines)
run_nested claude "$OUT/argv11" ENSO_AGENT_ACTIVE 1 "nested prompt"
check "claude nested (ENSO_AGENT_ACTIVE): argv untouched" \
    test "$(argv_count "$OUT/argv11")" = "1" -a "$(argv_line "$OUT/argv11" 1)" = "nested prompt"
check "claude nested (ENSO_AGENT_ACTIVE): nothing recorded" test "$(map_lines)" = "$BEFORE"

run_nested claude "$OUT/argv12" CLAUDECODE 1 "nested prompt"
check "claude nested (CLAUDECODE): argv untouched" \
    test "$(argv_count "$OUT/argv12")" = "1" -a "$(argv_line "$OUT/argv12" 1)" = "nested prompt"
check "claude nested (CLAUDECODE): nothing recorded" test "$(map_lines)" = "$BEFORE"

run_nested codex "$OUT/argv13" ENSO_AGENT_ACTIVE 1 "nested prompt"
check "codex nested (ENSO_AGENT_ACTIVE): argv untouched" \
    test "$(argv_count "$OUT/argv13")" = "1" -a "$(argv_line "$OUT/argv13" 1)" = "nested prompt"
check "codex nested (ENSO_AGENT_ACTIVE): nothing recorded" test "$(map_lines)" = "$BEFORE"

run_nested codex "$OUT/argv14" CODEX_SANDBOX seatbelt "nested prompt"
check "codex nested (CODEX_SANDBOX): argv untouched" \
    test "$(argv_count "$OUT/argv14")" = "1" -a "$(argv_line "$OUT/argv14" 1)" = "nested prompt"
check "codex nested (CODEX_SANDBOX): nothing recorded" test "$(map_lines)" = "$BEFORE"

# The wrapper marks its own session launches so THEIR children pass through.
run claude "$OUT/argv15" "marked prompt"
check "claude injection: exports ENSO_AGENT_ACTIVE marker" \
    test "$(cat "$OUT/argv15.env" 2>/dev/null)" = "1"

# --- codex: hook-less versions still record resume ids -----------------------
# An old codex without hook support gets plain passthrough, but an explicit
# `codex resume <id>` is still worth remembering.

OLD_BIN="$TMP/oldbin"
mkdir -p "$OLD_BIN"
cat > "$OLD_BIN/codex" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: codex [options] [prompt]"
    exit 0
fi
: > "${FAKE_ARGV_FILE:?}"
for arg in "$@"; do printf '%s\n' "$arg" >> "$FAKE_ARGV_FILE"; done
exit 0
EOF
chmod 755 "$OLD_BIN/codex"

OLD_UUID="11111111-2222-3333-4444-555555555555"
env "${SCRUB[@]}" PATH="$SHIM_BIN:$OLD_BIN:/usr/bin:/bin" \
    ENSO_TAB_ID="$TAB_ID" \
    ENSO_SHIM_DIR="$SHIM_BIN" \
    ENSO_SESSIONS_DIR="$SESSIONS" \
    FAKE_ARGV_FILE="$OUT/argv16" \
    "$SHIM_BIN/codex" resume "$OLD_UUID" > "$OUT/stdout" 2> "$OUT/stderr"
check "codex hook-less resume: argv untouched" \
    test "$(argv_count "$OUT/argv16")" = "2" -a "$(argv_line "$OUT/argv16" 1)" = "resume"
check "codex hook-less resume: user-session recorded" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
assert events[-1]["event"] == "user-session" and events[-1]["sessionId"] == sys.argv[2]
' "$MAP_FILE" "$OLD_UUID"

# --- launch-context recording: argvB64 + configDir ---------------------------

TRICKY1="hello world"
TRICKY2="it's \"quoted\""
TRICKY3=$'line1\nline2'
TRICKY4="émoji ✨ ~"
run claude "$OUT/argv17" "$TRICKY1" "$TRICKY2" "$TRICKY3" "$TRICKY4"
check "claude argvB64: stdout empty" stdout_empty
check "claude argvB64: original argv survives base64 round trip" \
    python3 -c '
import base64, json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
last = [e for e in events if e["event"] == "launch"][-1]
tokens = base64.b64decode(last["argvB64"]).split(b"\x00")
assert tokens[-1] == b"", "missing trailing NUL"
assert [t.decode() for t in tokens[:-1]] == sys.argv[2:], tokens
' "$MAP_FILE" "$TRICKY1" "$TRICKY2" "$TRICKY3" "$TRICKY4"
check "claude argvB64: configDir absent when CLAUDE_CONFIG_DIR unset" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
last = [e for e in events if e["event"] == "launch"][-1]
assert "configDir" not in last, last
' "$MAP_FILE"

# Bare launch records an EMPTY argvB64 (decodes to no arguments).
run claude "$OUT/argv18"
check "claude argvB64: bare launch records empty argv" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
last = [e for e in events if e["event"] == "launch"][-1]
assert last["argvB64"] == "", last
' "$MAP_FILE"

# configDir is recorded when the launch had a custom CLAUDE_CONFIG_DIR.
env "${SCRUB[@]}" PATH="$BASE_PATH" ENSO_TAB_ID="$TAB_ID" ENSO_SHIM_DIR="$SHIM_BIN" \
    ENSO_SESSIONS_DIR="$SESSIONS" FAKE_ARGV_FILE="$OUT/argv19" \
    CLAUDE_CONFIG_DIR="/tmp/custom claude home" \
    "$SHIM_BIN/claude" "hi" > "$OUT/stdout" 2> "$OUT/stderr"
check "claude configDir: stdout empty" stdout_empty
check "claude configDir: recorded on launch" \
    python3 -c '
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
last = [e for e in events if e["event"] == "launch"][-1]
assert last["configDir"] == "/tmp/custom claude home", last
' "$MAP_FILE"

# Codex records argvB64 + CODEX_HOME on user-session (resume) events too.
env "${SCRUB[@]}" PATH="$BASE_PATH" ENSO_TAB_ID="$TAB_ID" ENSO_SHIM_DIR="$SHIM_BIN" \
    ENSO_SESSIONS_DIR="$SESSIONS" FAKE_ARGV_FILE="$OUT/argv20" \
    CODEX_HOME="/tmp/codex home" \
    "$SHIM_BIN/codex" resume "$RESUME_ID" --model gpt-5.4 > "$OUT/stdout" 2> "$OUT/stderr"
check "codex argvB64: stdout empty" stdout_empty
check "codex argvB64 + CODEX_HOME recorded on user-session" \
    python3 -c '
import base64, json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
last = [e for e in events if e["event"] == "user-session"][-1]
tokens = base64.b64decode(last["argvB64"]).split(b"\x00")
assert [t.decode() for t in tokens[:-1]] == ["resume", sys.argv[2], "--model", "gpt-5.4"], tokens
assert last["configDir"] == "/tmp/codex home", last
' "$MAP_FILE" "$RESUME_ID"

# --- final map integrity -----------------------------------------------------

check "map file: every line still valid JSON" json_valid_map

if [[ "$FAILED" != 0 ]]; then
    echo "SMOKE TESTS FAILED"
    exit 1
fi
echo "ALL SMOKE TESTS PASSED"
