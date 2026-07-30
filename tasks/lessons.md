# Lessons

- Per-home E2E teardown fixtures must pass the same `FM_HOME` that owned the spawn so endpoint validation and cleanup exercise the real runtime context.
- Cleanup schema hardening needs an explicit compatibility path for durable records written by earlier releases.
- Legacy cleanup must authorize durable worktree removal and live endpoint closure independently, with authoritative absence distinct from unreadable or foreign state.
- Runtime ownership belongs to the task container and its effective home, so replaceable pane or surface handles cannot prove absence and secondmate cleanup cannot inherit the primary home's identity.
- Effective endpoint homes are backend-specific: Herdr moves a secondmate into its child workspace, while Zellij keeps the secondmate endpoint in the spawning parent's shared session.
- Shared GUI runtimes need one global inventory authority for migration, live checks, and removal so window focus cannot change endpoint identity.
- Browser attribution namespaces must scope the entire task temp root by Firstmate home, not only the Puppeteer child directory.
- Process ownership evidence should be snapshotted once per candidate before comparing it with live task records.
- Relative path normalization must propagate through override variables when sourced scripts derive their own globals from those overrides.
