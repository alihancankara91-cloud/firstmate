# Codex launch sandbox posture

This document records the sandbox and approval posture Firstmate uses when it launches a Codex crewmate, scout, or secondmate, and the empirical evidence behind it.
`bin/fm-spawn.sh`'s `codex)` launch templates are the single owner of the exact flags; this doc is the evidence and rationale.

## Posture

Both Codex launch templates (secondmate and crewmate/scout) use:

```
--sandbox workspace-write --ask-for-approval never -c sandbox_workspace_write.network_access=true
```

- `--sandbox workspace-write` confines file writes and model-generated shell commands to the task worktree (plus `/tmp`); writes outside it are denied.
- `--ask-for-approval never` keeps an unattended agent running and denies (never escalates) any out-of-sandbox command instead of stalling on an approval prompt no human is watching.
- `-c sandbox_workspace_write.network_access=true` keeps outbound network on so `gh`, `git clone`, and `git fetch` still work.

This replaces the former `--dangerously-bypass-approvals-and-sandbox`, which disabled Codex's sandbox entirely.
Under that flag a YOLO Codex scout attached a debugging session to the captain's personal Chrome (logged-in accounts plus a crypto wallet); see the incident note below.

## Known, accepted residuals

On the verified Codex version the posture does NOT close these two vectors, and Codex has no configuration knob to close them at this version:

1. Host-file READS outside the worktree remain possible: `workspace-write` always grants full-disk read, and Codex 0.145 exposes no read-allowlist for it.
2. Connecting to an ALREADY-listening localhost port (for example a Chrome remote-debugging port that is already open) remains possible: Codex 0.145 network access is all-or-nothing, so enabling it for `gh`/clone also permits localhost. The per-domain / localhost-blocking config from OpenAI's online reference (`features.network_proxy.*`, `experimental_network.*`) is not recognized by Codex 0.145 (see evidence).

These are accepted for now because the posture is still a strict improvement over the full bypass: it confines all host writes, blocks launching a browser, blocks process control, and permits no escalation.
Full closure of both residuals requires an external OS sandbox around the whole agent, which is a separate fast-follow task: `fm-codex-external-sandbox`.

## Kun-approach finding (public, fetchable, verified)

The task premise was that this fix "matches Kun." The public evidence shows it diverges:

- `kunchenguid/firstmate` `bin/fm-spawn.sh` (default branch, tip commit `10ee779`, 2026-07-24; `fm-spawn.sh` last touched by `3eca8ff`) STILL launches Codex with `--dangerously-bypass-approvals-and-sandbox` for both the secondmate and crewmate/scout templates.
- `kunchenguid/no-mistakes` `internal/agent/codex.go` also defaults to `--dangerously-bypass-approvals-and-sandbox` unless the caller supplies `--sandbox`/`--ask-for-approval`/the bypass flag.
- The flag's own `--help`: "Skip all confirmation prompts and execute commands without sandboxing. EXTREMELY DANGEROUS. Intended solely for running in environments that are externally sandboxed."

So Kun's public posture is bypass Codex's internal sandbox and rely on an EXTERNAL sandbox around the agent, not `--sandbox workspace-write`.
This `workspace-write` change is a strict internal-hardening improvement but is not the same posture as Kun's public firstmate.
Truly matching Kun (external OS sandbox) is the `fm-codex-external-sandbox` fast-follow.

## Docs-probe assessment

`--dangerously-bypass-approvals-and-sandbox` also appears in one-shot `codex exec` probe examples in `docs/turnend-guard.md`, `docs/cd-guard.md`, `docs/arm-pretool-check.md`, `docs/subagent-guard.md`, and `docs/sessionstart-nudge.md`, and in the `codex exec` continuity test `tests/fm-codex-continuity-live-e2e.test.sh`.
These are disposable one-shot probes running a fixed trivial command, not live supervised agents, so they are lower risk and are left as-is here.
The continuity test in particular writes to a Firstmate home outside its project clone, which `workspace-write` would deny, so converting it needs its own change.
This is called out rather than silently left; hardening them can follow in `fm-codex-external-sandbox` or a docs pass.

## Empirical evidence

- Date: 2026-07-24
- Codex: `codex-cli 0.145.0`
- Host: macOS; Chrome installed at `/Applications/Google Chrome.app` (bundle `com.google.Chrome`, resolvable outside the sandbox via `osascript -e 'id of app "Google Chrome"'`).

Posture under test (`codex exec` implies approval `never`):

```
codex exec --skip-git-repo-check --strict-config -s workspace-write \
  -c sandbox_workspace_write.network_access=true \
  -c 'notify=["bash","-c","touch <TURNEND>"]' <prompt>
```

### It still works

| Command | Exact output | Exit |
|---------|--------------|------|
| `echo hello > inworktree.txt && cat inworktree.txt` | `hello` | 0 |
| `printf 'a\nb\nHIT\n' \| grep HIT` | `HIT` | 0 |
| `gh repo clone octocat/Hello-World cloned` | `Cloning into 'cloned'...` | 0 |
| `-c notify=[bash,-c,touch <TURNEND>]` | `<TURNEND>` file created after the turn | - |

### It cannot launch a browser or write/escalate off-worktree

| Command | Exact output | Exit | Blocked |
|---------|--------------|------|---------|
| `touch $HOME/CODEX_HOSTWRITE_TEST` | `touch: /Users/.../CODEX_HOSTWRITE_TEST: Operation not permitted` | 1 | yes |
| `open -na 'Google Chrome' --args --remote-debugging-port=9222` | `Unable to find application named 'Google Chrome'` (Chrome IS installed; sandbox blocks the LaunchServices lookup) | 1 | yes |
| `'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' --headless --remote-debugging-port=9222 --user-data-dir=./cdir` | `zsh: nice(5) failed: operation not permitted`; no debug server started | - | yes |
| `curl http://127.0.0.1:9222/json/version` (attach to the launch above) | curl exit 7 (connection failed; no server) | - | yes |
| `pkill -f remote-debugging-port=9222` | `Cannot get process list` | - | yes |

### Residuals - NOT blocked (see "Known, accepted residuals")

| Command | Exact output | Exit | Blocked |
|---------|--------------|------|---------|
| `curl http://127.0.0.1:9333/` (a test server pre-listening on localhost) | `HTTP 200` | 0 | no |
| `head -c 12 /etc/hosts` | `##\n# Host Da` | 0 | no |

### Per-domain / localhost-block config is unavailable on Codex 0.145

| Config override | Result |
|-----------------|--------|
| `-c features.network_proxy.enabled=true -c 'features.network_proxy.domains=[...]'` | `Error loading config.toml: data did not match any variant of untagged enum FeatureToml in features.network_proxy` |
| `-c experimental_network.enabled=true -c 'experimental_network.allowed_domains=[...]'` | `Error loading config.toml: unknown configuration field 'experimental_network'` |

## Incident note (root cause)

Firstmate conflated the captain-approved `+yolo` decision-autonomy posture with the Codex CLI's `--dangerously-bypass-approvals-and-sandbox` flag.
`+yolo` grants Firstmate authority over routine gates (merges, ask-user findings); it never intended to disable Codex's OS sandbox.
The launch templates hardcoded the bypass flag for every Codex task, so a YOLO scout ran with no sandbox and reached the captain's personal browser.
The fix decouples the two: decision autonomy stays, and Codex now runs sandboxed.
