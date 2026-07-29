#!/usr/bin/env bash
# Behavior tests for task-exit and periodic Puppeteer browser reaping.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAPER="$ROOT/bin/fm-reap-browsers.sh"
TMP_ROOT=$(fm_test_tmproot fm-reap-browsers-tests)
PIDS=()

cleanup_processes() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.1
  for pid in "${PIDS[@]:-}"; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_processes EXIT

FAKE_BROWSER_PID=
start_fake_browser() {  # <cwd> <profile>
  local cwd=$1 profile=$2
  mkdir -p "$cwd" "$profile"
  (
    cd "$cwd" || exit 1
    # The process command has a Chrome-family executable marker and Puppeteer's
    # real profile marker. It exits on TERM like a cooperative browser process.
    exec bash -c 'trap "exit 0" TERM; while :; do sleep 1; done' \
      /fixture/chrome-headless-shell "--user-data-dir=$profile"
  ) >/dev/null 2>&1 &
  FAKE_BROWSER_PID=$!
  PIDS+=("$FAKE_BROWSER_PID")
  sleep 0.2
  kill -0 "$FAKE_BROWSER_PID" 2>/dev/null || fail "fake browser failed to start"
}

home_tag() {  # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" bash -c \
    '. "$1/bin/fm-backend-hometag-lib.sh"; fm_backend_hometag' _ "$ROOT"
}

wait_reaped() {  # <pid> <message>
  local pid=$1 message=$2
  wait "$pid" 2>/dev/null || true
  kill -0 "$pid" 2>/dev/null && fail "$message"
}

test_task_reaps_browser_tied_by_cwd() {
  local case_dir state wt profile pid child_pid out
  case_dir="$TMP_ROOT/task-exit"
  state="$case_dir/state"
  wt="$case_dir/worktree"
  profile="$case_dir/generic/puppeteer_dev_chrome_profile-task"
  mkdir -p "$state" "$wt"
  fm_write_meta "$state/task-a.meta" \
    "worktree=$wt" \
    "tasktmp=$case_dir/tasktmp"
  start_fake_browser "$wt" "$profile"
  pid=$FAKE_BROWSER_PID
  child_pid=$(pgrep -P "$pid" | head -1)
  [ -n "$child_pid" ] || fail "fake browser did not create its markerless child process"

  out=$(FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_BROWSER_REAP_GRACE_SECS=0 "$REAPER" --task task-a)
  wait_reaped "$pid" "task-exit reaper left a browser whose cwd was the task worktree"
  kill -0 "$child_pid" 2>/dev/null \
    && fail "task-exit reaper left a markerless child from the browser process tree"
  assert_contains "$out" "reaped browser pid=$pid task=task-a" \
    "task-exit reaper did not report the browser it terminated"
  pass "task-exit reaper terminates a Puppeteer browser tied by task cwd"
}

test_periodic_kills_orphan_but_preserves_live_task() {
  local case_dir state tag live_tmp orphan_tmp live_profile orphan_profile live_pid orphan_pid out
  case_dir="$TMP_ROOT/periodic"
  state="$case_dir/state"
  mkdir -p "$state"
  tag=$(home_tag "$case_dir")
  live_tmp="/tmp/fm-live-browser-test-$$/browser-$tag"
  orphan_tmp="/tmp/fm-orphan-browser-test-$$/browser-$tag"
  live_profile="$live_tmp/puppeteer_dev_chrome_profile-live"
  orphan_profile="$orphan_tmp/puppeteer_dev_chrome_profile-orphan"
  fm_write_meta "$state/live.meta" \
    "worktree=$case_dir/live-worktree" \
    "tasktmp=/tmp/fm-live-browser-test-$$" \
    "browsertmp=$live_tmp"
  start_fake_browser "$case_dir" "$live_profile"
  live_pid=$FAKE_BROWSER_PID
  start_fake_browser "$case_dir" "$orphan_profile"
  orphan_pid=$FAKE_BROWSER_PID

  out=$(FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_BROWSER_REAP_GRACE_SECS=0 "$REAPER")
  wait_reaped "$orphan_pid" "periodic reaper left a home-scoped orphan browser"
  kill -0 "$live_pid" 2>/dev/null || fail "periodic reaper killed a browser claimed by live task metadata"
  assert_contains "$out" "task=live reason=task is still recorded" \
    "periodic reaper did not report why it preserved the live task browser"
  assert_contains "$out" "reaped browser pid=$orphan_pid" \
    "periodic reaper did not report the orphan it terminated"
  rm -rf "/tmp/fm-live-browser-test-$$" "/tmp/fm-orphan-browser-test-$$"
  pass "periodic reaper kills only home-scoped orphan browsers"
}

test_unattributed_browser_is_left_alone() {
  local case_dir state profile pid out
  case_dir="$TMP_ROOT/unattributed"
  state="$case_dir/state"
  profile="$case_dir/captain-temp/puppeteer_dev_chrome_profile-unattributed"
  mkdir -p "$state"
  start_fake_browser "$case_dir" "$profile"
  pid=$FAKE_BROWSER_PID

  out=$(FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_BROWSER_REAP_GRACE_SECS=0 "$REAPER")
  kill -0 "$pid" 2>/dev/null || fail "periodic reaper killed an unattributed Puppeteer browser"
  assert_contains "$out" "left browser pid=$pid reason=not attributable to this Firstmate home" \
    "periodic reaper did not report the conservatively retained browser"
  pass "unattributed Puppeteer browsers are reported and left alone"
}

test_lifecycle_wiring_contract() {
  # shellcheck disable=SC2016  # These are literal source-contract strings.
  grep -F '"$reaper" --task "$task_id"' "$ROOT/bin/fm-teardown.sh" >/dev/null \
    || fail "fm-teardown does not invoke task-scoped browser reaping"
  # shellcheck disable=SC2016  # Literal source-contract string.
  grep -F '"$SCRIPT_DIR/fm-reap-browsers.sh" 2>&1' "$ROOT/bin/fm-watch.sh" >/dev/null \
    || fail "fm-watch does not invoke periodic browser reaping"
  # shellcheck disable=SC2016  # Literal source-contract string.
  grep -F 'spawn_send_text_line "$T" "export TMPDIR=$BROWSER_TMP"' "$ROOT/bin/fm-spawn.sh" >/dev/null \
    || fail "fm-spawn does not export task-attributable TMPDIR"
  # shellcheck disable=SC2016  # Literal source-contract string.
  grep -F 'echo "browsertmp=$BROWSER_TMP"' "$ROOT/bin/fm-spawn.sh" >/dev/null \
    || fail "fm-spawn does not record browser temp attribution"
  pass "spawn, periodic monitoring, and teardown carry the browser-reaping contract"
}

test_task_reaps_browser_tied_by_cwd
test_periodic_kills_orphan_but_preserves_live_task
test_unattributed_browser_is_left_alone
test_lifecycle_wiring_contract
