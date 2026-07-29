# Gotchas

- `apply_patch` cannot create a file when its parent directory is absent, so create the directory first.
- A file cannot be added and updated in the same `apply_patch` call.
- Under macOS Bash 3 with `set -u`, expanding a declared but empty array raises an unbound-variable error, so seed indexed caches with an empty element.
- Distinct-home attribution tests must include the secondmate home marker because the shared home-tag helper uses that marker to distinguish homes sharing one code root.
- Home-scoped browser path recognition must match canonical home-tag prefixes, not every directory whose unrelated name begins with `browser-`.
- Running a test definition through `/dev/fd` breaks fixtures that resolve shared helpers relative to the script path, so use the repository test runner.
- Repository discovery must stay rooted in the current worktree because sibling worktrees are outside the permitted review boundary.
