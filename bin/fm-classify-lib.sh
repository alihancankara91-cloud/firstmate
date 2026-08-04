#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale is working, deliberately
# paused, or neither. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# The structured escalation line contract below is the ONE full owner of the
# format emitted into newly scaffolded worker instructions. Callers and docs
# cross-reference this function rather than restating its fields. Legacy
# "needs-decision: <note>" and "blocked: <note>" lines remain valid inputs to
# every classifier and fold, so already-running and older workers still surface.
status_escalation_format_contract() {
  cat <<'EOF'
For every new decision or blocker, use one concise single-line structured escalation with a stable key.
- `needs-decision [key=<slug>]: need=<concrete decision> | options=<A; B; ...> | recommend=<option and why>`
- `blocked [key=<slug>]: need=<concrete blocker> | action=<what firstmate must do> | recommend=<next step and why>`
Keep each value non-empty and do not use tabs, newlines, or the literal ` | ` separator inside a value.
Older unstructured `needs-decision:` and `blocked:` lines remain compatible, but newly scaffolded work must use the structured form above.
EOF
}

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}

# 0 only when one line matches the structured contract emitted by
# status_escalation_format_contract. Classification never requires this: legacy
# unstructured decision and blocker lines intentionally remain actionable.
status_escalation_is_structured() {  # <status-line>
  local line=$1 verb prefix key note first second third
  verb=$(status_line_verb "$line")
  case "$verb" in needs-decision|blocked) ;; *) return 1 ;; esac
  prefix=${line%%:*}
  case "$prefix" in *\[key=*\]*) ;; *) return 1 ;; esac
  key=$(_fm_decision_key "$line") || return 1
  [ "$key" != default ] || return 1
  note=$(status_line_note "$line")
  case "$verb:$note" in
    needs-decision:need=*' | options='*' | recommend='*)
      first=${note#need=}; first=${first%%' | options='*}
      second=${note#*' | options='}; second=${second%%' | recommend='*}
      third=${note#*' | recommend='}
      ;;
    blocked:need=*' | action='*' | recommend='*)
      first=${note#need=}; first=${first%%' | action='*}
      second=${note#*' | action='}; second=${second%%' | recommend='*}
      third=${note#*' | recommend='}
      ;;
    *) return 1 ;;
  esac
  [ -n "$(printf '%s' "$first" | tr -d '[:space:]')" ] || return 1
  [ -n "$(printf '%s' "$second" | tr -d '[:space:]')" ] || return 1
  [ -n "$(printf '%s' "$third" | tr -d '[:space:]')" ] || return 1
  case "$first$second$third" in *$'\t'*|*$'\n'*|*' | '*) return 1 ;; esac
  return 0
}
# Drop the record for <key> from a newline-terminated keyed event set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. The event
# variant retains the opening line number so a reopened decision with identical
# text is a new event rather than a duplicate of its earlier occurrence.
_fm_status_open_decision_events_stream() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped line_no=0
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\t'"${line_no}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Print the still-open decision events as TAB-separated
# "<key>\t<verb>\t<summary>\t<opening-line>" rows.
status_open_decision_events() {  # <status-file>
  _fm_status_open_decision_events_stream "$1"
}

# Print one TAB-separated "<key>\t<verb>\t<summary>" row per still-open
# decision, in most-recently-opened-last order. This is the durable open-set the
# fleet snapshot and every point-in-time consumer must use instead of trusting the
# last status line.
status_open_decisions() {  # <status-file>
  local f=$1 key verb note line_no
  while IFS=$'\t' read -r key verb note line_no; do
    [ -n "$key" ] || continue
    printf '%s\t%s\t%s\n' "$key" "$verb" "$note"
  done <<EOF
$(status_open_decision_events "$f")
EOF
}

# Print the last non-blank status event as "<physical-line>\t<line>".
status_last_event_info() {  # <status-file>
  local f=$1 line line_no=0 last='' last_no=0 stripped
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    last=$line
    last_no=$line_no
  done < "$f"
  [ "$last_no" -gt 0 ] || return 0
  printf '%s\t%s' "$last_no" "$last"
}

# Print a stable identity for one status event. Decision identities include the
# keyed opening line, while terminal and legacy identities include their physical
# line. This distinguishes a reopened decision even when its text is unchanged.
status_event_identity() {  # <physical-line> <status-line>
  local line_no=$1 line=$2 verb key
  verb=$(status_line_verb "$line")
  case "$verb" in
    needs-decision|blocked)
      key=$(_fm_decision_key "$line") || { printf 'line:%s' "$line_no"; return 0; }
      printf 'decision:%s:%s' "$key" "$line_no"
      ;;
    *) printf 'line:%s' "$line_no" ;;
  esac
}

# Print the identity of the current non-blank status event for per-wake
# classification and its shared daemon dedup marker.
status_current_event_identity() {  # <status-file>
  local info line_no line
  info=$(status_last_event_info "$1")
  [ -n "$info" ] || return 1
  line_no=${info%%$'\t'*}
  line=${info#*$'\t'}
  status_event_identity "$line_no" "$line"
}

# Encode one escalation into the watcher reason without exposing a status path as
# the only content. The token is single-field queue-safe and decodes to the exact
# note. The task, key, and verb alphabets cannot contain colons. Pi's existing
# watcher bridge translates this token into a visible captain-facing message.
status_escalation_token() {  # <task> <key> <verb> <note>
  local task=$1 key=$2 verb=$3 note=$4 encoded
  case "$task:$key:$verb" in
    *[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  case "$verb" in needs-decision|blocked) ;; *) return 1 ;; esac
  encoded=$(printf '%s' "$note" | base64 | tr -d '\r\n') || return 1
  printf 'fm-escalation-v1:%s:%s:%s:%s' "$task" "$key" "$verb" "$encoded"
}

# Print zero or more space-prefixed escalation tokens for the local status files
# represented by one watcher signal batch. A turn-ended key maps only to its
# sibling home-local status file. Open-set folding, rather than last-line reads,
# keeps an earlier unresolved decision visible behind later unrelated events.
signal_escalation_tokens() {  # <status-or-turn-ended-path> ...
  local f base task statusf open key verb note token seen=''
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status) task=${base%.status}; statusf=$f ;;
      *.turn-ended) task=${base%.turn-ended}; statusf=${f%/*}/$task.status ;;
      *) continue ;;
    esac
    case "$task" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    [ -f "$statusf" ] && [ ! -L "$statusf" ] || continue
    open=$(status_open_decisions "$statusf")
    while IFS=$'\t' read -r key verb note; do
      [ -n "$key" ] || continue
      case "$seen" in *"|$task:$key|"*) continue ;; esac
      token=$(status_escalation_token "$task" "$key" "$verb" "$note") || continue
      seen="$seen|$task:$key|"
      printf ' %s' "$token"
    done <<EOF
$open
EOF
  done
}

# Print the still-open local escalations represented by undrained signal records
# in one home's durable wake queue. Requires fm-wake-lib.sh to be sourced first
# for the structural queue-key mapper. Payload paths and records for other homes
# are never authority. Output is TAB-separated task, key, verb, and exact note.
queued_open_escalations() {  # <wake-queue> <state-dir>
  local queue=$1 state=$2 _epoch _seq kind queue_key _payload status_key statusf task open key verb note seen=''
  [ -s "$queue" ] || return 0
  while IFS=$'\t' read -r _epoch _seq kind queue_key _payload; do
    [ "$kind" = signal ] || continue
    fm_wake_status_key_map "$queue_key" || continue
    [ "$FM_WAKE_STATUS_HISTORICAL" = false ] || continue
    status_key=$FM_WAKE_STATUS_KEY
    statusf="$state/$status_key"
    [ -f "$statusf" ] && [ ! -L "$statusf" ] || continue
    task=${status_key%.status}
    open=$(status_open_decisions "$statusf")
    while IFS=$'\t' read -r key verb note; do
      [ -n "$key" ] || continue
      case "$seen" in *"|$task:$key|"*) continue ;; esac
      seen="$seen|$task:$key|"
      printf '%s\t%s\t%s\t%s\n' "$task" "$key" "$verb" "$note"
    done <<EOF
$open
EOF
  done < "$queue"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<event-id>\t<event-line>" for every captain-relevant
# event represented by state/*.status. The whole-stream decision fold keeps an
# unresolved decision visible behind unrelated later events, while a verified
# resolution or captain-held transfer removes it before this scan. The current
# terminal event is retained as a separate row so a new terminal event is never
# hidden by an older unresolved decision.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f task open key verb note line_no event_id event_line open_ids
  local last_info last_no last
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open_ids=''
    open=$(status_open_decision_events "$f")
    while IFS=$'\t' read -r key verb note line_no; do
      [ -n "$key" ] || continue
      event_id="decision:${key}:${line_no}"
      if [ "$key" = default ]; then
        event_line="${verb}: ${note}"
      else
        event_line="${verb} [key=${key}]: ${note}"
      fi
      printf '%s\t%s\t%s\t%s\n' "$f" "$task" "$event_id" "$event_line"
      open_ids="${open_ids}|${event_id}|"
    done <<EOF
$open
EOF

    last_info=$(status_last_event_info "$f")
    [ -n "$last_info" ] || continue
    last_no=${last_info%%$'\t'*}
    last=${last_info#*$'\t'}
    status_is_captain_relevant "$last" || continue
    event_id=$(status_event_identity "$last_no" "$last")
    case "$open_ids" in
      *"|${event_id}|"*) : ;;
      *) printf '%s\t%s\t%s\t%s\n' "$f" "$task" "${event_id}" "$last" ;;
    esac
  done
  return 0
}
