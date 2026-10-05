#!/usr/bin/env bash
# Long bg jobs must survive their caller and transient upstream drops, and status must match reality.
#   1. _spawn_detached: the bg supervisor leaves the caller's process group, so a group kill of the
#      caller (an agent tool call ending/timing out) no longer TERMs it -> no more interrupted:signal.
#   2. Election reclaim: a no-flock (macOS) election dir whose holder pid is GONE (ps rc 2) is
#      reclaimed instead of wedging every arm as NOT-ARMED.
#   3. _opencode_transient_failure: dropped stream / rate limit resume; billing refusals and a
#      finished run do not.
#   4. delegate_opencode resumes the SAME titled session after a transport drop.
#   5. _supervise: the tier hard cap extends while the job is making progress, unless OSRC_TIMEOUT
#      pins it; a live non-loopback model connection vetoes the stall kill.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="${OSRC_TEST_SRC:-$HERE/../outsourcerer.sh}"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state" OSRC_HEARTBEAT="$TMP/state/heartbeat" OSRC_CLOUD_ACK=1
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
set --; . "$SRC" >/dev/null 2>&1

# 1. detached supervisor survives a kill of the caller's process group
cat > "$TMP/child.sh" <<'SH'
#!/usr/bin/env bash
echo $$ > "$1"; sleep 30
SH
chmod +x "$TMP/child.sh"
( set -m; ( _spawn_detached "$TMP/child.sh" "$TMP/child.pid"; sleep 30 ) & echo $! > "$TMP/caller.pid"; wait ) &
for _ in $(seq 1 50); do [ -s "$TMP/child.pid" ] && break; sleep 0.1; done
cpg="$(ps -o pgid= -p "$(cat "$TMP/caller.pid")" | tr -d ' ')"; chp="$(cat "$TMP/child.pid" 2>/dev/null)"
kill -TERM -- "-$cpg" 2>/dev/null; sleep 0.5
if [ -n "$chp" ] && kill -0 "$chp" 2>/dev/null; then ok "bg supervisor survives a TERM to the caller's process group"; kill "$chp"
else bad "detached child died with the caller's group (pgid $cpg, child $chp)"; fi

# 2. dead-holder election dir is reclaimed on the mkdir path
_state_sync() { return 0; }
dead=99991; while kill -0 "$dead" 2>/dev/null || ps -p "$dead" >/dev/null 2>&1; do dead=$((dead-1)); done
mkdir -p "$OSRC_HEARTBEAT/.election"
printf '{"pid":%s,"pid_start":"Tue Aug 4 21:32:42 2026"}\n' "$dead" > "$OSRC_HEARTBEAT/.election/owner.json"
mkdir -p "$OSRC_HEARTBEAT/.election.pending.$dead.Tue_Aug_4_21:32:42_2026"
me="$(_pid_start_identity "$$")"
if OSRC_FORCE_MKDIR_ELECTION=1 _heartbeat_election_acquire "$OSRC_HEARTBEAT/.election" "$$" "$me"; then
  [ "$(jq -r .pid "$OSRC_HEARTBEAT/.election/owner.json")" = "$$" ] && ok "dead-holder election lock is reclaimed" || bad "election reclaimed but owner not republished"
  [ ! -d "$OSRC_HEARTBEAT/.election.pending.$dead.Tue_Aug_4_21:32:42_2026" ] && ok "dead claimant pending dir is swept" || bad "dead pending dir left behind"
  _heartbeat_election_release "$OSRC_HEARTBEAT/.election"
else bad "dead-holder election lock still wedges acquire"; fi

# 3. transient classifier
t(){ printf '%b' "$1" > "$TMP/cap"; _opencode_transient_failure "$TMP/cap" "$2"; }
t '> osrc-yolo\n\033[91m\033[1mError: \033[0mTransport: The socket connection was closed unexpectedly.\n' 1 && ok "socket drop is transient" || bad "socket drop not transient"
t 'work\nError: Error from provider (Console): Rate limit exceeded. Please try again later.\n' 1 && ok "rate limit is transient" || bad "rate limit not transient"
t "Error: Error from provider (Console): OpenCode's free tier can only be used from within OpenCode\n" 1 && bad "free-tier refusal treated as transient" || ok "free-tier refusal is not transient"
t 'Error: rate limit\nmore work\nOSRC::DONE#ab finished\n' 0 && bad "finished run treated as transient" || ok "a run that printed its terminal marker is never resumed"
t 'Error: request timed out in test output\nall good, continuing\n' 0 && bad "mid-run error on a clean exit treated as transient" || ok "clean exit with an earlier error line is not resumed"

# 4. resume of the titled session through delegate_opencode
mkdir -p "$TMP/bin"
cat > "$TMP/bin/opencode" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "session list" ]; then
  printf '[{"id":"ses_real123","title":"%s"}]\n' "$(cat "$OC_TITLE" 2>/dev/null)"; exit 0; fi
echo "$*" >> "$OC_LOG"
prev=""; for a in "$@"; do [ "$prev" = "--title" ] && echo "$a" > "$OC_TITLE"; prev="$a"; done
case " $* " in
  *" --session ses_real123 "*) echo "resumed" >&2; echo "OSRC::DONE finished" >&2; exit 0 ;;
  *) echo "> osrc-yolo" >&2; echo "Error: Transport: The socket connection was closed unexpectedly" >&2; exit 1 ;;
esac
SH
chmod +x "$TMP/bin/opencode"
export OC_LOG="$TMP/oc.log" OC_TITLE="$TMP/oc.title"
( cd "$TMP" && REST=("write a file") && MODEL=opencode/big-pickle && PATH="$TMP/bin:$PATH" OSRC_OPENCODE_RESUME_WAIT=0 \
    delegate_opencode autonomous ) >/dev/null 2>"$TMP/oc.err"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^run --' "$OC_LOG")" = 2 ] && grep -q -- '--session ses_real123' "$OC_LOG" \
   && head -1 "$OC_LOG" | grep -q -- '--title osrc-'; then ok "transport drop resumes the same titled session and finishes rc 0"
else bad "resume path wrong (rc=$rc): $(cat "$OC_LOG" 2>/dev/null | cut -c1-200)"; fi

# 5a. hard cap extends while output keeps growing (OSRC_TIMEOUT unset)
mk(){ local d="$TMP/jobs/$1"; mkdir -p "$d"; printf '{"verb":"run","cwd":"%s","lane":"opencode"}' "$TMP/cwd" > "$d/meta.json"; echo "$d"; }
mkdir -p "$TMP/cwd"
cat > "$TMP/talker.sh" <<'SH'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6 7; do echo "OSRC::PROGRESS step $i of the real work"; sleep 1; done; echo "OSRC::DONE all good"
SH
chmod +x "$TMP/talker.sh"
jd="$(mk hard1)"; ( unset OSRC_TIMEOUT; OSRC_POLL=1 OSRC_NOINIT_SECS=100 _supervise "$jd" 3 50 3 -- "$TMP/talker.sh" ) 2>/dev/null
[ "$(cat "$jd/status")" = done ] && ok "productive job runs past the tier hard cap" || bad "productive job killed at hard cap: $(cat "$jd/status") $(cat "$jd/reason" 2>/dev/null)"
jd="$(mk hard2)"; ( OSRC_TIMEOUT=3 OSRC_POLL=1 OSRC_NOINIT_SECS=100 _supervise "$jd" 3 50 3 -- "$TMP/talker.sh" ) 2>/dev/null
[ "$(cat "$jd/status")" = timeout ] && ok "explicit OSRC_TIMEOUT stays a strict cap" || bad "explicit OSRC_TIMEOUT not honored: $(cat "$jd/status")"

# 5b. net liveness: non-loopback ESTABLISHED counts, loopback-only does not
cat > "$TMP/bin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p123\nf20\nn%s\n' "$LSOF_PEER"
SH
chmod +x "$TMP/bin/lsof"; jd="$(mk net)"
LSOF_PEER='10.0.0.2:51000->104.18.1.1:443' PATH="$TMP/bin:$PATH" _job_net_alive "$jd" $$ && ok "remote model connection = alive" || bad "remote connection not seen"
LSOF_PEER='127.0.0.1:51000->127.0.0.1:4096' PATH="$TMP/bin:$PATH" _job_net_alive "$jd" $$ && bad "loopback counted as model connection" || ok "loopback connection ignored"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
