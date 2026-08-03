# shellcheck shell=bash

fm_delivery_contract() {  # <mode> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      FM_DELIVERY_SETUP=
      FM_DELIVERY_RULE1='1. Never push to the default branch (push only your `fm/'"$id"'` branch). Never merge a PR.'
      IFS= read -r -d '' FM_DELIVERY_DOD <<EOF || true
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      FM_DELIVERY_SETUP=
      FM_DELIVERY_RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`."
      IFS= read -r -d '' FM_DELIVERY_DOD <<EOF || true
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      FM_DELIVERY_SETUP="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
      FM_DELIVERY_RULE1='1. Never push to the default branch. Never merge a PR.'
      IFS= read -r -d '' FM_DELIVERY_DOD <<EOF || true
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its \`AGENTS.md\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    *) return 1 ;;
  esac
  FM_DELIVERY_DOD=${FM_DELIVERY_DOD%$'\n'}
}

fm_ship_rules() {  # <status-file> <paused-verb> <escalation-format>
  local status_file=$1 paused_verb=$2 escalation_format=$3
  IFS= read -r -d '' FM_SHIP_RULES <<EOF || true
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $status_file\`
   States: working, needs-decision, blocked, $paused_verb, done, failed.
$escalation_format
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$paused_verb: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use the structured \`blocked\` form above when you are stuck and need help.
5. If you hit the same obstacle twice, report it with the structured \`blocked\` form above and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   report it with the structured \`needs-decision\` form above and stop. Firstmate will apply the configured authority and reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, report it with the structured \`blocked\` form above and stop; only firstmate manages the daemon.
EOF
  FM_SHIP_RULES=${FM_SHIP_RULES%$'\n'}
}
