#!/usr/bin/env bash
# Covers registration, honest headless safety, and the interactive TUI adapter.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
TMP="$(mktemp -d)" || exit 1
export OSRC_HOME="$TMP/state"
BIN="$TMP/bin"
mkdir -p "$BIN"
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

cat > "$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  cat <<'HELP'
start opencode tui
  -m, --model  model to use
      --agent  agent to use
HELP
  exit 0
fi
printf '%s ' "$*" >> "$OPENCODE_LOG"
EOF
chmod +x "$BIN/opencode"
export PATH="$BIN:$PATH" OPENCODE_LOG="$TMP/opencode.log" OSRC_CLOUD_ACK=1

set --
. "$SRC" >/dev/null 2>&1

if [ "$(_lane_by_provider opencode 2>/dev/null)" = "opencode" ] \
  && [ "$(_lane_disp opencode opencode 2>/dev/null)" = "opencode" ] \
  && _provider_owns_catalog opencode && _is_cloud_lane opencode \
  && [ "$(_ready_probe_opencode)" = "opencode=user-configured-provider" ]; then
  ok "descriptor registers OpenCode as an engine lane"
else
  bad "OpenCode descriptor does not resolve provider/catalog/vehicle"
fi

REST=("inspect the repository")
MODEL="big-pickle/free" MODEL_EXPLICIT=1 EFFORT="high" TTIER=""
delegate_opencode auto >/dev/null 2>&1
out="$(cat "$OPENCODE_LOG" 2>/dev/null)"
if printf '%s' "$out" | grep -q 'run --dir ' \
  && printf '%s' "$out" | grep -q -- '--agent plan' \
  && printf '%s' "$out" | grep -q -- '--model big-pickle/free' \
  && printf '%s' "$out" | grep -q -- '--variant high' \
  && ! printf '%s' "$out" | grep -q -- '--auto'; then
  ok "headless work uses plan agent without dangerous --auto"
else
  bad "headless dispatch violated the plan-agent contract: $out"
fi

REST=("change a file")
MODEL="" MODEL_EXPLICIT=0
out="$(delegate_opencode accept-edits 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- "--auto" \
  && printf '%s' "$out" | grep -q 'session start'; then
  ok "mutating headless tier refuses dangerous approval escalation"
else
  bad "mutating headless tier was not refused honestly: rc=$rc out=$out"
fi

PROVIDER=opencode MODEL_EXPLICIT=1 MODEL=provider/model SESSION_LAUNCH=()
_session_launch_adapter
if [ "${SESSION_LAUNCH[*]}" = "opencode --agent build --model provider/model" ]; then
  ok "interactive session launches TUI with build agent and pinned model"
else
  bad "interactive adapter did not produce documented launch: ${SESSION_LAUNCH[*]}"
fi

out="$(PATH=/usr/bin:/bin; hash -r; PROVIDER=opencode; REST=(x); route_delegate auto run --provider opencode x 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'opencode CLI not on PATH'; then
  ok "missing OpenCode CLI fails before dispatch"
else
  bad "missing OpenCode CLI did not fail fast: rc=$rc out=$out"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
