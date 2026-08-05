#!/usr/bin/env bats
# T033 [US3] — The reconcile command definition (FR-010, FR-015 – FR-020, FR-030).
#
# Six lifecycle events registered a hook naming `speckit.jira.reconcile`. The
# command did not exist — no file, no manifest entry, nothing installed — so
# every registered `after_*` hook pointed at something the assistant could not
# resolve (research R7). This suite is the regression for that: the document
# exists, it answers to the name the hooks use, and its procedure is ordered and
# deterministic rather than left to judgement.
#
# Mirrors tests/bash/commands/test_agent_doc_config.bats in shape: the assertions
# are grep-testable statements about wording, because the wording IS the
# behaviour for a command the assistant executes by reading it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  DOC="${ROOT}/commands/speckit.jira.reconcile.md"
}

@test "the document exists — the whole point of research R7" {
  [ -f "${DOC}" ]
}

@test "front matter names the command exactly as the hooks reference it (FR-010)" {
  local frontmatter
  frontmatter="$(awk 'NR > 1 && /^---[[:space:]]*$/ { exit } NR > 1 { print }' "${DOC}")"
  grep -qE '^name:[[:space:]]*"speckit\.jira\.reconcile"[[:space:]]*$' <<< "${frontmatter}"
  grep -qE '^description:' <<< "${frontmatter}"
  grep -qE '^argument-hint:' <<< "${frontmatter}"
}

@test "the procedure is ordered and deterministic — four numbered steps" {
  grep -q '## Ordered procedure' "${DOC}"
  local n
  n="$(awk '/^## Ordered procedure/ { f = 1; next } f && /^## / { f = 0 } f && /^[0-9]+\. /' "${DOC}" | wc -l | tr -d ' ')"
  [ "${n}" -eq 4 ]
}

@test "step 1 locates the feature and is INERT with no active feature" {
  grep -q '.specify/feature.json' "${DOC}"
  grep -qi 'no active feature' "${DOC}"
}

@test "step 2 invokes the bridge by repository-relative path with --json (FR-014)" {
  grep -qF '.specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile' "${DOC}"
  grep -qF '.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 reconcile' "${DOC}"
  grep -qF -- '--json' "${DOC}"
}

@test "step 3 reports exactly one line per run (FR-016)" {
  grep -qi 'exactly one line' "${DOC}"
  # The phrase wraps in the document, so match the clause rather than the line.
  grep -qi 'never more than one' "${DOC}"
  grep -qi 'At most \*\*one\*\* message per host command run' "${DOC}"
}

@test "step 4 states the never-fail-the-host rule (FR-015)" {
  grep -q 'Never fail the host command' "${DOC}"
  grep -qi 'reported, not propagated' "${DOC}"
}

@test "the message-discipline table distinguishes all SIX causes (FR-017)" {
  grep -qi 'Not yet configured' "${DOC}"
  grep -qi 'Credentials absent' "${DOC}"
  grep -qi 'Credentials rejected' "${DOC}"
  grep -qi 'Prerequisite missing' "${DOC}"
  grep -qi 'Jira unreachable' "${DOC}"
  grep -qi 'Bridge unavailable' "${DOC}"
}

@test "a disabled event is reported as NOTHING AT ALL (FR-020)" {
  # Announcing the skip on every lifecycle command would be exactly the noise
  # FR-020 forbids for an event the operator deliberately turned off.
  grep -qi 'Report \*\*nothing at all\*\*' "${DOC}"
  grep -qi 'do not announce' "${DOC}"
}

@test "the not-yet-configured notice is capped at three lines (FR-019)" {
  grep -qi 'three lines' "${DOC}"
}

@test "the document forbids recalling a command name from memory (FR-018)" {
  grep -qi 'never recalled from' "${DOC}"
  grep -q '/speckit.jira.config' "${DOC}"
  grep -q '/speckit.jira.reconcile' "${DOC}"
}

@test "the exit-code section states none of them reaches the host (FR-015)" {
  grep -qi "None of these ever becomes the host command's exit code" "${DOC}"
}

# --- T089b [Phase 6, 011] — the field-defaults consolidated question, normatively --------

@test "the document states re-invocation with --accept-defaults and --field-value (contract §3.5)" {
  grep -q -- '--accept-defaults' "${DOC}"
  grep -q -- '--field-value <KEY>=<Type>=<Label>=<Value>' "${DOC}"
}

@test "a decline is resumed with --accept-defaults and no decline flag exists (FR-015)" {
  grep -q 'no decline flag' "${DOC}"
  grep -qi 're-invoke with `--accept-defaults`' "${DOC}"
}

@test "the unreachable-operator contract: the caller declares it on its first invocation (research R4, contract §3.10)" {
  grep -q 'on its \*\*first\*\* invocation' "${DOC}"
}

@test "the unreachable-operator contract: the entry point never sniffs a TTY (research R4)" {
  grep -q 'never sniffs a TTY' "${DOC}"
}

@test "a hook-fired run is documented as not an unreachable-operator caller (contract §3.10)" {
  grep -q 'is not such a caller' "${DOC}"
}

# --- 017, US3 [T039] — the single-target rule, documented normatively ------

@test "017 — step 1 states the single-target rule once for all six events (FR-019–FR-021)" {
  grep -qi "target is always that feature's own \`spec.md\`" "${DOC}"
}

@test "017 — the document names plan, tasks, research, data-model, quickstart, contracts and analysis output as never targets" {
  grep -qF 'plan.md' "${DOC}"
  grep -qF 'tasks.md' "${DOC}"
  grep -qF 'research.md' "${DOC}"
  grep -qF 'data-model.md' "${DOC}"
  grep -qF 'quickstart.md' "${DOC}"
  grep -qF 'contracts/' "${DOC}"
  grep -qi 'analysis output' "${DOC}"
}

@test "017 — the message-discipline table carries the rejected-target row, exit 1, one reported line" {
  grep -qi 'Rejected target' "${DOC}"
  grep -qE '\| Rejected target \| Exit `1`' "${DOC}"
}

@test "017 — the section heading's stated cause count matches the number of table rows" {
  local heading_n row_n
  heading_n="$(grep -oE '## Message discipline — the [a-z]+ distinguished causes' "${DOC}" | sed -E 's/.*the ([a-z]+) distinguished.*/\1/')"
  [ "${heading_n}" = "eight" ]
  # Every data row, header and separator excluded — a row may start with a
  # bold cause name (`| **Bridge unavailable** |`), so match on the leading
  # pipe alone and subtract the two fixed header lines.
  row_n="$(awk '/^## Message discipline/ { f = 1; next } f && /^## / { f = 0 } f && /^\|/' "${DOC}" | wc -l | tr -d ' ')"
  [ "$((row_n - 2))" -eq 8 ]
}

@test "017 — the <SPEC-FILE> positional is documented as accepting a feature specification file only" {
  grep -qi 'accepting a feature specification' "${DOC}"
}
