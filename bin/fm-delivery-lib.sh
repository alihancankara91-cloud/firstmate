# shellcheck shell=bash
# fm-delivery-lib.sh - the delivery gate: fail-closed verification that a ship
# task's work is actually delivered on the remote before the task can be treated
# as done or depended on.
#
# Why this exists: four real incidents in two days where a task was "done" with
# a commit that never reached the merged PR, a branch with no PR raised, and -
# worst - a branch never pushed at all. A written rule was added after the third
# incident and the fourth happened anyway. A rule that depends on remembering
# does not hold; this gate blocks structurally instead.
#
# THE CONTRACT (owned here, referenced everywhere else):
#   A commit is not delivery. A pushed branch is not delivery. A green pipeline
#   is not delivery. For a ship task in a PR delivery mode, delivery means ONE
#   of these two evidence arms verifies against the REMOTE:
#
#   Arm R (remote default branch): the up-to-date fetched remote default branch
#     already contains the worktree's content (HEAD is an ancestor, or a 3-way
#     merge adds nothing - the same tree technique as bin/fm-teardown.sh's
#     content_in_default, restated here because the two contracts differ:
#     teardown's landed test protects work from destruction, this gate proves
#     delivery), AND every recorded expected deliverable path exists in that
#     fetched default tree. This arm covers the captain-authorized pr-less
#     merge flow on repos with no PR CI.
#
#   Arm P (raised pull request): a PR is resolvable for the task (recorded
#     pr= metadata, or discovered from the branch name), the PR is open or
#     merged (a closed-unmerged PR is not a delivery vehicle), the local HEAD
#     is contained in the PR head fetched from the forge (so a commit that
#     never reached the PR refuses), and the PR's OWN file list - read from
#     the forge via `gh pr diff --name-only`, never from the local branch, a
#     commit message, or a pipeline result - is non-empty, contains every
#     path the worktree's net diff produced, and contains every recorded
#     expected deliverable path.
#
#   FAIL CLOSED: any error - unreachable remote, gh failure, missing worktree
#   input, ambiguous state - fails that arm; both arms failing refuses. The
#   gate never passes because it could not check.
#
#   NOT SATISFIABLE BY ASSERTION: every check reads the remote, the forge, or
#   git object facts. No status line, report, or worker claim is consulted.
#
# Scope: kind=ship only. Scouts deliver a report, secondmates are not work
# items - both are not-applicable. mode=local-only tasks have no remote PR;
# for them the gate verifies only recorded expected deliverable paths against
# the local default branch tree (bin/fm-merge-local.sh and teardown's existing
# local-only refusal own the rest of that mode's rigor).
#
# Expected deliverable paths are recorded by FIRSTMATE (not the worker) as
# repeated `deliverable=<repo-relative-path>` lines in state/<id>.meta, via
# `bin/fm-delivery-gate.sh expect`. They are optional: without them the gate
# still enforces push + PR + file-list containment of the actual local diff;
# with them it additionally refuses when a promised path is absent from the
# PR file list (the "workflow that never reached the PR" incident).
#
# Override: the ONLY sanctioned exception path is a recorded override written
# by `bin/fm-delivery-gate.sh override <id> --reason <text>`, which creates
# state/<id>.delivery-override plus a durable data/<id>/delivery-override.md
# record. An active override passes the gate LOUDLY (every caller prints the
# override provenance); it is deliberate and visible, never silent.
#
# Durable evidence: a verify pass writes data/<id>/delivered.md (survives
# teardown, like a scout report). bin/fm-spawn.sh's --requires reads exactly
# that record - a dependent step cannot start on a predecessor that never
# cleared this gate.
#
# Enforcement points (each a hard refusal, not a warning):
#   - bin/fm-teardown.sh: a non-force ship teardown in a PR mode must pass this
#     gate before destructive cleanup, so completion can never be recorded for
#     undelivered work. Teardown's own unlanded-work refusal is untouched and
#     still runs first; this gate is strictly additive.
#   - bin/fm-spawn.sh --requires <task-id>: dispatch of a dependent step
#     refuses unless each named predecessor has durable delivery evidence.
#   - bin/fm-delivery-gate.sh verify: the same verification on demand, run by
#     firstmate when a worker reports done.
#
# Sourced by bin/fm-delivery-gate.sh, bin/fm-teardown.sh, bin/fm-spawn.sh, and
# tests. No side effects on source. set -u / set -e safe.
#
# On return from fm_delivery_verify:
#   FM_DELIVERY_RESULT   pass | override | not-applicable | refused
#   FM_DELIVERY_EVIDENCE newline-joined human-readable evidence lines (pass)
#   FM_DELIVERY_REASONS  newline-joined refusal reasons (refused)

# _fm_delivery_reset: clear result globals before a verification run.
_fm_delivery_reset() {
  FM_DELIVERY_RESULT=
  FM_DELIVERY_EVIDENCE=
  FM_DELIVERY_REASONS=
}

_fm_delivery_reason() {
  if [ -z "$FM_DELIVERY_REASONS" ]; then
    FM_DELIVERY_REASONS=$1
  else
    FM_DELIVERY_REASONS="$FM_DELIVERY_REASONS
$1"
  fi
}

_fm_delivery_evidence() {
  if [ -z "$FM_DELIVERY_EVIDENCE" ]; then
    FM_DELIVERY_EVIDENCE=$1
  else
    FM_DELIVERY_EVIDENCE="$FM_DELIVERY_EVIDENCE
$1"
  fi
}

# fm_delivery_meta_get <meta> <key>: last value for key= in a meta file, empty
# when absent. Local restatement so the CLI does not need bin/fm-backend.sh.
fm_delivery_meta_get() {
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_delivery_deliverables <meta>: print every recorded deliverable= path,
# one per line, de-duplicated, preserving first-seen order.
fm_delivery_deliverables() {
  local meta=$1
  [ -f "$meta" ] || return 0
  grep '^deliverable=' "$meta" 2>/dev/null | cut -d= -f2- | awk '!seen[$0]++' || true
}

# fm_delivery_path_valid <path>: a recordable expected deliverable path is
# repo-relative, non-empty, and free of traversal or option-like shapes.
fm_delivery_path_valid() {
  local p=${1-}
  case "$p" in
    ''|/*|-*|*..*) return 1 ;;
    *$'\n'*|*$'\t'*) return 1 ;;
  esac
  return 0
}

# _fm_delivery_default_branch <repo-dir>: the project's default branch name via
# origin/HEAD, falling back to main then master. Non-zero when undeterminable.
_fm_delivery_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# _fm_delivery_local_paths <wt> <default-ref>: the net repo-relative paths the
# worktree's work changed, relative to the merge-base with <default-ref>.
# Non-zero when the diff cannot be computed (fail closed at the caller).
_fm_delivery_local_paths() {
  local wt=$1 default_ref=$2 base
  base=$(git -C "$wt" merge-base "$default_ref" HEAD 2>/dev/null) || return 1
  [ -n "$base" ] || return 1
  git -C "$wt" diff --name-only "$base" HEAD -- 2>/dev/null
}

# _fm_delivery_pr_target <meta> <wt> <branch>: print the PR url or number to
# verify against - the recorded pr= first, else a forge lookup by branch name.
_fm_delivery_pr_target() {
  local meta=$1 wt=$2 branch=$3 url out n
  url=$(fm_delivery_meta_get "$meta" pr)
  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    return 0
  fi
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$(cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# _fm_delivery_pr_number <target>: the numeric PR id inside a url or number.
_fm_delivery_pr_number() {
  local target=$1 n
  case "$target" in
    '') return 1 ;;
    *"/pull/"*) n=${target##*/pull/}; n=${n%%[!0-9]*} ;;
    [0-9]*) n=${target%%[!0-9]*} ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# _fm_delivery_patch_id <wt> <commit>: the stable patch id of one commit.
_fm_delivery_patch_id() {
  git -C "$1" show --pretty=medium --no-ext-diff "$2" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# _fm_delivery_unpushed_patches_in_pr_head <wt> <pr-head>: every local commit
# not reachable from any remote is patch-equivalent to a commit in the PR head
# (the replayed/rebased no-mistakes flow). Mirrors bin/fm-teardown.sh's
# unpushed_patches_are_in_pr_head; the two contracts differ (landed vs
# delivered) so each states its own check. Non-zero on any doubt.
_fm_delivery_unpushed_patches_in_pr_head() {
  local wt=$1 pr_head=$2 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$wt" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$wt" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          _fm_delivery_patch_id "$wt" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(_fm_delivery_patch_id "$wt" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# _fm_delivery_head_contained <wt> <target> <pr-head>: does the PR head from
# the forge contain the worktree's HEAD? Fetches refs/pull/<n>/head when the
# object is absent locally (deleted-branch flow). Accepts direct ancestry, or
# patch equivalence of every not-on-a-remote local commit for the replayed
# no-mistakes flow. Non-zero on any doubt.
_fm_delivery_head_contained() {
  local wt=$1 target=$2 pr_head=$3 n current
  if ! git -C "$wt" cat-file -e "$pr_head^{commit}" 2>/dev/null; then
    n=$(_fm_delivery_pr_number "$target") || return 1
    git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
    git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
    git -C "$wt" cat-file -e "$pr_head^{commit}" 2>/dev/null || return 1
  fi
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$wt" merge-base --is-ancestor "$current" "$pr_head" 2>/dev/null && return 0
  _fm_delivery_unpushed_patches_in_pr_head "$wt" "$pr_head"
}

# _fm_delivery_arm_pr <meta> <wt> <branch> <deliverables>: Arm P. Verifies the
# raised PR and its forge-side file list. Appends refusal reasons and returns
# non-zero on any failure. On success appends evidence including the file list.
_fm_delivery_arm_pr() {
  local meta=$1 wt=$2 branch=$3 deliverables=$4
  local target view state pr_head files local_paths p base default missing
  target=$(_fm_delivery_pr_target "$meta" "$wt" "$branch") || {
    _fm_delivery_reason "no pull request found for the work (no pr= recorded and no PR matches branch '$branch' on the forge)"
    return 1
  }
  view=$(cd "$wt" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || {
    _fm_delivery_reason "could not read PR $target from the forge (network or auth failure counts as not delivered)"
    return 1
  }
  state=${view%%$'\t'*}
  pr_head=${view#*$'\t'}
  if [ "$state" = "$view" ] || [ -z "$pr_head" ]; then
    _fm_delivery_reason "forge answer for PR $target is incomplete (state/head unreadable)"
    return 1
  fi
  case "$state" in
    OPEN|open|MERGED|merged) ;;
    *)
      _fm_delivery_reason "PR $target is $state - a closed, unmerged PR is not a delivery vehicle"
      return 1 ;;
  esac
  if ! _fm_delivery_head_contained "$wt" "$target" "$pr_head"; then
    _fm_delivery_reason "local HEAD is not contained in PR $target's head $pr_head - a local commit never reached the PR"
    return 1
  fi
  files=$(cd "$wt" && gh pr diff "$target" --name-only 2>/dev/null) || {
    _fm_delivery_reason "could not read PR $target's own file list from the forge (gh pr diff --name-only failed)"
    return 1
  }
  if [ -z "$files" ]; then
    _fm_delivery_reason "PR $target's file list is empty - nothing is being delivered by that PR"
    return 1
  fi
  default=$(_fm_delivery_default_branch "$wt") || {
    _fm_delivery_reason "cannot determine the default branch to compute the work's changed paths"
    return 1
  }
  if git -C "$wt" rev-parse --quiet --verify "refs/remotes/origin/$default" >/dev/null 2>&1; then
    base="refs/remotes/origin/$default"
  else
    base="refs/heads/$default"
  fi
  local_paths=$(_fm_delivery_local_paths "$wt" "$base") || {
    _fm_delivery_reason "cannot compute the worktree's changed paths against $default"
    return 1
  }
  if [ -z "$local_paths" ] && [ -z "$deliverables" ]; then
    _fm_delivery_reason "the worktree's net diff against $default is empty and no expected deliverable paths are recorded - nothing verifiable is being delivered"
    return 1
  fi
  missing=
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$files" | grep -qxF "$p" || missing="$missing $p"
  done <<EOF
$local_paths
EOF
  if [ -n "$missing" ]; then
    _fm_delivery_reason "PR $target's file list is missing locally changed path(s):$missing"
    return 1
  fi
  missing=
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$files" | grep -qxF "$p" || missing="$missing $p"
  done <<EOF
$deliverables
EOF
  if [ -n "$missing" ]; then
    _fm_delivery_reason "PR $target's file list is missing expected deliverable path(s):$missing"
    return 1
  fi
  _fm_delivery_evidence "PR $target ($state, head $pr_head) contains local HEAD"
  _fm_delivery_evidence "PR file list (read from the forge):"
  _fm_delivery_evidence "$files"
  return 0
}

# _fm_delivery_arm_remote_default <wt> <deliverables>: Arm R. Fetches the
# remote default branch and verifies the worktree's content plus expected
# deliverable paths are contained in it. Appends reasons / evidence.
_fm_delivery_arm_remote_default() {
  local wt=$1 deliverables=$2
  local default ref default_tree merged_tree current p missing
  default=$(_fm_delivery_default_branch "$wt") || {
    _fm_delivery_reason "cannot determine the remote default branch"
    return 1
  }
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || {
    _fm_delivery_reason "no origin remote to verify the default branch against"
    return 1
  }
  git -C "$wt" fetch --quiet origin "+refs/heads/$default:refs/remotes/origin/$default" >/dev/null 2>&1 || {
    _fm_delivery_reason "cannot fetch origin/$default (unreachable remote counts as not delivered)"
    return 1
  }
  ref="refs/remotes/origin/$default"
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || {
    _fm_delivery_reason "cannot resolve the worktree's HEAD"
    return 1
  }
  if git -C "$wt" merge-base --is-ancestor "$current" "$ref" 2>/dev/null; then
    _fm_delivery_evidence "origin/$default contains local HEAD $current"
  else
    default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || {
      _fm_delivery_reason "cannot resolve origin/$default's tree"
      return 1
    }
    merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || {
      _fm_delivery_reason "cannot compare the worktree's content with origin/$default"
      return 1
    }
    merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
    if [ "$merged_tree" != "$default_tree" ]; then
      _fm_delivery_reason "origin/$default does not contain the worktree's content (work is not on the remote default branch)"
      return 1
    fi
    _fm_delivery_evidence "origin/$default already contains the worktree's full content (squash-equivalent)"
  fi
  missing=
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    git -C "$wt" cat-file -e "$ref:$p" 2>/dev/null || missing="$missing $p"
  done <<EOF
$deliverables
EOF
  if [ -n "$missing" ]; then
    _fm_delivery_reason "origin/$default is missing expected deliverable path(s):$missing"
    return 1
  fi
  [ -z "$deliverables" ] || _fm_delivery_evidence "expected deliverable paths present in origin/$default"
  return 0
}

# fm_delivery_override_active <state-dir> <id>: an intentional recorded
# override exists - an ordinary single-link file with a non-empty reason.
# Callers must also have sourced bin/fm-pr-lib.sh (fm_pr_file_link_count).
fm_delivery_override_active() {
  local state=$1 id=$2 f reason
  f="$state/$id.delivery-override"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(fm_pr_file_link_count "$f")" = 1 ] || return 1
  reason=$(fm_delivery_meta_get "$f" reason)
  [ -n "$reason" ] || return 1
  FM_DELIVERY_OVERRIDE_REASON=$reason
  return 0
}

# fm_delivery_verify <id> <state-dir> <data-dir>: run the gate for a task from
# its recorded metadata. Sets FM_DELIVERY_RESULT / _EVIDENCE / _REASONS per the
# header. Returns 0 for pass, override, or not-applicable; 1 for refused.
fm_delivery_verify() {
  local id=$1 state=$2 data=$3
  local meta kind mode wt branch deliverables
  _fm_delivery_reset
  meta="$state/$id.meta"
  if [ ! -f "$meta" ]; then
    FM_DELIVERY_RESULT=refused
    _fm_delivery_reason "no task metadata at $meta - cannot verify delivery (fail closed)"
    return 1
  fi
  kind=$(fm_delivery_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  mode=$(fm_delivery_meta_get "$meta" mode)
  [ -n "$mode" ] || mode=no-mistakes
  case "$kind" in
    scout|secondmate)
      FM_DELIVERY_RESULT=not-applicable
      _fm_delivery_evidence "kind=$kind is outside the delivery gate (a scout delivers a report, a secondmate is not a work item)"
      return 0 ;;
  esac
  if fm_delivery_override_active "$state" "$id"; then
    FM_DELIVERY_RESULT=override
    _fm_delivery_evidence "DELIVERY GATE OVERRIDDEN for $id: $FM_DELIVERY_OVERRIDE_REASON"
    _fm_delivery_evidence "override records: $state/$id.delivery-override and $data/$id/delivery-override.md"
    return 0
  fi
  wt=$(fm_delivery_meta_get "$meta" worktree)
  deliverables=$(fm_delivery_deliverables "$meta")
  if [ "$mode" = local-only ]; then
    _fm_delivery_local_only_verify "$id" "$wt" "$deliverables"
    return $?
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    FM_DELIVERY_RESULT=refused
    _fm_delivery_reason "task worktree '${wt:-<unrecorded>}' is not inspectable - cannot verify delivery (fail closed)"
    return 1
  fi
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if _fm_delivery_arm_remote_default "$wt" "$deliverables"; then
    FM_DELIVERY_RESULT=pass
    return 0
  fi
  if _fm_delivery_arm_pr "$meta" "$wt" "$branch" "$deliverables"; then
    FM_DELIVERY_RESULT=pass
    return 0
  fi
  FM_DELIVERY_RESULT=refused
  return 1
}

# _fm_delivery_local_only_verify <id> <wt> <deliverables>: local-only mode has
# no remote PR; the gate verifies only recorded expected deliverable paths
# against the local default branch tree. Everything else in that mode is owned
# by bin/fm-merge-local.sh and teardown's existing local-only refusal.
_fm_delivery_local_only_verify() {
  local id=$1 wt=$2 deliverables=$3 default p missing
  if [ -z "$deliverables" ]; then
    FM_DELIVERY_RESULT=not-applicable
    _fm_delivery_evidence "local-only task with no recorded expected deliverable paths - local merge rigor is owned by the local-only delivery path"
    return 0
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    FM_DELIVERY_RESULT=refused
    _fm_delivery_reason "task worktree '${wt:-<unrecorded>}' is not inspectable - cannot verify local-only deliverables (fail closed)"
    return 1
  fi
  default=$(_fm_delivery_default_branch "$wt") || {
    FM_DELIVERY_RESULT=refused
    _fm_delivery_reason "cannot determine the local default branch to verify deliverables against"
    return 1
  }
  missing=
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    git -C "$wt" cat-file -e "refs/heads/$default:$p" 2>/dev/null || missing="$missing $p"
  done <<EOF
$deliverables
EOF
  if [ -n "$missing" ]; then
    FM_DELIVERY_RESULT=refused
    _fm_delivery_reason "local $default is missing expected deliverable path(s):$missing - merge the approved branch first (bin/fm-merge-local.sh)"
    return 1
  fi
  FM_DELIVERY_RESULT=pass
  _fm_delivery_evidence "expected deliverable paths present in local $default"
  return 0
}

# fm_delivery_record <id> <data-dir>: write the durable delivery evidence at
# data/<id>/delivered.md from the current FM_DELIVERY_RESULT/_EVIDENCE. This is
# the record bin/fm-spawn.sh's --requires reads; only a gate pass or a recorded
# override ever writes it.
fm_delivery_record() {
  local id=$1 data=$2 dir
  case "$FM_DELIVERY_RESULT" in
    pass|override) ;;
    *) return 1 ;;
  esac
  dir="$data/$id"
  mkdir -p "$dir" || return 1
  {
    printf '# Delivery record: %s\n\n' "$id"
    printf -- '- verified: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- result: %s\n\n' "$FM_DELIVERY_RESULT"
    printf '%s\n' "$FM_DELIVERY_EVIDENCE"
  } > "$dir/delivered.md" || return 1
  return 0
}

# fm_delivery_required_evidence <data-dir> <required-id>: does durable evidence
# exist that <required-id> cleared the gate (delivered.md) or, for a finished
# scout, produced its report (report.md)? Read-only; used by fm-spawn --requires.
fm_delivery_required_evidence() {
  local data=$1 rid=$2
  if [ -f "$data/$rid/delivered.md" ] && [ ! -L "$data/$rid/delivered.md" ]; then
    return 0
  fi
  if [ -f "$data/$rid/report.md" ] && [ ! -L "$data/$rid/report.md" ]; then
    return 0
  fi
  return 1
}
