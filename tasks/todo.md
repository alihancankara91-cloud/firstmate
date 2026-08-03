# CI behavior failure fixes

- [x] Diagnose the portable secondmate teardown failure and the Herdr per-home teardown failure.
- [x] Update the stale portable assertion and restore faithful per-home teardown context.
- [x] Run focused portable and Herdr verification.

# Review finding fixes

- [x] Validate legacy non-tmux cleanup, Orca abort recovery, and delivery-gate documentation findings.
- [x] Preserve strict current metadata validation while admitting structurally valid legacy records.
- [x] Make Orca worktree-only recovery records teardown-compatible.
- [x] Restore the canonical delivery-gate state inventory.
- [x] Add regression coverage.
- [x] Run one focused verification.

# Legacy provenance hardening

- [x] Reproduce binding-stripping downgrade and identify task-bound evidence for each non-tmux backend.
- [x] Require bounded live or durable provenance before legacy cleanup.
- [x] Document the compatibility and migration contract in `docs/configuration.md`.
- [x] Add downgrade and authenticated-legacy regression coverage.
- [x] Run one focused verification.

# Legacy ownership completion

- [x] Reproduce and validate the five remaining cleanup findings.
- [x] Unify durable task and home provenance for legacy endpoint migration.
- [x] Preserve worktree cleanup when legacy endpoints are absent or unauthoritative.
- [x] Fix bound Herdr agent-exit cleanup arguments.
- [x] Update focused regression coverage and operator contract.
- [x] Run one focused verification.

# Legacy endpoint leak completion

- [x] Reproduce and validate the five remaining ownership findings.
- [x] Derive the validated secondmate endpoint home for top-level teardown.
- [x] Authenticate pathless pre-launch Orca recovery without an `fm/<id>` branch.
- [x] Tighten Herdr, Zellij, and cmux authoritative-absence classification.
- [x] Add focused regression coverage and update the runtime contract.
- [x] Run one focused verification.

# Historical runtime recovery completion

- [x] Reproduce and validate the three remaining compatibility findings.
- [x] Authenticate markerless pathless Orca records with historical provenance.
- [x] Keep Zellij secondmates on their state-owning parent home.
- [x] Reacquire unique cmux replacement workspaces and surfaces.
- [x] Add focused regressions and update the runtime contract.
- [x] Run one focused verification.

# Cmux cross-window cleanup completion

- [x] Reproduce and validate the current-window lookup defect.
- [x] Centralize all-window workspace inventory.
- [x] Bind target recovery and removal to the global inventory.
- [x] Add focused cross-window regression coverage.
- [x] Run one focused verification.

# Browser reaper review fixes

- [x] Validate the four reported findings against the current diff.
- [x] Home-scope task temp roots and browser ownership.
- [x] Cache browser candidate ancestry and support markerless headless roots.
- [x] Close recursive secondmate teardown's post-endpoint race.
- [x] Add regression coverage.
- [x] Run focused verification.

# Browser reaper documentation review

- [x] Inspect the target diff and changed contracts.
- [x] Trace browser cleanup facts to their authoritative owners.
- [x] Remove the duplicate base metadata inventory from `AGENTS.md`.
- [x] Document conservative live-task and unattributed-browser retention.
- [x] Re-read the updated documentation and run documentation checks.

# Relative durable root review

- [x] Reproduce the cwd-dependent durable handoffs.
- [x] Compare the failing and absolute-root paths.
- [x] Normalize relative roots at all three changed handoff boundaries.
- [x] Add behavioral regression coverage.
- [x] Run one focused verification.

# Relative X consumer root review

- [x] Trace bootstrap output through migration, watcher validation, and poll dispatch.
- [x] Confirm the authenticated shim is quarantined by an unnormalized consumer.
- [x] Normalize root ownership at all three consumer entry points.
- [x] Add bootstrap-to-watcher behavioral coverage.
- [x] Run one focused verification.

# Relative X fallback-home review

- [x] Reproduce absolute root with a relative fallback home and state.
- [x] Identify initialization order as the shared consumer defect.
- [x] Derive fallback homes only after root normalization.
- [x] Exercise the unset-home bootstrap-to-watcher path.
- [x] Run one focused verification.

# Relative X explicit-home review

- [x] Reproduce explicit relative home and state shim rejection.
- [x] Audit producer and consumer durable path initialization.
- [x] Canonicalize relative root, home, and state inputs consistently.
- [x] Exercise explicit relative home and state handoffs.

# Upstream sync 2026-08-03

- [ ] Fetch origin/main and upstream/main, confirm the six upstream commits.
- [ ] Merge upstream/main with a real merge commit and reconcile conflicts without dropping fork adaptations.
- [ ] Export conflict evidence, prove ancestry, and run the full local test suite plus focused lint.
- [ ] Drive no-mistakes through green CI and open the required PR without merging it.
- [x] Run one focused verification.
