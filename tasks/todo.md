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
