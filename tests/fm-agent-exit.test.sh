#!/usr/bin/env bash
# tests/fm-agent-exit.test.sh - behavior tests for bin/fm-agent-exit.sh, the
# one mechanical owner of safe agent shutdown before rotation.
#
# Proves the two 2026-07-22/23 lessons as mechanisms, against a REAL tmux
# server on a private socket (never the host's sessions):
#
#   1. Interrupt-then-exit ordering: the fake agent emulates a wedged harness
#      at 100% context - it QUEUES every line (including /exit) while busy and
#      can only process input after the interrupt (Escape) lands. It exits
#      cleanly only if the interrupt arrives before the exit command, so a
#      clean exit IS the ordering proof.
#   2. Queued-message drain: an open pending-reply expectation whose recovery
#      resend WOULD fire (proven on a baseline copy of the state) is
#      invalidated by rotation, and the post-rotation reconciliation tick
#      delivers nothing to the successor.
#
# The fake agent must read as a live harness process to
# fm_backend_tmux_agent_alive, which classifies by #{pane_current_command}. A
# shebang script reports its interpreter ("bash"), which classifies as a dead
# bare shell, so the fixture copies the local node binary to a file named
# "claude" and runs the agent script through it (verified in-repo: the pane
# then reports "claude"). Skips when tmux or node is unavailable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

AGENT_EXIT="$ROOT/bin/fm-agent-exit.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-agent-exit-$$"
TMP_ROOT=$(fm_test_tmproot fm-agent-exit-tests)
# fm_test_tmproot ran in the $(...) subshell above, so its registration of
# TMP_ROOT for cleanup was discarded with that subshell. Re-register it in this
# shell so cleanup_tmux's fm_test_cleanup actually removes the temp root (else
# it leaks) and its cleanup loop returns success instead of leaving the EXIT
# trap with the last failed empty-array test as $? under the set -e in effect
# at exit.
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")

cleanup_tmux() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_tmux EXIT

# tmux shim: every bare `tmux ...` from the adapter goes to the private socket.
SHIM_DIR="$TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
FIXTURE="$TMP_ROOT/fixture"
mkdir -p "$STATE" "$FIXTURE"
touch "$STATE/.last-watcher-beat"

# A platform bash/zsh copy will not execute on macOS (signed platform binary),
# but node copies fine and gives the pane a "claude" current-command.
cp "$(command -v node)" "$FIXTURE/claude" || fail "could not copy node as the fake harness binary"

INPUT_LOG="$FIXTURE/input.log"
INTERRUPTED_MARKER="$FIXTURE/interrupted"
EXITED_MARKER="$FIXTURE/exited-clean"
cat > "$FIXTURE/agent.js" <<'JS'
// Wedged-harness emulator: raw-reads its tty. While "busy" it only LOGS what
// arrives (a typed /exit queues behind work it can no longer reach). A single
// ESC byte is the interrupt: it flips the agent to idle and writes the
// interrupted marker. Only after that does a completed "/exit" line exit the
// process (writing the exited-clean marker). Exit without a prior interrupt is
// impossible by construction.
const fs = require("fs");
const [logPath, interruptedMarker, exitedMarker] = process.argv.slice(2);
let busy = true;
let line = "";
const log = (entry) => fs.appendFileSync(logPath, entry + "\n");
process.stdin.setRawMode(true);
process.stdin.resume();
process.stdin.on("data", (buf) => {
  for (const byte of buf) {
    if (byte === 0x1b) {
      log("<ESC>");
      if (busy) {
        busy = false;
        fs.writeFileSync(interruptedMarker, "interrupted\n");
      }
      continue;
    }
    if (byte === 0x0d || byte === 0x0a) {
      if (line.length > 0) log(busy ? "queued:" + line : "line:" + line);
      if (!busy && line === "/exit") {
        fs.writeFileSync(exitedMarker, "exited-clean\n");
        process.exit(0);
      }
      line = "";
      continue;
    }
    line += String.fromCharCode(byte);
  }
});
setInterval(() => {}, 1000);
JS

ID="rot1"
SESSION="rot"
WINDOW="fm-$ID"
TARGET="$SESSION:$WINDOW"
fm_write_meta "$STATE/$ID.meta" \
  "window=$TARGET" \
  "project=$TMP_ROOT/project" \
  "kind=ship" \
  "mode=no-mistakes" \
  "harness=claude"

tmux new-session -d -s "$SESSION" -x 200 -y 50 || fail "real tmux: new-session failed"
tmux new-window -d -t "$SESSION:" -n "$WINDOW" \
  "$FIXTURE/claude $FIXTURE/agent.js $INPUT_LOG $INTERRUPTED_MARKER $EXITED_MARKER" \
  || fail "real tmux: could not launch the fake wedged agent"

wait_for() {  # <label> <check...>
  local label=$1 i=0
  shift
  while [ "$i" -lt 100 ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "$label"
}

check_pane_command_is_claude() {
  [ "$(tmux display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null)" = claude ]
}
wait_for "fake agent never reported as a live claude process" check_pane_command_is_claude

# A typed exit command queues at the wedged agent instead of landing - the
# exact pre-fix failure. Send one directly and prove it did NOT exit the agent.
tmux send-keys -t "$TARGET" -l '/exit'
tmux send-keys -t "$TARGET" Enter
check_exit_queued() { grep -q '^queued:/exit$' "$INPUT_LOG" 2>/dev/null; }
wait_for "wedged agent did not record the queued /exit" check_exit_queued
[ ! -e "$EXITED_MARKER" ] || fail "a queued /exit alone must not exit a wedged agent (ordering premise broken)"
pass "wedged fake agent queues a bare /exit exactly like a 100%-context harness"

# Open pending-reply expectation, recovery-eligible (delivered, request turn
# completed, grace elapsed). The baseline clone proves its recovery resend
# WOULD fire and chase whatever agent sits at the endpoint next.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
CORR=$(FM_PENDING_REPLY_NOW=1000000 fm_pending_reply_create "$HOME_DIR" "$STATE" "$ID" "send the follow-up notices") \
  || fail "could not create the pending-reply fixture"
REC=$(fm_pending_reply_path "$STATE" "$CORR")
fm_pending_reply_set "$REC" delivered_epoch 1000000 || fail "fixture delivered_epoch"
fm_pending_reply_set "$REC" request_turn_completed_epoch 1000000 || fail "fixture request_turn_completed_epoch"

BASELINE="$TMP_ROOT/state-baseline"
cp -R "$STATE" "$BASELINE"
BASELINE_HOOK_LOG="$TMP_ROOT/baseline-recovery.log"
FM_PENDING_REPLY_NOW=1000200 \
  FM_PENDING_REPLY_SEND_HOOK="printf '%s\n' recovery-delivered >> $BASELINE_HOOK_LOG; :" \
  fm_pending_reply_tick "$BASELINE" || true
grep -q recovery-delivered "$BASELINE_HOOK_LOG" 2>/dev/null \
  || fail "baseline: the open expectation's recovery resend never fired, so the invalidation test would prove nothing"
pass "baseline: an open pending-reply expectation resends recovery to whoever holds the endpoint"

# --- rotation: interrupt-then-exit, drain, endpoint removal -----------------

set +e
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_AGENT_EXIT_INTERRUPT_SETTLE=1 FM_AGENT_EXIT_WAIT=15 \
  "$AGENT_EXIT" "$ID" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "fm-agent-exit failed (rc=$RC): $(cat "$TMP_ROOT/err")"

[ -e "$INTERRUPTED_MARKER" ] || fail "interrupt never reached the wedged agent"
[ -e "$EXITED_MARKER" ] || fail "agent did not exit cleanly - interrupt-then-exit ordering did not land"
ESC_LINE=$(grep -n '^<ESC>$' "$INPUT_LOG" | head -1 | cut -d: -f1)
EXIT_LINE=$(grep -n '^line:/exit$' "$INPUT_LOG" | head -1 | cut -d: -f1)
[ -n "$ESC_LINE" ] && [ -n "$EXIT_LINE" ] || fail "input log missing interrupt or exit evidence: $(cat "$INPUT_LOG")"
[ "$ESC_LINE" -lt "$EXIT_LINE" ] || fail "exit command was processed before the interrupt: $(cat "$INPUT_LOG")"
pass "interrupt-then-exit ordering exits a busy agent (interrupt strictly first)"

if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "outgoing agent's window survived rotation - queued pty input could still reach a successor"
fi
grep -q "agent-exit $ID complete" "$TMP_ROOT/out" || fail "fm-agent-exit did not report completion: $(cat "$TMP_ROOT/out")"
pass "rotation removes the outgoing agent's endpoint entirely"

[ "$(fm_pending_reply_get "$REC" phase)" = resolved ] || fail "pending-reply record not invalidated by rotation"
[ "$(fm_pending_reply_get "$REC" resolved_via)" = rotation ] || fail "invalidated record should say resolved_via=rotation"
grep -q "invalidated 1 queued pending-reply request" "$TMP_ROOT/out" \
  || fail "fm-agent-exit did not report the drained queued request: $(cat "$TMP_ROOT/out")"

POST_HOOK_LOG="$TMP_ROOT/post-recovery.log"
FM_PENDING_REPLY_NOW=1000400 \
  FM_PENDING_REPLY_SEND_HOOK="printf '%s\n' recovery-delivered >> $POST_HOOK_LOG; :" \
  fm_pending_reply_tick "$STATE" || true
[ ! -s "$POST_HOOK_LOG" ] || fail "a queued request still reached the successor after rotation"
pass "queued pending-reply requests cannot reach a successor after rotation"

# --- idempotence: a second run on the already-rotated task is a clean no-op --

set +e
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$AGENT_EXIT" "$ID" > "$TMP_ROOT/out2" 2> "$TMP_ROOT/err2"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "fm-agent-exit rerun on a rotated task must succeed (rc=$RC): $(cat "$TMP_ROOT/err2")"
grep -q "no queued pending-reply requests" "$TMP_ROOT/out2" \
  || fail "rerun should find nothing left to invalidate: $(cat "$TMP_ROOT/out2")"
pass "fm-agent-exit is idempotent once the agent and endpoint are gone"
