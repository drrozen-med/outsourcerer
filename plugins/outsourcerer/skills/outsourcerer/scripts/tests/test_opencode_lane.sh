#!/usr/bin/env bash
# Covers registration, the free-model default/aliases, honest headless safety
# (plan agent for read-only; scoped per-run permission config for mutating tiers;
# never --auto), plan-limit + transport failure detection, and the interactive
# TUI adapter.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
TMP="$(mktemp -d)" || exit 1
export OSRC_HOME="$TMP/state"
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/td"
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
printf '%s\n' "${OPENCODE_CONFIG:-none}" >> "$OPENCODE_CFG_LOG"
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "$OPENCODE_CONFIG" ]; then
  cat "$OPENCODE_CONFIG" >> "$OPENCODE_CFG_BODY"
fi
case "${OPENCODE_FAKE_MODE:-ok}" in
  quota) echo 'Error: FreeTierError: free tier usage limit reached; buy credits (HTTP 402)' >&2; exit 1 ;;
  drop)  echo 'Error: connection reset by peer' >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$BIN/opencode"
export PATH="$BIN:$PATH" OPENCODE_LOG="$TMP/opencode.log" OPENCODE_CFG_LOG="$TMP/cfg.log" \
  OPENCODE_CFG_BODY="$TMP/cfgbody.log" OSRC_CLOUD_ACK=1

set --
. "$SRC" >/dev/null 2>&1

if [ "$(_lane_by_provider opencode 2>/dev/null)" = "opencode" ] \
  && [ "$(_lane_disp opencode opencode 2>/dev/null)" = "opencode" ] \
  && _provider_owns_catalog opencode && _is_cloud_lane opencode \
  && [ "$(_lane_field opencode default_model)" = "opencode/big-pickle" ] \
  && [ "$(_ready_probe_opencode)" = "opencode=user-configured-provider" ]; then
  ok "descriptor registers OpenCode as an engine lane with free default model"
else
  bad "OpenCode descriptor does not resolve provider/catalog/vehicle/default"
fi

if [ "$(_opencode_model_alias free)" = "opencode/big-pickle" ] \
  && [ "$(_opencode_model_alias free-large)" = "opencode/muse-spark-1.3-contributor-free" ] \
  && [ "$(_opencode_model_alias free-fast)" = "opencode/nemotron-3.5-lightning-free" ] \
  && [ "$(_opencode_model_alias '')" = "opencode/big-pickle" ] \
  && [ "$(_opencode_model_alias provider/model)" = "provider/model" ]; then
  ok "lane-local aliases resolve to the Zen free roster; unknown ids pass through"
else
  bad "alias map wrong: free=$(_opencode_model_alias free) free-large=$(_opencode_model_alias free-large) free-fast=$(_opencode_model_alias free-fast) empty=$(_opencode_model_alias '')"
fi

if printf '%s' "$(_opencode_cost_note opencode/big-pickle)" | grep -q '\$0' \
  && printf '%s' "$(_opencode_cost_note opencode/nemotron-3.5-lightning-free)" | grep -q '\$0' \
  && [ "$(_opencode_cost_note provider/model)" != "$(_opencode_cost_note opencode/big-pickle)" ] \
  && printf '%s' "$(_opencode_cost_note provider/model)" | grep -q 'bill'; then
  ok "cost disclosure reports \$0 for opencode/* free models; non-free ids get the billing note"
else
  bad "cost disclosure wrong: big-pickle=$(_opencode_cost_note opencode/big-pickle) other=$(_opencode_cost_note provider/model)"
fi

REST=("inspect the repository")
MODEL="big-pickle/free" MODEL_EXPLICIT=1 EFFORT="high" TTIER=""
: > "$OPENCODE_LOG"; : > "$OPENCODE_CFG_LOG"
delegate_opencode auto >/dev/null 2>&1
out="$(cat "$OPENCODE_LOG" 2>/dev/null)"
if printf '%s' "$out" | grep -q '^run --agent plan ' \
  && ! printf '%s' "$out" | grep -q -- '--dir' \
  && ! printf '%s' "$out" | grep -q -- '--standalone' \
  && printf '%s' "$out" | grep -q -- '--model big-pickle/free' \
  && printf '%s' "$out" | grep -q -- '--variant high' \
  && ! printf '%s' "$out" | grep -q -- '--auto' \
  && ! grep -qv '^none$' "$OPENCODE_CFG_LOG"; then
  ok "headless read-only uses plan agent, verbatim model, no --auto, no temp config"
else
  bad "read-only dispatch violated the plan-agent contract: out=$out cfglog=$(cat "$OPENCODE_CFG_LOG")"
fi

: > "$OPENCODE_LOG"
MODEL="" MODEL_EXPLICIT=0 EFFORT=""
delegate_opencode auto >/dev/null 2>&1
out="$(cat "$OPENCODE_LOG" 2>/dev/null)"
if printf '%s' "$out" | grep -q -- '--model opencode/big-pickle'; then
  ok "no -m defaults to the free model opencode/big-pickle"
else
  bad "default model not pinned to the free roster: $out"
fi

: > "$OPENCODE_LOG"
MODEL="free-fast" MODEL_EXPLICIT=1
delegate_opencode auto >/dev/null 2>&1
out="$(cat "$OPENCODE_LOG" 2>/dev/null)"
if printf '%s' "$out" | grep -q -- '--model opencode/nemotron-3.5-lightning-free'; then
  ok "-m free-fast resolves to opencode/nemotron-3.5-lightning-free"
else
  bad "alias dispatch wrong: $out"
fi

# Mutating tier: scoped per-run config in a private temp dir (never the repo),
# osrc-edit agent, external_directory denied, cleaned up after the run.
: > "$OPENCODE_LOG"; : > "$OPENCODE_CFG_LOG"; : > "$OPENCODE_CFG_BODY"
REST=("change a file") MODEL="" MODEL_EXPLICIT=0 EFFORT=""
TMPDIR="$TMP/td" delegate_opencode accept-edits >/dev/null 2>&1
out="$(cat "$OPENCODE_LOG" 2>/dev/null)"
cfgpath="$(tail -1 "$OPENCODE_CFG_LOG" 2>/dev/null)"
if printf '%s' "$out" | grep -q -- '--agent osrc-edit' \
  && printf '%s' "$out" | grep -q '^run --standalone ' \
  && ! printf '%s' "$out" | grep -q -- '--dir' \
  && ! printf '%s' "$out" | grep -q -- '--auto' \
  && case "$cfgpath" in "$TMP/td/"*) true ;; *) false ;; esac \
  && grep -q '"osrc-edit"' "$OPENCODE_CFG_BODY" \
  && grep -q '"edit": "allow"' "$OPENCODE_CFG_BODY" \
  && grep -q '"bash": "allow"' "$OPENCODE_CFG_BODY" \
  && grep -q '"webfetch": "allow"' "$OPENCODE_CFG_BODY" \
  && grep -q '"external_directory": "deny"' "$OPENCODE_CFG_BODY" \
  && [ ! -e "$cfgpath" ] && [ ! -e "$(dirname "$cfgpath")" ]; then
  ok "headless edit uses a scoped per-run config (osrc-edit, ext-dir denied), repo untouched, temp cleaned"
else
  bad "accept-edits dispatch wrong: out=$out cfgpath=$cfgpath body=$(cat "$OPENCODE_CFG_BODY" 2>/dev/null)"
fi

# yolo (dangerous): osrc-yolo agent, external_directory allowed.
: > "$OPENCODE_LOG"; : > "$OPENCODE_CFG_LOG"; : > "$OPENCODE_CFG_BODY"
REST=("refactor freely") MODEL="" MODEL_EXPLICIT=0
TMPDIR="$TMP/td" delegate_opencode dangerous >/dev/null 2>&1
out="$(cat "$OPENCODE_LOG" 2>/dev/null)"; cfgpath="$(tail -1 "$OPENCODE_CFG_LOG" 2>/dev/null)"
if printf '%s' "$out" | grep -q -- '--agent osrc-yolo' \
  && ! printf '%s' "$out" | grep -q -- '--auto' \
  && grep -q '"osrc-yolo"' "$OPENCODE_CFG_BODY" \
  && grep -q '"external_directory": "allow"' "$OPENCODE_CFG_BODY" \
  && [ ! -e "$cfgpath" ]; then
  ok "headless yolo uses osrc-yolo scoped config (ext-dir allowed), temp cleaned"
else
  bad "dangerous dispatch wrong: out=$out body=$(cat "$OPENCODE_CFG_BODY" 2>/dev/null)"
fi

# research (autonomous): scoped config, ext-dir denied.
: > "$OPENCODE_CFG_LOG"; : > "$OPENCODE_CFG_BODY"
REST=("run the benchmark") MODEL="" MODEL_EXPLICIT=0
TMPDIR="$TMP/td" delegate_opencode autonomous >/dev/null 2>&1
if grep -q '"external_directory": "deny"' "$OPENCODE_CFG_BODY" \
  && [ ! -e "$(tail -1 "$OPENCODE_CFG_LOG")" ]; then
  ok "research/autonomous tier runs scoped (ext-dir denied) and cleans up"
else
  bad "autonomous dispatch wrong: body=$(cat "$OPENCODE_CFG_BODY" 2>/dev/null)"
fi

# Quota / limit detection: FreeTierError, usage limit, buy credits, bare 402/429.
qhit=0
for msg in 'FreeTierError: free tier usage limit reached' 'Error: usage limit exceeded' \
           'please buy credits to continue' 'HTTP 402 payment required' \
           'Error: 429 too many requests' 'insufficient quota'; do
  printf '%s\n' "$msg" > "$TMP/err.txt"
  _lane_plan_limit_refusal opencode "$TMP/err.txt" && qhit=$((qhit + 1))
done
# A status-code digit string embedded in a larger number must NOT count (the regex
# is digit-delimited; the probe-then-decide block still verifies before marking).
printf 'the server returned status 14025 and exited\n' > "$TMP/err.txt"
_lane_plan_limit_refusal opencode "$TMP/err.txt" && qhit=$((qhit + 100))
if [ "$qhit" -eq 6 ]; then
  ok "quota detection catches FreeTierError / usage limit / buy credits / 402 / 429 (no prose false positive)"
else
  bad "quota detection wrong: qhit=$qhit (want 6; +100 = prose false positive)"
fi

# Post-run hook: a quota refusal marks the lane down (probe re-confirms via the
# fake's quota mode) and writes the failover signal a configured fallback reads.
_lane_down_clear opencode 2>/dev/null; _failover_signal_clear 2>/dev/null
: > "$OPENCODE_LOG"
REST=(x) MODEL="" MODEL_EXPLICIT=0
OPENCODE_FAKE_MODE=quota delegate_opencode auto >/dev/null 2>&1
if _lane_down_active opencode && _failover_signal_read && [ "$_FO_LANE" = "opencode" ]; then
  ok "quota refusal marks lane down and writes the failover handoff signal"
else
  bad "quota refusal did not engage failover: down=$(_lane_down_active opencode && echo yes || echo no) fo=$_FO_LANE/$_FO_VERDICT"
fi
_lane_down_clear opencode 2>/dev/null; _failover_signal_clear 2>/dev/null

# Transport drop: named clearly, not mislabeled a plan refusal.
: > "$OPENCODE_LOG"
REST=(x) MODEL="" MODEL_EXPLICIT=0
tout="$(OPENCODE_FAKE_MODE=drop delegate_opencode auto 2>&1)"; trc=$?
if [ "$trc" -ne 0 ] && printf '%s' "$tout" | grep -q 'transport failure' \
  && ! printf '%s' "$tout" | grep -q 'plan limit'; then
  ok "network drop is reported as a transport failure, not a quota refusal"
else
  bad "transport drop misclassified: rc=$trc out=$tout"
fi

PROVIDER=opencode MODEL_EXPLICIT=1 MODEL=provider/model EFFORT="" SESSION_LAUNCH=()
_session_launch_adapter
if [ "${SESSION_LAUNCH[*]}" = "opencode --agent build --model provider/model" ]; then
  ok "interactive session launches TUI with build agent and pinned model"
else
  bad "interactive adapter did not produce documented launch: ${SESSION_LAUNCH[*]}"
fi

PROVIDER=opencode MODEL_EXPLICIT=0 MODEL="" SESSION_LAUNCH=()
_session_launch_adapter
if [ "${SESSION_LAUNCH[*]}" = "opencode --agent build --model opencode/big-pickle" ]; then
  ok "interactive session pins the free default when -m is omitted"
else
  bad "default session launch wrong: ${SESSION_LAUNCH[*]}"
fi

PROVIDER=opencode MODEL_EXPLICIT=1 MODEL=free-large SESSION_LAUNCH=()
_session_launch_adapter
if [ "${SESSION_LAUNCH[*]}" = "opencode --agent build --model opencode/muse-spark-1.3-contributor-free" ]; then
  ok "interactive session resolves the free-large alias"
else
  bad "session alias resolution wrong: ${SESSION_LAUNCH[*]}"
fi

out="$(PATH=/usr/bin:/bin; hash -r; PROVIDER=opencode; REST=(x); route_delegate auto run --provider opencode x 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'opencode CLI not on PATH'; then
  ok "missing OpenCode CLI fails before dispatch"
else
  bad "missing OpenCode CLI did not fail fast: rc=$rc out=$out"
fi

_lanes="$(_ready_lanes 2>/dev/null || true)"
case "$_lanes" in *opencode*) ok "ready-lane brief advertises OpenCode" ;; *) bad "brief omits OpenCode: $_lanes" ;; esac

: > "$OPENCODE_LOG"
SEAM="$(bash "$SRC" run --provider opencode --cloud-ack --wait -m big-pickle/free x </dev/null 2>&1 || true)"
if grep -q -- '--agent plan' "$OPENCODE_LOG" && grep -q -- '--model big-pickle/free' "$OPENCODE_LOG"; then
  ok "router seam: run --provider opencode reaches OpenCode read-only with model verbatim"
else
  bad "router seam did not reach OpenCode as expected: log=$(cat "$OPENCODE_LOG" 2>/dev/null) out=$SEAM"
fi

: > "$OPENCODE_LOG"; : > "$OPENCODE_CFG_LOG"
SEAM="$(cd "$TMP" && TMPDIR="$TMP/td" bash "$SRC" edit --provider opencode --cloud-ack --wait -m free x </dev/null 2>&1 || true)"
if grep -q -- '--agent osrc-edit' "$OPENCODE_LOG" && grep -q -- '--model opencode/big-pickle' "$OPENCODE_LOG" \
  && [ -n "$(tail -1 "$OPENCODE_CFG_LOG")" ] && [ ! -e "$(tail -1 "$OPENCODE_CFG_LOG")" ]; then
  ok "router seam: edit --provider opencode -m free dispatches scoped mutation"
else
  bad "edit seam wrong: log=$(cat "$OPENCODE_LOG" 2>/dev/null) cfg=$(cat "$OPENCODE_CFG_LOG" 2>/dev/null) out=$SEAM"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
