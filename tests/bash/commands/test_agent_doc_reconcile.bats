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
