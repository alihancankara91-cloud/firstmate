# Gotchas

- Run focused ShellCheck through the repository's configured source graph or with its established exclusions; a bare multi-file invocation reports non-actionable SC1091 and test-harness SC2153 diagnostics.
- Before a multi-file patch, re-read every target hunk's exact current context; one shifted function signature rejects the entire patch.
- In a failure-condition OR chain, an optional write guard must return false when the optional value is absent.
- Use the repository's approved evidence directory for redirected test traces; broad file-removal command forms are rejected even for one exact temporary file.
- Herdr jq arguments must avoid jq 1.6 reserved identifiers, including `label`.
- Re-read the exact flagged jq expression before patching because its result-shape predicate may differ from nearby queries.
- The docs audience checker classifies every changed Markdown file, including workflow task ledgers, so focused source verification must account for those separately.
- Locate the audience inventory from the checker defaults before assuming its path.
- ShellCheck treats a later test-local function override as the definition for earlier calls, so real-helper coverage and stubbed orchestration coverage belong in separate test functions.
