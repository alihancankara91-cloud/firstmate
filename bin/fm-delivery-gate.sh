#!/usr/bin/env bash
# fm-delivery-gate.sh - operate the delivery gate for a task.
#
# The verification contract - what counts as delivered, the two evidence arms,
# fail-closed rules, scope, and enforcement points - is owned by
# bin/fm-delivery-lib.sh. This CLI is the operator surface.
#
# Usage:
#   fm-delivery-gate.sh verify <task-id>
#       Verify delivery against the remote and the PR's own file list.
#       Prints PASS with the evidence (including the forge-side file list) or
#       REFUSED with every reason. A pass writes durable evidence to
#       data/<task-id>/delivered.md, which bin/fm-spawn.sh --requires reads.
#       Exit 0 pass/override/not-applicable, 1 refused, 2 usage.
#   fm-delivery-gate.sh expect <task-id> <repo-relative-path>...
#       Record expected deliverable paths (deliverable= lines in the task's
#       metadata). Firstmate records these at intake from the task's
#       acceptance criteria; the worker never does. Idempotent.
#   fm-delivery-gate.sh override <task-id> --reason <text>
#       Record the deliberate, loud exception: the task may complete without
#       remote delivery verification. Writes state/<task-id>.delivery-override
#       and durable data/<task-id>/delivery-override.md. Only use with
#       explicit captain authority; the override is printed loudly by every
#       later gate check and teardown.
#   fm-delivery-gate.sh status <task-id>
#       Show recorded expectations, override, and durable delivery evidence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

CMD=${1:-}
case "$CMD" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
shift
ID=${1:-}
if ! fm_task_id_path_safe "$ID"; then
  echo "error: invalid task id" >&2
  exit 2
fi
shift
META="$STATE/$ID.meta"

case "$CMD" in
  verify)
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    if fm_delivery_verify "$ID" "$STATE" "$DATA"; then
      case "$FM_DELIVERY_RESULT" in
        not-applicable)
          printf 'NOT APPLICABLE: %s\n' "$FM_DELIVERY_EVIDENCE"
          ;;
        override)
          printf 'PASS (OVERRIDE):\n%s\n' "$FM_DELIVERY_EVIDENCE"
          fm_delivery_record "$ID" "$DATA" || {
            echo "error: could not write durable delivery record data/$ID/delivered.md" >&2
            exit 1
          }
          ;;
        *)
          printf 'PASS: delivery verified for %s\n%s\n' "$ID" "$FM_DELIVERY_EVIDENCE"
          fm_delivery_record "$ID" "$DATA" || {
            echo "error: could not write durable delivery record data/$ID/delivered.md" >&2
            exit 1
          }
          printf 'recorded: data/%s/delivered.md\n' "$ID"
          ;;
      esac
      exit 0
    fi
    printf 'REFUSED: %s is NOT delivered.\n%s\n' "$ID" "$FM_DELIVERY_REASONS" >&2
    echo "A commit is not delivery; neither is a pushed branch or a green pipeline." >&2
    echo "Deliver the work (push, raise the PR, verify its file list), or record a deliberate exception with: bin/fm-delivery-gate.sh override $ID --reason '<why>'" >&2
    exit 1
    ;;
  expect)
    [ "$#" -ge 1 ] || { echo "error: expect needs at least one repo-relative path" >&2; exit 2; }
    [ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no task metadata at $META" >&2; exit 1; }
    for p in "$@"; do
      fm_delivery_path_valid "$p" || { echo "error: invalid deliverable path '$p' (must be repo-relative, no .., not option-like)" >&2; exit 2; }
    done
    for p in "$@"; do
      grep -qxF "deliverable=$p" "$META" || printf 'deliverable=%s\n' "$p" >> "$META"
    done
    printf 'recorded %d expected deliverable path(s) for %s:\n' "$#" "$ID"
    fm_delivery_deliverables "$META"
    ;;
  override)
    REASON=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason)
          [ "$#" -ge 2 ] || { echo "error: --reason requires a value" >&2; exit 2; }
          REASON=$2
          shift 2 ;;
        *) echo "error: unknown override argument '$1'" >&2; exit 2 ;;
      esac
    done
    case "$REASON" in
      *[!\ ]*) ;;
      *) echo "error: override requires a non-empty --reason" >&2; exit 2 ;;
    esac
    case "$REASON" in
      *$'\n'*) echo "error: --reason must be a single line" >&2; exit 2 ;;
    esac
    [ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no task metadata at $META" >&2; exit 1; }
    NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf 'reason=%s\nrecorded=%s\n' "$REASON" "$NOW" > "$STATE/$ID.delivery-override"
    chmod 0600 "$STATE/$ID.delivery-override"
    mkdir -p "$DATA/$ID"
    {
      printf '# Delivery gate override: %s\n\n' "$ID"
      printf -- '- recorded: %s\n' "$NOW"
      printf -- '- reason: %s\n\n' "$REASON"
      printf 'This task was allowed to complete WITHOUT remote delivery verification.\n'
      printf 'The delivery gate (bin/fm-delivery-lib.sh) did not prove its work is on\n'
      printf 'the remote as a verified pull request. If the work was supposed to land,\n'
      printf 'verify it by hand.\n'
    } > "$DATA/$ID/delivery-override.md"
    printf 'DELIVERY GATE OVERRIDE RECORDED for %s.\n' "$ID"
    printf 'Reason: %s\n' "$REASON"
    printf 'The gate will pass this task LOUDLY without verifying remote delivery.\n'
    printf 'Records: state/%s.delivery-override, data/%s/delivery-override.md\n' "$ID" "$ID"
    ;;
  status)
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    printf 'task: %s\n' "$ID"
    if [ -f "$META" ]; then
      printf 'kind: %s\n' "$(fm_delivery_meta_get "$META" kind)"
      printf 'mode: %s\n' "$(fm_delivery_meta_get "$META" mode)"
      printf 'pr: %s\n' "$(fm_delivery_meta_get "$META" pr)"
      DELIV=$(fm_delivery_deliverables "$META")
      if [ -n "$DELIV" ]; then
        printf 'expected deliverables:\n%s\n' "$DELIV"
      else
        printf 'expected deliverables: none recorded\n'
      fi
    else
      printf 'metadata: absent (%s)\n' "$META"
    fi
    if fm_delivery_override_active "$STATE" "$ID"; then
      printf 'override: ACTIVE - %s\n' "$FM_DELIVERY_OVERRIDE_REASON"
    else
      printf 'override: none\n'
    fi
    if [ -f "$DATA/$ID/delivered.md" ]; then
      printf 'durable delivery evidence: data/%s/delivered.md\n' "$ID"
    else
      printf 'durable delivery evidence: none\n'
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
