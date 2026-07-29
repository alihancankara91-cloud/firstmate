#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes.
# The same predicate also refuses a turn while this home's durable wake queue
# represents an undrained, still-open decision or blocker, even when watcher
# supervision is healthy.
# bin/fm-classify-lib.sh owns the status fold and structured escalation format.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/fm-claude-stop-autoarm.sh), which fires on the same Stop event.
# A live watcher, an auto-arm claim, or a fresh rewake resolves only the
# supervision predicate; a queued open escalation still requires a bounded
# continuation so the primary drains and handles it.
# Missing auto-arm recovery is bounded by FM_CLAUDE_TURNEND_BLOCK_BUDGET
# (default 3), safely below Claude Code's hard 8-consecutive-block override.
# Any allow resets the consecutive-block budget.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
CLAUDE_MODE=0
SYNC_WAIT_MS=${FM_CLAUDE_AUTOARM_SYNC_WAIT_MS:-800}
EPOCH_FRESH=${FM_CLAUDE_AUTOARM_EPOCH_FRESH:-15}
BLOCK_BUDGET=${FM_CLAUDE_TURNEND_BLOCK_BUDGET:-3}
case "$SYNC_WAIT_MS" in ''|*[!0-9]*) SYNC_WAIT_MS=800 ;; esac
case "$EPOCH_FRESH" in ''|*[!0-9]*|0) EPOCH_FRESH=15 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    *) echo "usage: $(basename "$0") [--claude]" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$CLAUDE_MODE" -eq 0 ] && [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

# A queue row is only a delivery obligation while its structurally mapped,
# home-local status stream still has the same decision key open. A later
# resolved/captain-held event closes it, payload paths are ignored, and draining
# the queue clears this turn-end condition exactly as the handling contract says.
PENDING_ESCALATIONS=$(queued_open_escalations "$STATE/.wake-queue" "$STATE")

BUDGET_FILE="$STATE/.turnend-claude-blocks"
budget_reset() {
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  rm -f "$BUDGET_FILE" 2>/dev/null || true
}

fm_supervision_status "$STATE" "$GRACE"
WATCHER_REQUIRED=0
if [ "$CLAUDE_MODE" -eq 1 ]; then
  [ "$FM_SUP_NEEDED" = true ] && WATCHER_REQUIRED=1
else
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && WATCHER_REQUIRED=1
fi
WATCHER_UNHEALTHY=0
if [ "$WATCHER_REQUIRED" -eq 1 ] \
   && ! fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  WATCHER_UNHEALTHY=1
fi
if [ -z "$PENDING_ESCALATIONS" ] && [ "$WATCHER_UNHEALTHY" -eq 0 ]; then
  budget_reset
  exit 0
fi

block_stop() {
  local afk x_mode reason rule task key verb note label
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    if [ -n "$PENDING_ESCALATIONS" ]; then
      printf '●%s\n' "$rule"
      printf '●  TURN CANNOT END - A WORKER ESCALATION IS STILL UNDRAINED\n'
      while IFS=$'\t' read -r task key verb note; do
        [ -n "$task" ] || continue
        case "$verb" in
          needs-decision) label='Decision needed' ;;
          blocked) label='Work blocked' ;;
          *) continue ;;
        esac
        if [ "$key" = default ]; then
          printf '●  %s for %s: %s\n' "$label" "$task" "$note"
        else
          printf '●  %s for %s [%s]: %s\n' "$label" "$task" "$key" "$note"
        fi
      done <<EOF
$PENDING_ESCALATIONS
EOF
      printf '●  Run bin/fm-wake-drain.sh first, then relay or resolve the concrete escalation before replying.\n'
      printf '●%s\n' "$rule"
    fi
    if [ "$WATCHER_UNHEALTHY" -eq 1 ]; then
      afk=0
      [ -e "$STATE/.afk" ] && afk=1
      x_mode=0
      [ -f "$CONFIG/x-mode.env" ] && x_mode=1
      reason=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
        || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
      printf '●%s\n' "$rule"
      printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
      if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
        printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
      else
        printf '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_BEACON_DESC"
      fi
      if [ "$CLAUDE_MODE" -eq 1 ]; then
        printf '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.\n'
      fi
      printf '●  %s\n' "$reason"
      printf '●%s\n' "$rule"
    fi
  } >&2
  exit 2
}

if [ "$CLAUDE_MODE" -eq 0 ]; then
  block_stop
fi

# --- --claude cooperative path -----------------------------------------------
# The Stop-owned auto-arm fires on the same Stop event. Give it a brief bounded
# window to prove it owns supervision recovery for this event epoch before
# consuming one of Claude's bounded continuations.
autoarm_owns_recovery() {
  local pid outcome age
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0
  pid=$(cat "$STATE/.claude-autoarm.lock/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" && return 0
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  if [ "$outcome" = rewake ]; then
    age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
    [ "$age" -lt "$EPOCH_FRESH" ] && return 0
  fi
  return 1
}

if [ "$WATCHER_UNHEALTHY" -eq 1 ]; then
  i=0
  while [ "$i" -lt $((SYNC_WAIT_MS / 100)) ]; do
    if autoarm_owns_recovery; then
      WATCHER_UNHEALTHY=0
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$WATCHER_UNHEALTHY" -eq 1 ] && autoarm_owns_recovery; then
    WATCHER_UNHEALTHY=0
  fi
fi
if [ -z "$PENDING_ESCALATIONS" ] && [ "$WATCHER_UNHEALTHY" -eq 0 ]; then
  budget_reset
  exit 0
fi

# An open escalation or genuinely absent auto-arm still requires a continuation,
# but the budget guarantees that the Claude session can always end.
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
COUNT=0
if [ -f "$BUDGET_FILE" ]; then
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  [ "$old_session" = "$SESSION_ID" ] && COUNT=$old_count
fi
COUNT=$((COUNT + 1))
if [ "$COUNT" -gt "$BLOCK_BUDGET" ]; then
  budget_reset
  if [ -n "$PENDING_ESCALATIONS" ] && [ "$WATCHER_UNHEALTHY" -eq 1 ]; then
    NEED_DESC="an undrained worker escalation and missing supervision recovery"
    NEXT_DESC="Drain and handle the escalation, then repair supervision or investigate why bin/fm-claude-stop-autoarm.sh is not claiming this home."
  elif [ -n "$PENDING_ESCALATIONS" ]; then
    NEED_DESC="an undrained worker escalation"
    NEXT_DESC="Run bin/fm-wake-drain.sh and handle the concrete escalation."
  elif [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    NEED_DESC="$FM_SUP_IN_FLIGHT task(s) in flight with no live watcher or Stop auto-arm claim"
    NEXT_DESC="Repair supervision or investigate why bin/fm-claude-stop-autoarm.sh is not claiming this home."
  else
    NEED_DESC="X-mode relay polling with no live watcher or Stop auto-arm claim"
    NEXT_DESC="Repair supervision or investigate why bin/fm-claude-stop-autoarm.sh is not claiming this home."
  fi
  printf '{"systemMessage":"firstmate turn-end guard: %s; block budget exhausted, allowing this stop. %s"}\n' "$NEED_DESC" "$NEXT_DESC"
  exit 0
fi
printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$COUNT" > "$BUDGET_FILE" 2>/dev/null || true
block_stop
