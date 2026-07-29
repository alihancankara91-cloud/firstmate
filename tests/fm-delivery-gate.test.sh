#!/usr/bin/env bash
# tests/fm-delivery-gate.test.sh - the delivery gate BLOCKS, it does not warn.
#
# The contract under test is bin/fm-delivery-lib.sh (verification arms,
# fail-closed rules, scope, override) enforced at bin/fm-teardown.sh (the
# done-half) and bin/fm-spawn.sh --requires (the dependent-step half), operated
# by bin/fm-delivery-gate.sh.
#
# The four historical failures each get a refusing scenario:
#   1. commit reported done but never reached the merged PR  -> refused
#      (PR file list / PR head containment)
#   2. expected deliverable path never in the PR file list   -> refused
#   3. branch pushed with no PR raised at all                -> refused
#   4. branch never pushed to the remote at all              -> refused
# Plus: the clean case passes without friction, a scout is unaffected, an
# unreachable remote refuses rather than passes (fail closed), the override is
# loud and recorded, and a dependent spawn refuses without durable evidence.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GATE="$ROOT/bin/fm-delivery-gate.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-gate-tests)

# Build a fresh sandbox for one case: state/, data/, config/, fakebin mocks,
# a bare origin with a main baseline, a project clone, and a task worktree on
# branch fm/task-x1. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # Default forge mocks: no PR exists anywhere and every view fails - the
  # "nothing was ever raised" baseline the gate must refuse on.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=$kind" \
    "mode=$mode" \
    "yolo=off"
}

wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

push_branch() {
  local case_dir=$1
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

append_pr_meta_url() {
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$1/state/task-x1.meta"
}

# Add a fork remote and push the worktree's task branch to it, then fetch into
# the project so the worktree sees the fork's remote-tracking ref. Simulates
# the legitimate local-only flow where work reaches a remote but never lands
# on the local default branch. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Serve PR 7 from the fake forge: view reports <state> and <head-sha>, and
# `pr diff --name-only` prints the case's pr-files.txt - the PR's OWN file
# list, decoupled from anything local so the tests can disagree with reality.
# <base> is the PR's own base branch as the forge reports it (default main);
# pass the empty string to make the baseRefName query FAIL, which is what drives
# the gate's repo-default fallback. Args: case_dir state head [base]
add_gh_pr() {
  local case_dir=$1 state=$2 head=$3 base=${4-main} base_case
  if [ -n "$base" ]; then
    base_case="      *\"baseRefName\"*) printf '%s\n' '$base' ; exit 0 ;;"
  else
    base_case="      *\"baseRefName\"*) echo 'error: field unavailable' >&2 ; exit 1 ;;"
  fi
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
$base_case
      *"state,headRefOid"*) printf '%s\t%s\n' '$state' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "pr diff")
    case " \$* " in
      *" --name-only "*) cat '$case_dir/pr-files.txt' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_gate() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$GATE" "$@"
}

run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

run_scout_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

run_spawn() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_PROJECTS_OVERRIDE="$case_dir/projects" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@"
}

# --- historical failure 4: branch never pushed to the remote ----------------

test_verify_refuses_commit_without_push() {
  local case_dir rc
  case_dir=$(make_case commit-no-push)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" notice-send.yml "send capability"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "commit-no-push: verify must refuse a commit that never left the machine"
  grep -q 'REFUSED' "$case_dir/stderr" || fail "commit-no-push: no REFUSED line"
  grep -q 'A commit is not delivery' "$case_dir/stderr" || fail "commit-no-push: missing the core message"
  assert_absent "$case_dir/data/task-x1/delivered.md" "commit-no-push: refused task must not gain delivery evidence"
  pass "verify refuses a committed-but-never-pushed task (historical failure 4)"
}

# --- historical failure 3: pushed branch, no PR raised ----------------------

test_verify_refuses_pushed_branch_without_pr() {
  local case_dir rc
  case_dir=$(make_case pushed-no-pr)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" notice-send.yml "send capability"
  push_branch "$case_dir"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pushed-no-pr: verify must refuse a pushed branch with no PR"
  grep -q 'no pull request found' "$case_dir/stderr" || fail "pushed-no-pr: refusal must name the missing PR"
  assert_absent "$case_dir/data/task-x1/delivered.md" "pushed-no-pr: refused task must not gain delivery evidence"
  pass "verify refuses a pushed branch with no PR raised (historical failure 3)"
}

# --- historical failure 1: work never reached the PR that merged ------------

test_verify_refuses_pr_whose_file_list_lacks_the_work() {
  local case_dir rc head
  case_dir=$(make_case pr-missing-file)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" reconstruction.yml "the workflow"
  push_branch "$case_dir"
  append_pr_meta_url "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' "unrelated.txt" > "$case_dir/pr-files.txt"
  add_gh_pr "$case_dir" MERGED "$head"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-missing-file: verify must refuse when the PR's own file list lacks the work"
  grep -q 'missing locally changed path' "$case_dir/stderr" || fail "pr-missing-file: refusal must name the missing path check"
  grep -q 'reconstruction.yml' "$case_dir/stderr" || fail "pr-missing-file: refusal must name the path itself"
  pass "verify refuses a PR whose file list lacks the produced path (historical failure 1)"
}

# --- historical failure 2: promised deliverable never in the PR -------------

test_verify_refuses_missing_expected_deliverable() {
  local case_dir rc head
  case_dir=$(make_case missing-deliverable)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" helper.txt "support file"
  push_branch "$case_dir"
  append_pr_meta_url "$case_dir"
  run_gate "$case_dir" expect task-x1 .github/workflows/grant-points.yml >/dev/null
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' "helper.txt" > "$case_dir/pr-files.txt"
  add_gh_pr "$case_dir" OPEN "$head"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-deliverable: verify must refuse when a promised path is absent from the PR file list"
  grep -q 'missing expected deliverable' "$case_dir/stderr" || fail "missing-deliverable: refusal must name the expectation check"
  grep -q 'grant-points.yml' "$case_dir/stderr" || fail "missing-deliverable: refusal must name the promised path"
  pass "verify refuses when a recorded expected deliverable never reached the PR (historical failure 2)"
}

# --- the clean case passes without friction ---------------------------------

test_verify_passes_verified_pr_and_records_evidence() {
  local case_dir rc head
  case_dir=$(make_case clean-pass)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt "the change"
  push_branch "$case_dir"
  append_pr_meta_url "$case_dir"
  run_gate "$case_dir" expect task-x1 feature.txt >/dev/null
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' "feature.txt" > "$case_dir/pr-files.txt"
  add_gh_pr "$case_dir" OPEN "$head"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "clean-pass: verify must pass a raised PR whose file list contains the work"
  grep -q 'PASS' "$case_dir/stdout" || fail "clean-pass: no PASS line"
  assert_present "$case_dir/data/task-x1/delivered.md" "clean-pass: durable delivery evidence must be recorded"
  assert_grep 'feature.txt' "$case_dir/data/task-x1/delivered.md" "clean-pass: evidence must include the verified file list"
  pass "verify passes the clean case and records durable evidence"
}

# --- a stacked PR is judged against its OWN base, not the repo default ------

# Serve <branch> from origin with <file>=<content> committed on top of the
# origin baseline, make its objects available in the project, and then rewind
# the project's remote-tracking ref for it to the baseline. Origin really holds
# the branch, but every local view of it is STALE, so only a fresh fetch can
# find the true branch point. Args: case_dir branch file content
add_origin_branch_with_stale_tracking_ref() {
  local case_dir=$1 branch=$2 file=$3 content=$4 tmp baseline
  baseline=$(git -C "$case_dir/project" rev-parse refs/remotes/origin/main)
  tmp="$case_dir/_base"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add $file"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q origin "$branch"
  git -C "$case_dir/project" rev-parse FETCH_HEAD > "$case_dir/base-head"
  git -C "$case_dir/project" update-ref "refs/remotes/origin/$branch" "$baseline"
}

test_verify_passes_stacked_pr_against_its_own_base() {
  local case_dir rc head
  case_dir=$(make_case stacked-pr)
  write_meta "$case_dir" no-mistakes ship
  # PR 7's base is feature-base, not main. base.txt is inherited from that base
  # and belongs to the OTHER PR, so PR 7's own file list legitimately omits it.
  # The local view of feature-base is stale (rewound to the baseline): judged
  # against it, base.txt would look like this PR's own work and be demanded of
  # its file list. Only the freshly fetched base gives the true branch point.
  add_origin_branch_with_stale_tracking_ref "$case_dir" feature-base base.txt inherited
  git -C "$case_dir/wt" reset --hard -q "$(cat "$case_dir/base-head")"
  wt_commit_file "$case_dir" stacked.txt "the stacked change"
  append_pr_meta_url "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' "stacked.txt" > "$case_dir/pr-files.txt"
  add_gh_pr "$case_dir" OPEN "$head" feature-base

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stacked-pr: a PR based on a feature branch must be judged against that base"
  grep -q 'PASS' "$case_dir/stdout" || fail "stacked-pr: no PASS line"
  assert_not_contains "$(cat "$case_dir/stderr")" 'base.txt' \
    "stacked-pr: an inherited path must never be demanded of this PR's file list"
  assert_present "$case_dir/data/task-x1/delivered.md" "stacked-pr: durable evidence must be recorded"
  pass "a stacked PR passes against a freshly fetched view of its own baseRefName"
}

test_verify_fails_closed_when_pr_base_cannot_be_fetched() {
  local case_dir rc head
  case_dir=$(make_case stacked-pr-base-unfetchable)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt "the change"
  push_branch "$case_dir"
  append_pr_meta_url "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' "feature.txt" > "$case_dir/pr-files.txt"
  # The forge names a base branch origin does not serve. A same-named local
  # branch exists and would resolve if the gate were willing to look locally -
  # it must not be, and the unfetchable base must fail the arm closed.
  git -C "$case_dir/project" branch -q --no-track gone-base refs/remotes/origin/main
  add_gh_pr "$case_dir" MERGED "$head" gone-base

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stacked-pr-base-unfetchable: an unfetchable PR base must refuse"
  grep -q "cannot fetch origin/gone-base" "$case_dir/stderr" \
    || fail "stacked-pr-base-unfetchable: refusal must name the base branch it could not fetch"
  assert_absent "$case_dir/data/task-x1/delivered.md" \
    "stacked-pr-base-unfetchable: nothing verified means no evidence"
  pass "a PR base that origin does not serve fails closed instead of using a local branch"
}

test_verify_fails_closed_when_pr_base_and_repo_default_unreadable() {
  local case_dir rc head
  case_dir=$(make_case stacked-pr-no-base)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt "the change"
  append_pr_meta_url "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' "feature.txt" > "$case_dir/pr-files.txt"
  # The forge will not answer baseRefName, and the repo default is
  # undeterminable too: no origin/HEAD and no local main/master to fall back to.
  add_gh_pr "$case_dir" MERGED "$head" ""
  git -C "$case_dir/project" checkout --detach -q
  git -C "$case_dir/project" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
  git -C "$case_dir/project" branch -D main -q
  ! git -C "$case_dir/project" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 \
    || fail "stacked-pr-no-base: test setup bug, origin/HEAD still resolves a default branch"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stacked-pr-no-base: an unreadable base with no fallback must refuse"
  grep -q 'cannot read PR .* base branch from the forge' "$case_dir/stderr" \
    || fail "stacked-pr-no-base: refusal must name the unreadable base"
  assert_absent "$case_dir/data/task-x1/delivered.md" \
    "stacked-pr-no-base: nothing verified means no evidence"
  pass "an unreadable PR base with no determinable repo default fails closed"
}

# --- one view of the remote: a stale local ref cannot change the verdict -----

test_verify_judges_emptiness_against_the_freshly_fetched_default_ref() {
  local case_dir rc baseline
  case_dir=$(make_case stale-origin-ref)
  write_meta "$case_dir" no-mistakes ship
  baseline=$(git -C "$case_dir/project" rev-parse refs/remotes/origin/main)
  wt_commit_file "$case_dir" feature.txt "the change"
  # The work is fast-forwarded onto the remote default branch, then the local
  # remote-tracking ref is rewound so it no longer shows that. Judged against
  # the stale ref the net diff looks non-empty; judged against the ref the
  # containment proof actually fetches it is empty. Only one of those may
  # decide the outcome, and it must be the fetched one.
  git -C "$case_dir/wt" push -q origin HEAD:main
  git -C "$case_dir/project" update-ref refs/remotes/origin/main "$baseline"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-origin-ref: a contentless-looking verdict is not a refusal"
  grep -q 'NOT APPLICABLE' "$case_dir/stdout" \
    || fail "stale-origin-ref: the fetched ref must decide, not the stale one"
  grep -q 'fm-delivery-gate.sh expect' "$case_dir/stdout" \
    || fail "stale-origin-ref: the not-applicable output must name the resolutions"
  assert_absent "$case_dir/data/task-x1/delivered.md" \
    "stale-origin-ref: ref staleness must never decide whether evidence is recorded"
  pass "emptiness and containment are both judged against the one freshly fetched ref"
}

# --- fail closed: unreachable remote refuses, never passes ------------------

test_verify_refuses_unreachable_remote() {
  local case_dir rc
  case_dir=$(make_case unreachable-remote)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt "the change"
  push_branch "$case_dir"
  append_pr_meta_url "$case_dir"
  # The remote disappears and the forge errors: the gate must refuse, not pass.
  git -C "$case_dir/project" remote set-url origin "$case_dir/gone.git"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreachable-remote: verify must refuse when it cannot check (fail closed)"
  grep -q 'REFUSED' "$case_dir/stderr" || fail "unreachable-remote: no REFUSED line"
  grep -q 'cannot fetch origin/main' "$case_dir/stderr" \
    || fail "unreachable-remote: the fetch failure itself must be reported, not swallowed"
  assert_absent "$case_dir/data/task-x1/delivered.md" "unreachable-remote: no evidence may appear when nothing was verified"
  pass "verify refuses when the remote is unreachable (fail closed, no false confidence)"
}

# --- scope: a scout has no PR and is not blocked ----------------------------

test_verify_scout_not_applicable() {
  local case_dir rc
  case_dir=$(make_case scout-exempt)
  write_meta "$case_dir" no-mistakes scout

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-exempt: a scout must not be blocked by the delivery gate"
  grep -q 'NOT APPLICABLE' "$case_dir/stdout" || fail "scout-exempt: missing the not-applicable marker"
  pass "a scout task is outside the delivery gate"
}

# --- the override is deliberate, loud, and recorded -------------------------

test_override_is_loud_and_recorded() {
  local case_dir rc
  case_dir=$(make_case override)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt "the change"

  run_gate "$case_dir" override task-x1 --reason "captain authorized: repo has no remote yet" > "$case_dir/override-out"
  grep -q 'DELIVERY GATE OVERRIDE RECORDED' "$case_dir/override-out" || fail "override: recording must announce itself"
  assert_present "$case_dir/data/task-x1/delivery-override.md" "override: durable override record must exist"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "override: verify must pass an overridden task"
  grep -q 'OVERRIDE' "$case_dir/stdout" || fail "override: the pass must be loud about the override"
  grep -q 'captain authorized' "$case_dir/stdout" || fail "override: the pass must repeat the recorded reason"
  pass "the override passes loudly with durable records, never silently"
}

test_override_requires_a_reason() {
  local case_dir rc
  case_dir=$(make_case override-no-reason)
  write_meta "$case_dir" no-mistakes ship
  set +e
  run_gate "$case_dir" override task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "override-no-reason: an override without a reason must be rejected"
  pass "an override without a reason is rejected"
}

# --- enforcement: teardown blocks, it does not warn -------------------------

test_teardown_refuses_pushed_branch_without_pr() {
  local case_dir rc
  case_dir=$(make_case teardown-blocks)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" notice-send.yml "send capability"
  push_branch "$case_dir"
  # Today's landed test alone would allow this (HEAD reachable from origin);
  # the delivery gate must still refuse: pushed is not delivered.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "teardown-blocks: teardown must refuse an undelivered ship task"
  grep -q 'has not cleared the delivery gate' "$case_dir/stderr" || fail "teardown-blocks: refusal must name the delivery gate"
  assert_present "$case_dir/wt" "teardown-blocks: the worktree must be preserved"
  assert_present "$case_dir/state/task-x1.meta" "teardown-blocks: task state must be preserved"
  assert_absent "$case_dir/data/task-x1/delivered.md" "teardown-blocks: no delivery evidence may be fabricated"
  pass "teardown refuses completion for a pushed branch with no PR (the gate blocks)"
}

test_teardown_passes_verified_pr_and_records_evidence() {
  local case_dir rc head
  case_dir=$(make_case teardown-clean)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt "the change"
  push_branch "$case_dir"
  append_pr_meta_url "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' "feature.txt" > "$case_dir/pr-files.txt"
  add_gh_pr "$case_dir" MERGED "$head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "teardown-clean: a delivered task must tear down without friction"
  assert_present "$case_dir/data/task-x1/delivered.md" "teardown-clean: teardown must record durable delivery evidence"
  assert_absent "$case_dir/state/task-x1.meta" "teardown-clean: task state must be cleaned up"
  pass "teardown proceeds for a verified PR and records durable delivery evidence"
}

# --- enforcement: a dependent step cannot start on an unverified predecessor -

test_spawn_requires_refuses_without_evidence() {
  local case_dir rc
  case_dir=$(make_case requires-refuses)
  mkdir -p "$case_dir/projects"

  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/project" --requires task-x1 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "requires-refuses: dependent spawn must refuse without delivery evidence"
  grep -q 'has not cleared the delivery gate' "$case_dir/stderr" || fail "requires-refuses: refusal must name the gate"
  assert_absent "$case_dir/state/task-y2.meta" "requires-refuses: no task state may be created"
  pass "a dependent spawn refuses while the predecessor has no delivery evidence"
}

test_spawn_requires_accepts_delivered_predecessor() {
  local case_dir rc
  case_dir=$(make_case requires-accepts)
  mkdir -p "$case_dir/projects" "$case_dir/data/task-x1"
  printf '# Delivery record: task-x1\n' > "$case_dir/data/task-x1/delivered.md"

  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/nonexistent-project" --requires task-x1 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # The spawn proceeds past the gate and fails later for an unrelated reason
  # (the project dir does not exist) - what matters is the gate let it through.
  assert_not_contains "$(cat "$case_dir/stderr")" 'has not cleared the delivery gate' \
    "requires-accepts: delivered predecessor must pass the gate"
  [ "$rc" -ne 0 ] || fail "requires-accepts: setup error - spawn unexpectedly succeeded"
  pass "a dependent spawn passes the gate once durable delivery evidence exists"
}

test_spawn_requires_refuses_bare_scout_report() {
  local case_dir rc
  case_dir=$(make_case requires-scout)
  mkdir -p "$case_dir/projects" "$case_dir/data/scout-z9"
  # A report file only proves a worker wrote a file. Firstmate's scout gates
  # (report check + unresolved-decision completion gate) are what produce
  # delivered.md, and only that record satisfies a dependency.
  printf '# findings\n' > "$case_dir/data/scout-z9/report.md"

  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/project" --requires scout-z9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "requires-scout: a bare scout report must not satisfy a dependency"
  grep -q 'has not cleared the delivery gate' "$case_dir/stderr" \
    || fail "requires-scout: refusal must name the delivery gate"
  assert_absent "$case_dir/state/task-y2.meta" "requires-scout: no task state may be created"
  pass "a dependent spawn refuses on a bare scout report with no gate-written evidence"
}

# A scout that cleared BOTH of its teardown gates earns the same durable
# evidence a ship task earns from the delivery gate.
test_scout_teardown_records_delivery_and_unblocks_requires() {
  local case_dir rc
  if ! command -v tasks-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip: tasks-axi/jq not found (scout delivery evidence case)"
    return 0
  fi
  case_dir=$(make_case scout-delivers)
  cp "$ROOT/.tasks.toml" "$case_dir/.tasks.toml"
  cat > "$case_dir/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off" \
    "decisions_reviewed=1"
  mkdir -p "$case_dir/data/task-x1"
  printf '# findings\n' > "$case_dir/data/task-x1/report.md"

  set +e
  run_scout_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-delivers: a scout that cleared both gates must tear down"
  assert_present "$case_dir/data/task-x1/delivered.md" \
    "scout-delivers: teardown must record durable delivery evidence once both scout gates pass"
  assert_grep 'unresolved-decision completion gate' "$case_dir/data/task-x1/delivered.md" \
    "scout-delivers: the evidence must name the gates it rests on"

  mkdir -p "$case_dir/projects"
  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/nonexistent-project" --requires task-x1 \
    > "$case_dir/spawn-stdout" 2> "$case_dir/spawn-stderr"
  rc=$?
  set -e
  assert_not_contains "$(cat "$case_dir/spawn-stderr")" 'has not cleared the delivery gate' \
    "scout-delivers: a subsequent --requires must pass the gate"
  [ "$rc" -ne 0 ] || fail "scout-delivers: setup error - spawn unexpectedly succeeded"
  pass "scout teardown records delivery evidence after both gates and unblocks --requires"
}

# --- nothing produced is not delivery ---------------------------------------

test_empty_net_work_tears_down_without_minting_evidence() {
  local case_dir rc
  case_dir=$(make_case empty-net-work)
  write_meta "$case_dir" no-mistakes ship
  # A worktree that produced nothing: no commits, no diff against the default
  # branch, no recorded expectations. There is nothing to verify, so teardown
  # may clear the debris - but it must not mint delivery evidence for it.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-net-work: a contentless worktree is debris, not a refusal"
  ! grep -q REFUSED "$case_dir/stderr" || fail "empty-net-work: teardown printed a REFUSED line"
  grep -q 'nothing was produced to deliver' "$case_dir/stdout" \
    || fail "empty-net-work: teardown must say why no evidence was recorded"
  grep -q 'fm-delivery-gate.sh expect' "$case_dir/stdout" \
    || fail "empty-net-work: the not-applicable output must name the resolutions"
  assert_absent "$case_dir/data/task-x1/delivered.md" \
    "empty-net-work: a task that produced nothing must not gain delivery evidence"

  mkdir -p "$case_dir/projects"
  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/project" --requires task-x1 \
    > "$case_dir/spawn-stdout" 2> "$case_dir/spawn-stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "empty-net-work: a dependent spawn must still refuse"
  grep -q 'has not cleared the delivery gate' "$case_dir/spawn-stderr" \
    || fail "empty-net-work: refusal must name the delivery gate"
  grep -q 'fm-delivery-gate.sh expect' "$case_dir/spawn-stderr" \
    || fail "empty-net-work: the spawn refusal must name the resolutions"
  pass "an empty-net-work task tears down, records no evidence, and keeps --requires refusing"
}

# --- local-only mode with no recorded deliverables: containment is proved,
# never assumed from teardown being reached -----------------------------------

test_local_only_verify_records_delivery_when_local_main_contains_the_work() {
  local case_dir rc wt_head merged_head
  case_dir=$(make_case local-only-main-contained)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt "the change"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  # bin/fm-merge-local.sh landed the branch on local main as its own commit:
  # main carries the worktree's exact tree under a different sha, so HEAD is not
  # an ancestor and containment has to be proved by tree equality against the
  # same local main ref the emptiness question uses. The worktree shares the
  # project's object db and refs, so refs/heads/main is visible from wt too.
  merged_head=$(printf 'merge %s\n' "$wt_head" \
    | git -C "$case_dir/project" commit-tree "$wt_head^{tree}" -p refs/heads/main)
  git -C "$case_dir/project" update-ref refs/heads/main "$merged_head"

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "local-only-main-contained: verify must pass when local main contains the work"
  grep -q 'PASS' "$case_dir/stdout" || fail "local-only-main-contained: no PASS line"
  assert_present "$case_dir/data/task-x1/delivered.md" "local-only-main-contained: proven containment must record durable delivery evidence"
  assert_grep 'work contained in local main' "$case_dir/data/task-x1/delivered.md" \
    "local-only-main-contained: evidence must name the observed local containment"

  mkdir -p "$case_dir/projects"
  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/nonexistent-project" --requires task-x1 \
    > "$case_dir/spawn-stdout" 2> "$case_dir/spawn-stderr"
  rc=$?
  set -e
  assert_not_contains "$(cat "$case_dir/spawn-stderr")" 'has not cleared the delivery gate' \
    "local-only-main-contained: a subsequent --requires must pass the gate"
  [ "$rc" -ne 0 ] || fail "local-only-main-contained: setup error - spawn unexpectedly succeeded"
  pass "local-only verify records delivery from proven local containment and unblocks --requires"
}

# The accepted consequence of judging emptiness against the same ref the
# containment proof uses: a fast-forwarded local main is byte-identical to a
# worktree that produced nothing, so nothing is recorded and the resolutions are
# named. The companion test below shows the named resolution actually working.
test_local_only_fast_forwarded_main_records_no_delivery_without_expectations() {
  local case_dir rc wt_head
  case_dir=$(make_case local-only-fast-forward)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt "the change"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "local-only-fast-forward: teardown should still proceed"
  ! grep -q REFUSED "$case_dir/stderr" || fail "local-only-fast-forward: teardown printed a REFUSED line"
  grep -q 'nothing was produced to deliver' "$case_dir/stdout" \
    || fail "local-only-fast-forward: teardown must say why no evidence was recorded"
  grep -q 'fm-delivery-gate.sh expect' "$case_dir/stdout" \
    || fail "local-only-fast-forward: the not-applicable output must name the resolutions"
  assert_absent "$case_dir/data/task-x1/delivered.md" \
    "local-only-fast-forward: an empty net diff against local main records nothing"

  mkdir -p "$case_dir/projects"
  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/project" --requires task-x1 \
    > "$case_dir/spawn-stdout" 2> "$case_dir/spawn-stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "local-only-fast-forward: a dependent spawn must still refuse"
  grep -q 'has not cleared the delivery gate' "$case_dir/spawn-stderr" \
    || fail "local-only-fast-forward: refusal must name the delivery gate"
  pass "a fast-forwarded local-only branch with nothing recorded records no evidence"
}

test_local_only_fast_forwarded_main_passes_with_recorded_expectations() {
  local case_dir rc wt_head
  case_dir=$(make_case local-only-fast-forward-expected)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt "the change"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  # The named resolution: firstmate records what this task was supposed to
  # produce, which is then verified against that very same local main ref.
  run_gate "$case_dir" expect task-x1 feature.txt >/dev/null

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "local-only-fast-forward-expected: teardown should succeed"
  ! grep -q REFUSED "$case_dir/stderr" || fail "local-only-fast-forward-expected: teardown printed a REFUSED line"
  assert_present "$case_dir/data/task-x1/delivered.md" \
    "local-only-fast-forward-expected: recorded expectations must make the landed work verifiable"

  mkdir -p "$case_dir/projects"
  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/nonexistent-project" --requires task-x1 \
    > "$case_dir/spawn-stdout" 2> "$case_dir/spawn-stderr"
  rc=$?
  set -e
  assert_not_contains "$(cat "$case_dir/spawn-stderr")" 'has not cleared the delivery gate' \
    "local-only-fast-forward-expected: a subsequent --requires must pass the gate"
  [ "$rc" -ne 0 ] || fail "local-only-fast-forward-expected: setup error - spawn unexpectedly succeeded"
  pass "recording expected deliverable paths clears a fast-forwarded local-only task"
}

test_local_only_teardown_records_no_delivery_when_fork_remote_not_contained_locally() {
  local case_dir rc
  case_dir=$(make_case local-only-fork-not-contained)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt "the change"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "local-only-fork-not-contained: teardown should still succeed when HEAD is on a fork remote (unchanged behavior)"
  ! grep -q REFUSED "$case_dir/stderr" || fail "local-only-fork-not-contained: teardown printed a REFUSED line"
  assert_absent "$case_dir/data/task-x1/delivered.md" \
    "local-only-fork-not-contained: no delivery evidence may be written without proven local containment"

  mkdir -p "$case_dir/projects"
  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/project" --requires task-x1 \
    > "$case_dir/spawn-stdout" 2> "$case_dir/spawn-stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "local-only-fork-not-contained: a subsequent --requires must still refuse"
  grep -q 'has not cleared the delivery gate' "$case_dir/spawn-stderr" \
    || fail "local-only-fork-not-contained: refusal must name the delivery gate"
  pass "local-only teardown with unmerged fork-remote work records no delivery evidence and --requires keeps refusing"
}

# Recording expectations may only make the gate stricter. A deliverable path
# that already exists in the local default branch says nothing about THIS task.
test_local_only_deliverable_present_but_work_not_contained_refuses() {
  local case_dir rc
  case_dir=$(make_case local-only-deliverable-not-contained)
  write_meta "$case_dir" local-only ship
  # The promised path is already tracked on local main before the task starts.
  printf '%s\n' "baseline" > "$case_dir/project/tracked.txt"
  git -C "$case_dir/project" add -- tracked.txt
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -q -m "pre-existing tracked file"
  # The task edits it and pushes to a fork - never merged into local main.
  wt_commit_file "$case_dir" tracked.txt "the change"
  add_fork_with_pushed_branch "$case_dir"
  run_gate "$case_dir" expect task-x1 tracked.txt >/dev/null

  set +e
  run_gate "$case_dir" verify task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "local-only-deliverable-not-contained: an existing path must not stand in for the work"
  grep -q 'NOT contained in that branch' "$case_dir/stderr" \
    || fail "local-only-deliverable-not-contained: refusal must name the missing containment proof"
  grep -q 'fm-delivery-gate.sh override' "$case_dir/stderr" \
    || fail "local-only-deliverable-not-contained: refusal must name the resolutions"
  assert_absent "$case_dir/data/task-x1/delivered.md" \
    "local-only-deliverable-not-contained: no delivery evidence may be recorded"
  pass "local-only recorded deliverables never substitute for the containment proof"
}

test_spawn_requires_rejects_invalid_id() {
  local case_dir rc
  case_dir=$(make_case requires-invalid)
  mkdir -p "$case_dir/projects"

  set +e
  run_spawn "$case_dir" task-y2 "$case_dir/project" --requires '../escape' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "requires-invalid: a traversal id must be rejected"
  grep -q 'invalid task id' "$case_dir/stderr" || fail "requires-invalid: refusal must name the invalid id"
  pass "--requires rejects a path-unsafe task id"
}

test_verify_refuses_commit_without_push
test_verify_refuses_pushed_branch_without_pr
test_verify_refuses_pr_whose_file_list_lacks_the_work
test_verify_refuses_missing_expected_deliverable
test_verify_passes_verified_pr_and_records_evidence
test_verify_passes_stacked_pr_against_its_own_base
test_verify_fails_closed_when_pr_base_cannot_be_fetched
test_verify_fails_closed_when_pr_base_and_repo_default_unreadable
test_verify_judges_emptiness_against_the_freshly_fetched_default_ref
test_verify_refuses_unreachable_remote
test_verify_scout_not_applicable
test_override_is_loud_and_recorded
test_override_requires_a_reason
test_teardown_refuses_pushed_branch_without_pr
test_teardown_passes_verified_pr_and_records_evidence
test_spawn_requires_refuses_without_evidence
test_spawn_requires_accepts_delivered_predecessor
test_spawn_requires_refuses_bare_scout_report
test_scout_teardown_records_delivery_and_unblocks_requires
test_empty_net_work_tears_down_without_minting_evidence
test_spawn_requires_rejects_invalid_id
test_local_only_verify_records_delivery_when_local_main_contains_the_work
test_local_only_fast_forwarded_main_records_no_delivery_without_expectations
test_local_only_fast_forwarded_main_passes_with_recorded_expectations
test_local_only_teardown_records_no_delivery_when_fork_remote_not_contained_locally
test_local_only_deliverable_present_but_work_not_contained_refuses

echo "all fm-delivery-gate tests passed"
