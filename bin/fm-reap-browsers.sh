#!/usr/bin/env bash
# Reap Puppeteer Chrome processes that belong to one finished task or to no
# longer-recorded tasks in this Firstmate home.
#
# New tasks export a home-scoped browser temp directory from fm-spawn.sh, so
# Puppeteer's `puppeteer_dev_chrome_profile-*` user-data directory carries both
# task and home attribution in the browser command line. Older task browsers can
# still be attributed during teardown when their process or an ancestor has a
# cwd inside the recorded worktree or task temp root.
#
# Safety is deliberately conservative. A process is terminated only when it is
# a Chrome-family process with the Puppeteer profile marker and either:
#   - --task <id>: its profile or process ancestry ties it to that task's
#     recorded worktree, task temp root, or browser temp root; or
#   - periodic mode: its profile ties it to this home's browser temp namespace
#     and no live task metadata claims it.
# Unattributed Puppeteer browsers are reported and left alone. This means the
# captain's Chrome and Puppeteer sessions from outside Firstmate are never
# selected merely because they are headless or have a Puppeteer profile.
# Selected browser roots and their exact snapshotted descendant trees receive
# TERM, then KILL after FM_BROWSER_REAP_GRACE_SECS (default 2). Every PID's
# command is rechecked before each signal to avoid PID-reuse kills. Reaped and
# conservatively retained candidates are printed.
#
# Usage: fm-reap-browsers.sh [--task <task-id>]
# Environment seams used by tests:
#   FM_BROWSER_REAP_GRACE_SECS  TERM grace period in seconds.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$SCRIPT_DIR/fm-backend-hometag-lib.sh"

MODE=periodic
TASK_ID=
case "${1:-}" in
  '') ;;
  --task)
    [ "$#" -eq 2 ] || { echo "usage: fm-reap-browsers.sh [--task <task-id>]" >&2; exit 2; }
    MODE=task
    TASK_ID=$2
    case "$TASK_ID" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 2 ;; esac
    ;;
  *) echo "usage: fm-reap-browsers.sh [--task <task-id>]" >&2; exit 2 ;;
esac

GRACE=${FM_BROWSER_REAP_GRACE_SECS:-2}
case "$GRACE" in ''|*[!0-9.]*) GRACE=2 ;; esac
HOME_TAG=$(fm_backend_hometag)
BROWSER_SEGMENT="/browser-$HOME_TAG"
SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fm-reap-browsers.XXXXXX") || exit 1
trap 'rm -f "$SNAPSHOT"' EXIT HUP INT TERM
COLUMNS=10000 LC_ALL=C ps -axo pid=,ppid=,command= > "$SNAPSHOT" || {
  echo "fm-reap-browsers: could not read the process table; no processes changed" >&2
  exit 1
}

is_browser_candidate() {  # <command>
  case "$1" in *puppeteer_dev_chrome_profile*) ;; *) return 1 ;; esac
  case "$1" in
    *'/Google Chrome'*|*'/Chromium'*|*'/chrome-headless-shell'*|*' chrome-headless-shell '*|*'/chrome '*|*' HeadlessChrome '*) return 0 ;;
  esac
  return 1
}

profile_from_command() {  # <command>
  local token next=0
  for token in $1; do
    token=${token#\"}
    token=${token%\"}
    token=${token#\'}
    token=${token%\'}
    if [ "$next" -eq 1 ]; then
      case "$token" in *puppeteer_dev_chrome_profile*) printf '%s\n' "$token"; return 0 ;; esac
      return 1
    fi
    case "$token" in
      --user-data-dir=*)
        token=${token#--user-data-dir=}
        case "$token" in *puppeteer_dev_chrome_profile*) printf '%s\n' "$token"; return 0 ;; esac
        return 1
        ;;
      --user-data-dir) next=1 ;;
    esac
  done
  return 1
}

canonical_path() {  # <path>
  local path=$1 parent base
  [ -n "$path" ] || return 1
  if [ -d "$path" ]; then
    (cd "$path" 2>/dev/null && pwd -P)
    return $?
  fi
  parent=${path%/*}
  base=${path##*/}
  [ "$parent" != "$path" ] || parent=.
  parent=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$parent" "$base"
}

path_within() {  # <path> <root>
  local path root
  path=$(canonical_path "$1" 2>/dev/null || printf '%s' "$1")
  root=$(canonical_path "${2%/}" 2>/dev/null || printf '%s' "${2%/}")
  [ -n "$path" ] && [ -n "$root" ] && [ "$root" != / ] || return 1
  case "$path" in "$root"|"$root"/*) return 0 ;; esac
  return 1
}

snapshot_ppid() {  # <pid>
  awk -v pid="$1" '$1 == pid { print $2; exit }' "$SNAPSHOT"
}

cwd_for_pid() {  # <pid>
  local cwd
  if command -v lsof >/dev/null 2>&1; then
    cwd=$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ -n "$cwd" ] && { printf '%s\n' "${cwd% (deleted)}"; return 0; }
  fi
  if [ -L "/proc/$1/cwd" ]; then
    readlink "/proc/$1/cwd" 2>/dev/null
    return $?
  fi
  return 1
}

ancestry_tied_to_root() {  # <pid> <root>
  local pid=$1 root=$2 cwd ppid depth=0
  [ -n "$root" ] || return 1
  while [ "$depth" -lt 32 ]; do
    cwd=$(cwd_for_pid "$pid" 2>/dev/null || true)
    path_within "$cwd" "$root" && return 0
    ppid=$(snapshot_ppid "$pid")
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$ppid" -gt 1 ] || return 1
    pid=$ppid
    depth=$((depth + 1))
  done
  return 1
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

candidate_tied_to_meta() {  # <pid> <profile> <meta>
  local pid=$1 profile=$2 meta=$3 root
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  for root in "$(meta_value "$meta" browsertmp)" "$(meta_value "$meta" tasktmp)" "$(meta_value "$meta" worktree)"; do
    [ -n "$root" ] || continue
    path_within "$profile" "$root" && return 0
    ancestry_tied_to_root "$pid" "$root" && return 0
  done
  return 1
}

live_meta_for_candidate() {  # <pid> <profile>
  local meta
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    candidate_tied_to_meta "$1" "$2" "$meta" && { printf '%s\n' "$meta"; return 0; }
  done
  return 1
}

current_command() {  # <pid>
  COLUMNS=10000 LC_ALL=C ps -p "$1" -o command= 2>/dev/null | sed 's/^[[:space:]]*//'
}

process_is_gone() {  # <pid>
  local stat
  kill -0 "$1" 2>/dev/null || return 0
  stat=$(LC_ALL=C ps -p "$1" -o stat= 2>/dev/null | tr -d '[:space:]')
  case "$stat" in ''|Z*) return 0 ;; esac
  return 1
}

reap_pid() {  # <pid> <original-command> <task-label> <attribution>
  local pid=$1 original=$2 label=$3 attribution=$4 current waited=0 changed child parent child_command i known alive failures=0
  local target_pids=("$pid") target_commands=("$original")

  # Capture the complete browser subtree before signaling its root. Chrome
  # renderer, utility, GPU, and crash-handler children often omit the profile
  # marker, but their ancestry is exact attribution. Killing the recorded PIDs
  # individually avoids the agent-wide process group.
  while :; do
    changed=0
    while read -r child parent child_command; do
      case "$child:$parent" in *[!0-9:]*) continue ;; esac
      case " ${target_pids[*]} " in *" $parent "*) ;; *) continue ;; esac
      known=0
      for i in "${target_pids[@]}"; do
        [ "$i" = "$child" ] && { known=1; break; }
      done
      [ "$known" -eq 0 ] || continue
      target_pids+=("$child")
      target_commands+=("$child_command")
      changed=1
    done < "$SNAPSHOT"
    [ "$changed" -eq 1 ] || break
  done

  for i in "${!target_pids[@]}"; do
    process_is_gone "${target_pids[$i]}" && continue
    current=$(current_command "${target_pids[$i]}")
    if [ "$current" = "${target_commands[$i]}" ]; then
      kill -TERM "${target_pids[$i]}" 2>/dev/null || true
    else
      echo "left browser descendant pid=${target_pids[$i]} reason=process identity changed before TERM"
    fi
  done
  while awk -v n="$waited" -v g="$GRACE" 'BEGIN { exit !(n < g) }'; do
    alive=0
    for child in "${target_pids[@]}"; do
      process_is_gone "$child" || { alive=1; break; }
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.1
    waited=$(awk -v n="$waited" 'BEGIN { printf "%.1f", n + 0.1 }')
  done
  for i in "${!target_pids[@]}"; do
    process_is_gone "${target_pids[$i]}" && continue
    current=$(current_command "${target_pids[$i]}")
    if [ "$current" = "${target_commands[$i]}" ]; then
      kill -KILL "${target_pids[$i]}" 2>/dev/null || true
    else
      echo "left browser descendant pid=${target_pids[$i]} reason=process identity changed before KILL"
    fi
  done
  sleep 0.1
  for i in "${!target_pids[@]}"; do
    process_is_gone "${target_pids[$i]}" && continue
    current=$(current_command "${target_pids[$i]}")
    [ "$current" = "${target_commands[$i]}" ] || continue
    echo "left browser pid=${target_pids[$i]} task=$label reason=survived TERM and KILL" >&2
    failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || return 1
  echo "reaped browser pid=$pid task=$label attribution=$attribution processes=${#target_pids[@]}"
  return 0
}

failures=0
while read -r pid ppid command; do
  case "$pid:$ppid" in *[!0-9:]*) continue ;; esac
  [ "$pid" != "$$" ] || continue
  is_browser_candidate "$command" || continue
  profile=$(profile_from_command "$command" 2>/dev/null || true)
  if [ -z "$profile" ]; then
    echo "left browser pid=$pid reason=Puppeteer profile path could not be parsed"
    continue
  fi

  if [ "$MODE" = task ]; then
    meta="$STATE/$TASK_ID.meta"
    if candidate_tied_to_meta "$pid" "$profile" "$meta"; then
      reap_pid "$pid" "$command" "$TASK_ID" recorded-task || failures=$((failures + 1))
    else
      echo "left browser pid=$pid reason=not attributable to task $TASK_ID"
    fi
    continue
  fi

  if live_meta=$(live_meta_for_candidate "$pid" "$profile"); then
    echo "left browser pid=$pid task=$(basename "$live_meta" .meta) reason=task is still recorded"
    continue
  fi
  # Match the home tag with slash boundaries so another home's similarly
  # prefixed tag cannot match. The task id is the fm-* directory above it.
  case "$profile" in
    *"$BROWSER_SEGMENT"/*)
      task_part=${profile%%"$BROWSER_SEGMENT"*}
      task_part=${task_part##*/}
      task_part=${task_part#fm-}
      case "$task_part" in ''|*[!A-Za-z0-9._-]*) task_part=unknown ;; esac
      reap_pid "$pid" "$command" "$task_part" home-scoped-profile || failures=$((failures + 1))
      ;;
    *) echo "left browser pid=$pid reason=not attributable to this Firstmate home" ;;
  esac
done < "$SNAPSHOT"

[ "$failures" -eq 0 ]
