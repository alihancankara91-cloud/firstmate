#!/usr/bin/env bash
# Contract tests for the external Codex cage wrapper and Seatbelt profile.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAGE="$ROOT/bin/fm-codex-cage.sh"
PROFILE="$ROOT/bin/fm-codex-cage.sb"
GH_PUBLIC_CLONE="$ROOT/bin/fm-gh-public-clone.sh"
LIVE_TEST="$ROOT/tests/fm-codex-cage-live-e2e.test.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-cage)

assert_present "$CAGE" "Codex cage wrapper is missing"
assert_present "$PROFILE" "Codex Seatbelt profile is missing"
assert_present "$GH_PUBLIC_CLONE" "public GitHub clone helper is missing"
assert_present "$SPAWN" "Firstmate spawn script is missing"
[ -x "$CAGE" ] || fail "Codex cage wrapper must be executable"
[ -x "$GH_PUBLIC_CLONE" ] || fail "public GitHub clone helper must be executable"

test_profile_security_contract() {
  local native_scope
  native_scope=$(
    sed -n \
      '/(with-filter (process-path codex-native)/,/^;; Writes are limited/p' \
      "$PROFILE"
  )

  assert_grep '(deny default)' "$PROFILE" "Seatbelt profile must deny by default"
  assert_grep '(with-filter (process-path codex-native)' "$PROFILE" \
    "only the Codex native process may receive CODEX_HOME access"
  assert_grep '(remote ip "localhost:*")' "$PROFILE" \
    "Seatbelt profile must block every loopback TCP destination"
  assert_grep '(literal no-mistakes-socket)' "$PROFILE" \
    "Seatbelt profile must allow only the exact no-mistakes Unix socket"
  assert_grep '(deny appleevent-send)' "$PROFILE" \
    "Seatbelt profile must block browser UI automation"
  assert_grep '(global-name-prefix "com.apple.lsd")' "$PROFILE" \
    "Seatbelt profile must block LaunchServices"
  assert_grep '(subpath tls-trust-dir)' "$PROFILE" \
    "caged TLS clients must read only the system trust directory"
  assert_not_contains "$native_scope" 'securityd' \
    "native Codex must not receive a credential-broker exception"
  assert_grep '(global-name-prefix "com.apple.securityd")' "$PROFILE" \
    "Seatbelt profile must block the securityd credential broker"
  assert_grep '(global-name-prefix "com.apple.secd")' "$PROFILE" \
    "Seatbelt profile must continue to block the secd credential broker"
  assert_grep '(global-name-prefix "com.apple.akd")' "$PROFILE" \
    "Seatbelt profile must continue to block the akd account broker"
  pass "Seatbelt profile pins TLS trust, credential, browser, loopback, and broker boundaries"
}

test_wrapper_fails_closed_on_invalid_scope() {
  local out rc
  if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    set +e
    out=$("$CAGE" --worktree "$ROOT" --status-path /tmp/status -- codex 2>&1)
    rc=$?
    set -e
    expect_code 2 "$rc" "unsupported operating systems must fail closed"
    assert_contains "$out" "no verified external Codex cage is available" \
      "unsupported operating system refusal is not actionable"
    pass "wrapper fails closed on unsupported operating systems"
    return
  fi

  set +e
  out=$("$CAGE" --worktree "$TMP_ROOT/missing" --status-path /tmp/status -- codex 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "missing worktree must fail closed"
  assert_contains "$out" "directory does not exist" "missing worktree refusal is not actionable"

  set +e
  out=$("$CAGE" --worktree "$ROOT" --status-path relative -- codex 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "relative lifecycle path must fail closed"
  assert_contains "$out" "file path must be absolute" "relative path refusal is not actionable"
  pass "wrapper rejects missing worktrees and relative lifecycle paths"
}

make_fake_cage_fixture() {
  local fixture=$1 fake_root=$2 fake_exec=$3 native
  mkdir -p "$fixture/bin" "$fixture/data" "$fixture/state" \
    "$fake_root/bin" "$fake_root/node_modules/pkg/vendor/aarch64-apple-darwin/bin"
  git -C "$fixture" init -q
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_root/bin/codex"
  chmod +x "$fake_root/bin/codex"
  native="$fake_root/node_modules/pkg/vendor/aarch64-apple-darwin/bin/codex"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$native"
  chmod +x "$native"
  cat >"$fake_exec" <<SH
#!/usr/bin/env bash
env | LC_ALL=C sort >"$TMP_ROOT/captured.env"
printf '%s\\n' "\$@" >"$TMP_ROOT/captured.args"
/bin/zsh -lc 'command -v gh' >"$TMP_ROOT/captured.gh-path"
exit 0
SH
  chmod +x "$fake_exec"
}

test_wrapper_sanitizes_environment_and_binds_exact_paths() {
  local copy_dir fixture main_home task_data state fake_root fake_exec out rc args captured_env gh_path
  copy_dir="$TMP_ROOT/copy"
  fixture="$TMP_ROOT/repo"
  main_home="$TMP_ROOT/main-home"
  task_data="$main_home/data/cage-acceptance"
  state="$main_home/state"
  fake_root="$TMP_ROOT/fake-codex"
  fake_exec="$TMP_ROOT/fake-sandbox-exec"
  mkdir -p "$copy_dir" "$task_data" "$state"
  cp "$CAGE" "$copy_dir/fm-codex-cage.sh"
  cp "$PROFILE" "$copy_dir/fm-codex-cage.sb"
  cp "$GH_PUBLIC_CLONE" "$copy_dir/fm-gh-public-clone.sh"
  make_fake_cage_fixture "$fixture" "$fake_root" "$fake_exec"
  fixture=$(cd "$fixture" && pwd -P)
  main_home=$(cd "$main_home" && pwd -P)
  task_data="$main_home/data/cage-acceptance"
  state="$main_home/state"
  sed -i.bak "s#^SANDBOX_EXEC=/usr/bin/sandbox-exec\$#SANDBOX_EXEC='$fake_exec'#" \
    "$copy_dir/fm-codex-cage.sh"
  chmod +x "$copy_dir/fm-codex-cage.sh"

  set +e
  out=$(
    cd "$fixture" && \
      PATH="$fake_root/bin:$PATH" FM_CAGE_TEST_SECRET=must-not-cross \
      "$copy_dir/fm-codex-cage.sh" \
        --worktree "$fixture" \
        --task-data-dir "$task_data" \
        --status-path "$state/cage-acceptance.status" \
        --notify-path "$state/cage-acceptance.turn-ended" \
        --fm-home "$main_home" \
        -- codex --dangerously-bypass-approvals-and-sandbox 2>&1
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "fake cage launch should reach sandbox-exec"
  [ -z "$out" ] || fail "fake cage launch printed unexpected output: $out"
  args=$(cat "$TMP_ROOT/captured.args")
  captured_env=$(cat "$TMP_ROOT/captured.env")
  gh_path=$(cat "$TMP_ROOT/captured.gh-path")

  assert_contains "$args" "-f" "wrapper did not pass a Seatbelt profile"
  assert_contains "$args" "WORKTREE=$fixture" "wrapper did not bind the exact worktree"
  assert_contains "$args" "TASK_DATA_DIR=$task_data" \
    "wrapper did not bind the exact main-home task data directory"
  assert_contains "$args" "STATUS_PATH=$state/cage-acceptance.status" \
    "wrapper did not bind the exact main-home status path"
  assert_contains "$args" "NOTIFY_PATH=$state/cage-acceptance.turn-ended" \
    "wrapper did not bind the exact main-home turn-end path"
  assert_contains "$args" "TLS_TRUST_DIR=/private/etc/ssl" \
    "wrapper did not bind the exact macOS TLS trust directory"
  assert_contains "$args" "--dangerously-bypass-approvals-and-sandbox" \
    "wrapper did not preserve the Codex execution posture"
  assert_not_contains "$captured_env" "FM_CAGE_TEST_SECRET" \
    "wrapper leaked an unapproved environment variable into the cage"
  assert_contains "$captured_env" "GH_CONFIG_DIR=" \
    "wrapper did not isolate GitHub CLI configuration"
  assert_contains "$captured_env" "GIT_CONFIG_GLOBAL=" \
    "wrapper did not provide a sanitized Git identity configuration"
  assert_contains "$captured_env" "NO_MISTAKES_TELEMETRY=off" \
    "wrapper did not pin no-mistakes telemetry off"
  assert_contains "$captured_env" "SSL_CERT_FILE=/private/etc/ssl/cert.pem" \
    "wrapper did not direct Codex to the public CA bundle"
  assert_contains "$captured_env" \
    "DEVELOPER_DIR=/Library/Developer/CommandLineTools" \
    "wrapper did not pin xcrun to the allowed Command Line Tools tree"
  assert_contains "$captured_env" "PATH=/private/tmp/fm-codex-cage." \
    "wrapper did not prepend its credential-free command directory"
  assert_contains "$captured_env" "ZDOTDIR=/private/tmp/fm-codex-cage." \
    "wrapper did not isolate login-shell startup"
  assert_contains "$gh_path" "/bin/gh" \
    "login shells do not resolve the credential-free gh helper"
  pass "wrapper sanitizes the environment and binds only exact task paths"
}

test_public_github_clone_helper() {
  local fakebin out rc args
  fakebin="$TMP_ROOT/public-gh-fakebin"
  mkdir -p "$fakebin"
  cat >"$fakebin/git" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$@" >"$TMP_ROOT/public-gh.args"
SH
  chmod +x "$fakebin/git"

  PATH="$fakebin:$PATH" "$GH_PUBLIC_CLONE" \
    repo clone octocat/Hello-World clone-target -- --depth=1
  args=$(cat "$TMP_ROOT/public-gh.args")
  assert_contains "$args" "clone" "public gh helper did not invoke git clone"
  assert_contains "$args" "https://github.com/octocat/Hello-World.git" \
    "public gh helper did not construct the expected HTTPS remote"
  assert_contains "$args" "clone-target" \
    "public gh helper did not preserve the destination"
  assert_contains "$args" "--depth=1" \
    "public gh helper did not preserve explicit Git flags"

  set +e
  out=$("$GH_PUBLIC_CLONE" api user 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "public gh helper must reject authenticated operations"
  assert_contains "$out" "only public 'gh repo clone OWNER/REPO' is supported" \
    "public gh helper rejection is not actionable"
  pass "public gh helper clones without credentials and rejects authenticated operations"
}

test_live_harness_preserves_evidence() {
  # shellcheck disable=SC2016  # Every assertion searches for literal shell source.
  assert_grep 'print_live_file evidence "$EVIDENCE"' "$LIVE_TEST" \
    "live harness must print probe evidence from its EXIT trap"
  # shellcheck disable=SC2016
  assert_grep 'print_live_file last-message "$LAST_MESSAGE"' "$LIVE_TEST" \
    "live harness must print the final message from its EXIT trap"
  assert_grep 'FM_CAGE_LIVE_ARTIFACTS_PRESERVED' "$LIVE_TEST" \
    "live harness must report the retained failure directory"
  # shellcheck disable=SC2016
  assert_grep 'LAST_MESSAGE_TRIMMED=$(sed' "$LIVE_TEST" \
    "live harness must trim only trailing final-message whitespace"
  # shellcheck disable=SC2016
  assert_grep '[ "$LAST_MESSAGE_TRIMMED" = CAGE_PROBE_DONE ]' "$LIVE_TEST" \
    "live harness must still require an exact final-message token"
  assert_grep 'synthetic browser endpoint was not live before cage launch' "$LIVE_TEST" \
    "live harness must prove the loopback server is live before probing it"
  assert_grep "printf 'payload-read-ok '" "$LIVE_TEST" \
    "live harness must prove the exfiltration payload was readable"
  # shellcheck disable=SC2016
  assert_grep '"${denied_path}|exit=1|output="*"Operation not permitted"*' "$LIVE_TEST" \
    "live harness must require an OS denial for protected file probes"
  assert_grep "grep -Fqx 'working: cage acceptance' \"\$STATUS\"" "$LIVE_TEST" \
    "live harness must compare the status line exactly"
  pass "live harness prints evidence on both paths and preserves failed runs"
}

test_spawn_templates_require_the_external_cage() {
  local cage_count bypass_count
  cage_count=$(grep -Fc '__CODEXCAGE__ --worktree' "$SPAWN" || true)
  bypass_count=$(
    grep -Fc -- '--dangerously-bypass-approvals-and-sandbox' "$SPAWN" || true
  )
  [ "$cage_count" -eq 2 ] \
    || fail "both Codex launch templates must enter the external cage"
  [ "$bypass_count" -eq 2 ] \
    || fail "both caged Codex launch templates must use the accepted bypass posture"
  assert_not_contains "$SPAWN" "--sandbox workspace-write" \
    "fm-spawn retained the interim workspace-write posture"
  assert_not_contains "$SPAWN" "sandbox_workspace_write.network_access" \
    "fm-spawn retained the interim workspace-write network override"
  pass "both Codex spawn templates require bypass mode inside the external cage"
}

test_profile_security_contract
test_wrapper_fails_closed_on_invalid_scope
if [ "$(/usr/bin/uname -s)" = Darwin ]; then
  test_wrapper_sanitizes_environment_and_binds_exact_paths
fi
test_public_github_clone_helper
test_live_harness_preserves_evidence
test_spawn_templates_require_the_external_cage
