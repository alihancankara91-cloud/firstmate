#!/usr/bin/env bash
# Regression tests for cleanup endpoint identity validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)
REAL_TMUX=$(command -v tmux || true)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  dir=$(make_case unbound-recovery)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "worktree=" "project=$dir/project" "backend=orca" \
    "orca_recovery=worktree-only" "orca_worktree_id=worktree-recovery"
  assert_refused_without_mutation "$dir" "$id" "unbound Orca recovery"

  dir=$(make_case unmarked-current-recovery)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=" "project=$dir/project" \
    "backend=orca" "orca_worktree_id=worktree-recovery"
  assert_refused_without_mutation "$dir" "$id" "unmarked current Orca recovery"

  dir=$(make_case stripped-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "worktree=$dir/worktree" "project=$dir/project" "kind=scout" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  assert_refused_without_mutation "$dir" "$id" "binding-stripped opaque endpoint"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

test_legacy_worktree_provenance() {
  local dir id=legacy-proven proven_project proven_worktree orca_project orca_worktree
  dir=$(make_case legacy-provenance)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  proven_project="$dir/proven-project"
  proven_worktree="$dir/proven-worktree"
  fm_git_worktree "$proven_project" "$proven_worktree" "fm/$id"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:27" "worktree=$proven_worktree" "project=$proven_project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=23" "zellij_pane_id=27"
  fm_backend_legacy_worktree_matches "$dir/home/state/$id.meta" "$id" zellij \
    || fail "exact project-registered fm/<id> worktree provenance was rejected"
  ! fm_backend_legacy_worktree_matches "$dir/home/state/$id.meta" other-task zellij \
    || fail "another task id accepted the recorded legacy worktree branch"

  id=legacy-pathless-orca
  orca_project="$dir/orca-project"
  orca_worktree="$dir/orca-worktree"
  fm_git_worktree "$orca_project" "$orca_worktree" "fm-$id"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "terminal=legacy-terminal" "worktree=" "project=$orca_project" \
    "backend=orca" "orca_worktree_id=orca-worktree-id"
  fm_backend_worktree_path() {
    [ "$1:$2" = orca:orca-worktree-id ] || return 1
    printf '%s' "$orca_worktree"
  }
  fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" "$dir/home" "$ROOT" \
    || fail "pathless legacy Orca record did not resolve and migrate"
  assert_grep "worktree=$orca_worktree" "$dir/home/state/$id.meta" "pathless Orca migration did not persist its resolved worktree"
  assert_grep "endpoint_task_id=$id" "$dir/home/state/$id.meta" "pathless Orca migration omitted task binding"
  assert_grep "legacy_endpoint_cleanup=skip-terminal" "$dir/home/state/$id.meta" "pathless Orca migration did not suppress terminal cleanup"
  [ -z "$FM_BACKEND_VALIDATED_TARGET" ] || fail "pathless Orca migration retained a terminal cleanup target"

  id=legacy-pathless-crossed
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "worktree=" "project=$orca_project" \
    "backend=orca" "orca_worktree_id=orca-worktree-id"
  ! fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" "$dir/home" "$ROOT" 2>/dev/null \
    || fail "pathless Orca recovery accepted another task's native fm-<id> worktree"
  pass "legacy cleanup identity: exact registered worktrees authenticate recorded and pathless Orca cleanup"
}

test_secondmate_endpoint_ownership_uses_marked_home() {
  local dir id=secondmate-owner
  dir=$(make_case secondmate-endpoint-home)
  printf '%s\n' "$id" > "$dir/home/.fm-secondmate-home"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/home" "project=$dir/project" \
    "kind=secondmate" "home=$dir/home" "backend=herdr" \
    "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_task_endpoint_ownership "$dir/home/state/$id.meta" "$id" "$ROOT" "$ROOT" \
    || fail "marked secondmate endpoint ownership was not authenticated"
  [ "$FM_BACKEND_ENDPOINT_OWNING_HOME" = "$(cd "$dir/home" && pwd -P)" ] \
    || fail "secondmate endpoint ownership retained the primary home"
  [ "$FM_BACKEND_ENDPOINT_OWNING_ROOT" = "$(cd "$dir/home" && pwd -P)" ] \
    || fail "secondmate endpoint ownership retained the primary root"
  printf 'other-owner\n' > "$dir/home/.fm-secondmate-home"
  ! fm_backend_task_endpoint_ownership "$dir/home/state/$id.meta" "$id" "$ROOT" "$ROOT" \
    || fail "secondmate endpoint ownership accepted a crossed home marker"

  printf '%s\n' "$id" > "$dir/home/.fm-secondmate-home"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:7" "endpoint_task_id=$id" "worktree=$dir/home" "project=$dir/project" \
    "kind=secondmate" "home=$dir/home" "backend=zellij" \
    "zellij_session=firstmate" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_task_endpoint_ownership "$dir/home/state/$id.meta" "$id" "$ROOT" "$ROOT" \
    || fail "marked Zellij secondmate endpoint ownership was not authenticated"
  [ "$FM_BACKEND_ENDPOINT_OWNING_HOME" = "$(cd "$ROOT" && pwd -P)" ] \
    || fail "Zellij secondmate endpoint ownership left its state-owning parent home"
  [ "$FM_BACKEND_ENDPOINT_OWNING_ROOT" = "$(cd "$ROOT" && pwd -P)" ] \
    || fail "Zellij secondmate endpoint ownership left its state-owning parent root"
  assert_contains "$(<"$ROOT/bin/fm-teardown.sh")" "\$ENDPOINT_HOME\" \"\$ENDPOINT_ROOT" \
    "top-level teardown does not pass authenticated endpoint ownership to removal"
  pass "secondmate endpoint identity: Herdr uses the child home while Zellij remains parent-owned"
}

test_legacy_endpoint_status_uses_owning_home() {
  local dir id=home-bound
  dir=$(make_case owning-home)
  printf 'owner\n' > "$dir/home/.fm-secondmate-home"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-backend.sh"
    # shellcheck disable=SC2329
    fm_backend_source() { return 0; }
    # shellcheck disable=SC2329
    fm_backend_legacy_herdr_journal_status() { return 3; }
    # shellcheck disable=SC2329
    fm_backend_herdr_workspace_label() {
      [ "$(cd "$FM_HOME" && pwd -P)" = "$(cd "$dir/home" && pwd -P)" ] || return 1
      printf '2ndmate-owner'
    }
    # shellcheck disable=SC2329
    fm_backend_herdr_task_binding_status() {
      [ "$5" = 2ndmate-owner ] || return 1
      return 0
    }
    fm_backend_legacy_endpoint_status \
      "$dir/home/state/$id.meta" "$id" herdr lab:w1:p2 "$dir/home" "$dir/home"
  ) || fail "legacy Herdr endpoint proof did not use its explicit owning home"

  assert_grep "validate_task_endpoint_for_teardown \"\$child_meta\" \"\$child_id\" \"\$home\" \"\$home\"" \
    "$ROOT/bin/fm-teardown.sh" "recursive child validation does not thread the child home and root"
  pass "legacy endpoint identity: owning home is explicit for top-level and recursive cleanup"
}

test_supported_backend_endpoint_records_validate() {
  local dir id backend target
  dir=$(make_case valid-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tmux:firstmate:fm-$id" ] || fail "tmux endpoint validation returned wrong identity"

  id=tmux-spaced-session
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=team work:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint with a spaced session name refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "team work:fm-$id" ] || fail "tmux validation changed the spaced session identity"

  id=herdr-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"

  id=zellij-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Zellij endpoint refused"

  id=orca-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-7" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=orca" "orca_worktree_id=worktree-9"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Orca endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = term-7 ] || fail "Orca validation did not select its terminal"

  id=cmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-1:surface-2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-1" "cmux_surface_id=surface-2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid cmux endpoint refused"

  fm_backend_legacy_worktree_matches() {
    case "$2" in
      legacy-herdr|legacy-zellij|legacy-orca|legacy-orca-recovery|legacy-cmux|legacy-cmux-relaunch|legacy-crossed|legacy-dead-*)
        if [ "$2" = legacy-orca-recovery ]; then
          FM_BACKEND_LEGACY_RESOLVED_WORKTREE=$dir/worktree
        else
          FM_BACKEND_LEGACY_RESOLVED_WORKTREE=
        fi
        : "$FM_BACKEND_LEGACY_RESOLVED_WORKTREE"
        return 0
        ;;
      *) return 1 ;;
    esac
  }
  fm_backend_legacy_endpoint_status() {
    case "$2:$3" in
      legacy-herdr:herdr|legacy-zellij:zellij|legacy-cmux:cmux)
        return 0
        ;;
      legacy-cmux-relaunch:cmux)
        FM_BACKEND_LEGACY_RESOLVED_TARGET=workspace-new:surface-new
        : "$FM_BACKEND_LEGACY_RESOLVED_TARGET"
        return 0
        ;;
      legacy-dead-herdr:herdr|legacy-dead-zellij:zellij|legacy-dead-cmux:cmux)
        return 2
        ;;
      *) return 1 ;;
    esac
  }

  id=legacy-herdr
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p12" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t12" "herdr_pane_id=w1:p12"
  ! fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" 2>/dev/null || fail "unmigrated legacy Herdr endpoint passed current validation"
  fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "proven legacy Herdr endpoint did not migrate"
  assert_grep "endpoint_task_id=$id" "$dir/home/state/$id.meta" "legacy Herdr migration omitted task binding"

  id=legacy-zellij
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:17" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=13" "zellij_pane_id=17"
  ! fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" 2>/dev/null || fail "unmigrated legacy Zellij endpoint passed current validation"
  fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "proven legacy Zellij endpoint did not migrate"
  assert_grep "endpoint_task_id=$id" "$dir/home/state/$id.meta" "legacy Zellij migration omitted task binding"

  id=legacy-orca
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=orca" "orca_worktree_id=worktree-legacy"
  ! fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" 2>/dev/null || fail "unmigrated legacy Orca endpoint passed current validation"
  fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "proven legacy Orca worktree did not migrate"
  assert_grep "endpoint_task_id=$id" "$dir/home/state/$id.meta" "legacy Orca migration omitted task binding"
  assert_grep "legacy_endpoint_cleanup=skip-terminal" "$dir/home/state/$id.meta" "legacy Orca migration did not suppress unproven terminal cleanup"
  [ -z "$FM_BACKEND_VALIDATED_TARGET" ] || fail "legacy Orca migration retained an unproven terminal cleanup target"

  id=legacy-orca-recovery
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "worktree=" "project=$dir/project" \
    "backend=orca" "orca_worktree_id=worktree-legacy-recovery"
  fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" \
    || fail "proven pathless legacy Orca recovery did not migrate"
  assert_grep "worktree=$dir/worktree" "$dir/home/state/$id.meta" "pathless legacy Orca recovery did not persist its resolved worktree"
  assert_grep "endpoint_task_id=$id" "$dir/home/state/$id.meta" "pathless legacy Orca recovery omitted task binding"
  assert_grep "legacy_endpoint_cleanup=skip-terminal" "$dir/home/state/$id.meta" "pathless legacy Orca recovery retained terminal cleanup"

  id=legacy-cmux
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-11:surface-12" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-11" "cmux_surface_id=surface-12"
  ! fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" 2>/dev/null || fail "unmigrated legacy cmux endpoint passed current validation"
  fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "proven legacy cmux endpoint did not migrate"
  assert_grep "endpoint_task_id=$id" "$dir/home/state/$id.meta" "legacy cmux migration omitted task binding"

  id=legacy-cmux-relaunch
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-old:surface-old" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-old" "cmux_surface_id=surface-old"
  fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" \
    || fail "proven relaunched cmux endpoint did not migrate"
  assert_grep "window=workspace-new:surface-new" "$dir/home/state/$id.meta" "cmux migration retained its stale target"
  assert_grep "cmux_workspace_id=workspace-new" "$dir/home/state/$id.meta" "cmux migration retained its stale workspace"
  assert_grep "cmux_surface_id=surface-new" "$dir/home/state/$id.meta" "cmux migration retained its stale surface"

  for backend in herdr zellij cmux; do
    id=legacy-dead-$backend
    case "$backend" in
      herdr)
        fm_write_meta "$dir/home/state/$id.meta" \
          "window=lab:w1:p92" "worktree=$dir/worktree" "project=$dir/project" \
          "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t92" "herdr_pane_id=w1:p92"
        ;;
      zellij)
        fm_write_meta "$dir/home/state/$id.meta" \
          "window=lab:92" "worktree=$dir/worktree" "project=$dir/project" \
          "backend=zellij" "zellij_session=lab" "zellij_tab_id=91" "zellij_pane_id=92"
        ;;
      cmux)
        fm_write_meta "$dir/home/state/$id.meta" \
          "window=workspace-91:surface-92" "worktree=$dir/worktree" "project=$dir/project" \
          "backend=cmux" "cmux_workspace_id=workspace-91" "cmux_surface_id=surface-92"
        ;;
    esac
    fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" \
      || fail "authoritatively absent legacy $backend endpoint did not migrate"
    assert_grep "legacy_endpoint_cleanup=skip-endpoint" "$dir/home/state/$id.meta" "dead legacy $backend migration did not suppress endpoint cleanup"
    [ -z "$FM_BACKEND_VALIDATED_TARGET" ] || fail "dead legacy $backend migration retained a cleanup target"
    [ -z "$(fm_backend_target_of_meta "$dir/home/state/$id.meta")" ] || fail "dead legacy $backend metadata still resolved an endpoint target"
  done

  id=legacy-crossed
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:71" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=31" "zellij_pane_id=71"
  ! fm_backend_migrate_legacy_task_endpoint "$dir/home/state/$id.meta" "$id" 2>/dev/null \
    || fail "crossed legacy endpoint migrated without a matching live task label"
  assert_no_grep 'endpoint_task_id=' "$dir/home/state/$id.meta" "crossed legacy endpoint gained a binding"

  id=orca-recovery
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=" "project=$dir/project" \
    "backend=orca" "orca_recovery=worktree-only" "orca_worktree_id=worktree-recovery"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Orca worktree-only recovery refused"
  [ -z "$FM_BACKEND_VALIDATED_TARGET" ] || fail "Orca worktree-only recovery invented a terminal cleanup target"

  for backend in tmux herdr zellij orca cmux; do
    set +e
    fm_backend_kill "$backend" "" >/dev/null 2>&1
    target=$?
    set -e
    [ "$target" -ne 0 ] || fail "$backend generic kill accepted an empty target"
  done
  pass "cleanup identity: live task-bound and authoritatively absent legacy endpoints migrate while crossed records refuse"
}

test_tmux_empty_target_refuses_without_invocation() {
  local dir rc
  dir=$(make_case direct-empty)
  set +e
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct empty tmux target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "direct empty tmux target invoked tmux"
  pass "tmux backend: direct empty target returns nonzero without invoking tmux"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

isolated_tmux_window_exists() {  # <dir> <socket> <session> <window>
  ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "$3" -F '#{window_name}' 2>/dev/null ) \
    | grep -Fqx "$4"
}

test_isolated_tmux_invalid_and_valid_cleanup() {
  local dir socket socket_id session='endpoint safety' target_id=target control=control target=fm-target
  local prefix_target=fm-prefix prefix_survivor=fm-prefix2 rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case isolated-real)
  socket=dedicated.sock
  socket_id="$dir/$socket"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n "$control" )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "$session:" -n "$target" )
  printf '%s\n' "$socket_id" > "$dir/socket.identity"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -eu
[ -z "\${TMUX:-}" ] && [ -z "\${TMUX_PANE:-}" ] || exit 91
[ "\${FM_TEST_TMUX_SOCKET:-}" = '$socket_id' ] || exit 92
[ "\$(cat '$dir/socket.identity')" = '$socket_id' ] || exit 93
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
cd '$dir'
exec '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  fm_write_meta "$dir/home/state/invalid.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" invalid --force \
    > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated invalid endpoint unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated invalid endpoint reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "invalid cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "invalid cleanup removed target window"

  set +e
  # shellcheck disable=SC2016 # $1 expands inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/empty.out" 2> "$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated direct empty target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated direct empty target reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "direct empty cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "direct empty cleanup removed target window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "$prefix_survivor" )
  # shellcheck disable=SC2016 # $1 and $2 expand inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill "$2"' _ "$ROOT" "$session:$prefix_target"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$prefix_survivor" \
    || fail "missing exact target cleanup removed its prefix-matched neighbor"

  fm_write_meta "$dir/home/state/$target_id.meta" \
    "window=$session:$target" "endpoint_task_id=$target_id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$target_id" --force \
    > "$dir/valid.out" 2> "$dir/valid.err" \
    || fail "isolated valid endpoint teardown failed: $(cat "$dir/valid.err")"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" \
    && fail "valid cleanup did not remove the exact target window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" \
    || fail "valid cleanup removed the independent control window"
  grep -Fqx "tmux <kill-window> <-t> <=$session:=$target>" "$dir/runtime.log" \
    || fail "valid cleanup did not invoke exactly the recorded target: $(cat "$dir/runtime.log")"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: exact tmux cleanup preserves invalid and prefix-matched neighbors while removing only the recorded target"
}

test_invalid_endpoint_records_refuse_before_mutation
test_legacy_worktree_provenance
test_secondmate_endpoint_ownership_uses_marked_home
test_legacy_endpoint_status_uses_owning_home
test_supported_backend_endpoint_records_validate
test_tmux_empty_target_refuses_without_invocation
test_recorded_process_identity_cleanup_is_exact
test_isolated_tmux_invalid_and_valid_cleanup
