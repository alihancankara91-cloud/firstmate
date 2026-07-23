#!/usr/bin/env bash
# Safely shut down one task's agent before rotation, relaunch, or retirement.
# Usage: fm-agent-exit.sh <task-id>
#
# This script is the one mechanical owner of two contracts that used to live
# only in agent memory (and were violated on 2026-07-22/23 despite being
# written down):
#
#   1. Queued-message drain (rotation safety): before anything else, every
#      open parent-owned pending-reply expectation for the task is invalidated
#      (fm_pending_reply_invalidate_task, resolved_via=rotation), so no
#      recovery resend or escalation can deliver a stale correlation id to the
#      task's SUCCESSOR agent. The endpoint itself is removed at the end,
#      which destroys the pane's pty along with any keystrokes still buffered
#      at the outgoing agent - nothing typed at the old agent can surface in
#      front of a successor launched afterward.
#   2. Interrupt-then-exit ordering: an agent at or near 100% context cannot
#      process a typed exit command - it queues behind work the agent can no
#      longer reach. The interrupt is what actually lands. So the interrupt
#      key is always sent FIRST, then the exit command, then a bounded wait
#      for the agent process to end before the endpoint is removed.
#
# Per-harness interrupt keys and exit commands below encode the verified facts
# from the harness-adapters skill (the authority); when a harness's interrupt
# or exit fact changes there, update the table here in the same change.
# An unknown or unrecorded harness skips the graceful attempt and goes
# straight to endpoint removal, reported plainly.
#
# The exit command is sent through the backend submit core directly, NOT
# through fm-send: fm-send marks secondmate-bound text and creates a
# pending-reply expectation, and a lifecycle command must never carry a
# correlation id (that is exactly how the 2026-07-23 queued /exit became an
# unattributable instruction in front of a successor).
#
# Endpoint removal is verified: after fm_backend_kill the endpoint must be
# confirmed gone (retried once). A persisting endpoint FAILS the script,
# because a successor launched while the old endpoint survives can still
# receive input queued at it. This script never touches the task's worktree,
# metadata, status file, or backlog entry - rotation keeps the task identity,
# and relaunch stays with the stuck-crewmate-recovery contract.
#
# Tunables (env):
#   FM_AGENT_EXIT_INTERRUPT_SETTLE  seconds after the interrupt before the exit
#                                   command (default 2)
#   FM_AGENT_EXIT_WAIT              bounded seconds to wait for the agent
#                                   process to end after the exit command
#                                   (default 20)
#   FM_AGENT_EXIT_POLL              seconds between liveness polls (default 1)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  cat <<'EOF'
Usage: fm-agent-exit.sh <task-id>

Safely shuts down the task's recorded agent: invalidates queued pending-reply
requests so nothing can chase a successor, interrupts FIRST so a wedged agent
can accept the exit command, sends the harness exit command, waits bounded for
the agent to end, then removes the endpoint and verifies it is gone.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# rotate or exit a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-agent-exit refuses to resolve tasks without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-agent-exit cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the agent exit WILL still proceed.' "$SCRIPT_DIR/fm-guard.sh" || true

ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
BACKEND=$(fm_backend_of_meta "$META")
T=$(fm_backend_target_of_meta "$META")
HARNESS=$(fm_meta_get "$META" harness)
LABEL="fm-$ID"

fm_backend_validate "$BACKEND" || exit 1

INTERRUPT_SETTLE=${FM_AGENT_EXIT_INTERRUPT_SETTLE:-2}
EXIT_WAIT=${FM_AGENT_EXIT_WAIT:-20}
EXIT_POLL=${FM_AGENT_EXIT_POLL:-1}

# 1) Invalidate queued marked requests so nothing chases the successor.
INVALIDATED=$(fm_pending_reply_invalidate_task "$STATE" "$ID") || {
  echo "error: could not invalidate pending-reply records for $ID; refusing to rotate with a live queued-request path" >&2
  exit 1
}
if [ -n "$INVALIDATED" ]; then
  COUNT=$(printf '%s\n' "$INVALIDATED" | grep -c . || true)
  echo "invalidated $COUNT queued pending-reply request(s) for $ID: $(printf '%s' "$INVALIDATED" | tr '\n' ' ')"
else
  echo "no queued pending-reply requests for $ID"
fi

# Per-harness interrupt keys and exit command (see header for the authority).
INTERRUPT_KEYS=
EXIT_CMD=
case "$HARNESS" in
  claude) INTERRUPT_KEYS='Escape'; EXIT_CMD='/exit' ;;
  codex) INTERRUPT_KEYS='Escape'; EXIT_CMD='/quit' ;;
  opencode) INTERRUPT_KEYS='Escape Escape'; EXIT_CMD='/exit' ;;
  pi) INTERRUPT_KEYS='Escape'; EXIT_CMD='/quit' ;;
  grok) INTERRUPT_KEYS='C-c'; EXIT_CMD='/exit' ;;
esac

agent_state() {
  fm_backend_agent_alive "$BACKEND" "$T" 2>/dev/null || printf 'unknown'
}

GRACEFUL_EXIT=0
if [ -n "$T" ] && fm_backend_target_exists "$BACKEND" "$T" "$LABEL" 2>/dev/null; then
  ALIVE=$(agent_state)
  if [ "$ALIVE" = dead ]; then
    echo "agent for $ID already exited; only endpoint cleanup remains"
    GRACEFUL_EXIT=1
  elif [ -z "$EXIT_CMD" ]; then
    echo "harness '${HARNESS:-unrecorded}' has no verified interrupt/exit facts; skipping the graceful exit and removing the endpoint"
  else
    # 2) Interrupt FIRST, so a wedged agent regains a composer that can
    # actually process the exit command instead of queueing it.
    for KEY in $INTERRUPT_KEYS; do
      if ! fm_backend_send_key "$BACKEND" "$T" "$KEY" "$LABEL" 2>/dev/null; then
        echo "warning: interrupt key $KEY not accepted by $BACKEND target $T; continuing to the exit command" >&2
        break
      fi
      sleep 0.3
    done
    sleep "$INTERRUPT_SETTLE"
    # 3) Exit command through the backend submit core (never fm-send: no
    # marker, no pending-reply record for a lifecycle command). The 1.2s
    # settle matches fm-send's slash-command popup handling.
    if ! VERDICT=$(fm_backend_send_text_submit "$BACKEND" "$T" "$EXIT_CMD" "${FM_SEND_RETRIES:-3}" "${FM_SEND_SLEEP:-0.4}" 1.2 "$LABEL" 2>/dev/null); then
      VERDICT=send-failed
    fi
    case "$VERDICT" in
      pending|send-failed)
        echo "exit command did not land cleanly on $ID ($VERDICT); relying on endpoint removal" >&2
        ;;
    esac
    # 4) Bounded wait for the agent process to actually end.
    WAITED=0
    while [ "$WAITED" -lt "$EXIT_WAIT" ]; do
      if [ "$(agent_state)" = dead ]; then
        GRACEFUL_EXIT=1
        break
      fi
      if ! fm_backend_target_exists "$BACKEND" "$T" "$LABEL" 2>/dev/null; then
        GRACEFUL_EXIT=1
        break
      fi
      sleep "$EXIT_POLL"
      WAITED=$((WAITED + 1))
    done
    if [ "$GRACEFUL_EXIT" = 1 ]; then
      echo "agent for $ID exited after interrupt-then-exit"
    else
      echo "agent for $ID did not confirm exit within ${EXIT_WAIT}s; removing the endpoint" >&2
    fi
  fi
else
  echo "no live endpoint recorded for $ID; nothing queued at it can reach a successor"
fi

# 5) Remove the endpoint and verify it is gone. Destroying the pane destroys
# its pty, and with it any input still buffered at the outgoing agent.
if [ -n "$T" ] && fm_backend_target_exists "$BACKEND" "$T" "$LABEL" 2>/dev/null; then
  fm_backend_kill "$BACKEND" "$T" "$(fm_meta_get "$META" zellij_tab_id)" "$LABEL" 2>/dev/null || true
  if fm_backend_target_exists "$BACKEND" "$T" "$LABEL" 2>/dev/null; then
    sleep 1
    fm_backend_kill "$BACKEND" "$T" "$(fm_meta_get "$META" zellij_tab_id)" "$LABEL" 2>/dev/null || true
    if fm_backend_target_exists "$BACKEND" "$T" "$LABEL" 2>/dev/null; then
      echo "error: endpoint $T for $ID survived removal; a successor launched now could still receive input queued at it. Do not relaunch until the endpoint is confirmed gone." >&2
      exit 1
    fi
  fi
fi
echo "agent-exit $ID complete (endpoint ${T:-none} removed; graceful=$GRACEFUL_EXIT)"
