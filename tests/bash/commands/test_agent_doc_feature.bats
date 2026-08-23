#!/usr/bin/env bats
# The feature command definition — the scope fence (consumer incident 2026-08-22).
#
# `speckit.jira.feature` is a `before_specify` hook that computes NAMES. In the
# reported incident a single dispatch of it authored `spec.md`, skipped the
# remaining `before_specify` hooks, and ran the `after_specify` chain itself —
# which created two real Jira issues in a shared project before any
# specification existed. No port code can do that: `cmd_feature` cannot reach
# reconcile, and the dispatcher routes one command per run. The document was the
# defect: its step 5 said "drive the host flow" and named no boundary, and an
# absent "never" reads to an agent as a licence.
#
# Mirrors tests/bash/commands/test_agent_doc_reconcile.bats in shape: the
# assertions are grep-testable statements about wording, because the wording IS
# the behaviour for a command the assistant executes by reading it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  DOC="${ROOT}/commands/speckit.jira.feature.md"
}

@test "the document exists and answers to the name the hook references" {
  [ -f "${DOC}" ]
  local frontmatter
  frontmatter="$(awk 'NR > 1 && /^---[[:space:]]*$/ { exit } NR > 1 { print }' "${DOC}")"
  grep -qE '^name:[[:space:]]*"speckit\.jira\.feature"[[:space:]]*$' <<< "${frontmatter}"
}

@test "the scope fence is a section of its own, ahead of the ceremony" {
  grep -q '^## What this step is, and is not — normative$' "${DOC}"
  local fence ceremony
  fence="$(grep -n '^## What this step is, and is not — normative$' "${DOC}" | cut -d: -f1)"
  ceremony="$(grep -n '^## Ordered ceremony$' "${DOC}" | cut -d: -f1)"
  [ -n "${fence}" ] && [ -n "${ceremony}" ]
  [ "${fence}" -lt "${ceremony}" ]
}

# The three prohibitions, one test each: each names a distinct step of the
# incident, and a fence that loses one of them silently reopens that door.

@test "the fence forbids authoring the specification itself" {
  local body
  body="$(awk '/^## What this step is, and is not — normative$/ { f = 1; next } f && /^## / { f = 0 } f' "${DOC}")"
  grep -qE 'MUST NOT' <<< "${body}"
  grep -qE 'spec\.md' <<< "${body}"
  grep -qE 'checklist' <<< "${body}"
}

@test "the fence forbids standing in for the sibling before_specify hooks" {
  local body
  body="$(awk '/^## What this step is, and is not — normative$/ { f = 1; next } f && /^## / { f = 0 } f' "${DOC}")"
  grep -qE 'before_specify' <<< "${body}"
  grep -qE 'priority order' <<< "${body}"
}

@test "the fence forbids dispatching any after_* hook, and names reconcile" {
  local body
  body="$(awk '/^## What this step is, and is not — normative$/ { f = 1; next } f && /^## / { f = 0 } f' "${DOC}")"
  grep -qE 'after_\*' <<< "${body}"
  grep -qE 'speckit\.jira\.reconcile' <<< "${body}"
  grep -qE 'after_specify' <<< "${body}"
}

@test "the fence states that non-optional dispatch is not ownership of the command" {
  local body
  body="$(awk '/^## What this step is, and is not — normative$/ { f = 1; next } f && /^## / { f = 0 } f' "${DOC}")"
  grep -qE 'optional: false' <<< "${body}"
  grep -qE 'return control' <<< "${body}"
}

# The prose this guard rejects is wrapped across two source lines ("\u2026 \u21d2 drive"
# / "the host flow with \u2026"), so a line-oriented grep matches nothing and the
# assertion passes against the very file it is meant to reject. Flatten first.
@test "step 5 no longer tells the agent to drive the host flow" {
  local step5
  step5="$(awk '/^5\. \*\*Nominal output\*\*/ { f = 1 } f && /^## / { f = 0 } f' "${DOC}" | tr '\n' ' ')"
  [ -n "${step5}" ]
  ! grep -qE 'drive[[:space:]]+the host flow' <<< "${step5}"
}

@test "step 5 makes branch creation a named owner's job, not this hook's" {
  local step5
  step5="$(awk '/^5\. \*\*Nominal output\*\*/ { f = 1 } f && /^## / { f = 0 } f' "${DOC}")"
  grep -qE 'git\.feature' <<< "${step5}"
  grep -qE 'verbatim' <<< "${step5}"
}

@test "step 5 names GIT_BRANCH_NAME as the conveyance, not prose goodwill" {
  local step5
  step5="$(awk '/^5\. \*\*Nominal output\*\*/ { f = 1 } f && /^## / { f = 0 } f' "${DOC}")"
  grep -qE 'GIT_BRANCH_NAME' <<< "${step5}"
}

# Two different scripts are named create-new-feature.sh — the host's (folder, no
# git) and the git extension's (branch, no folder). Naming one without a path
# leaves the agent to guess, and the two do opposite halves of the job.
@test "step 5 disambiguates the host folder script from the git extension's" {
  local step5
  step5="$(awk '/^5\. \*\*Nominal output\*\*/ { f = 1 } f && /^## / { f = 0 } f' "${DOC}" | tr '\n' ' ')"
  grep -qE '\.specify/scripts/bash/create-new-feature\.sh' <<< "${step5}"
  grep -qE '\.specify/extensions/git' <<< "${step5}"
}

# Naming another extension in a normative step is a coupling risk: this one
# neither requires nor detects it. The requirement must sit on the host-level
# channel, with the counterpart marked as an illustration.
@test "step 5 marks the receiving extension as an illustration, not a prerequisite" {
  local step5
  step5="$(awk '/^5\. \*\*Nominal output\*\*/ { f = 1 } f && /^## / { f = 0 } f' "${DOC}" | tr '\n' ' ')"
  # Flattening newlines leaves the source indentation behind, so every
  # multi-word phrase must tolerate a run of spaces, not exactly one.
  grep -qE 'not[[:space:]]+a[[:space:]]+prerequisite' <<< "${step5}"
  grep -qE 'neither[[:space:]]+requires[[:space:]]+nor[[:space:]]+detects' <<< "${step5}"
}

# This definition is read on both hosts. A Bash-only spelling makes the
# ceremony undeterministic on Windows, where `export` does not exist and the
# host ships the PowerShell port of its own scripts.
@test "step 5 spells the environment variable for both hosts" {
  local step5
  step5="$(awk '/^5\. \*\*Nominal output\*\*/ { f = 1 } f && /^## / { f = 0 } f' "${DOC}")"
  grep -qE 'GIT_BRANCH_NAME=' <<< "${step5}"
  grep -qE '\$env:GIT_BRANCH_NAME' <<< "${step5}"
}

@test "step 5 spells the host folder script for both hosts" {
  local step5
  step5="$(awk '/^5\. \*\*Nominal output\*\*/ { f = 1 } f && /^## / { f = 0 } f' "${DOC}")"
  grep -qE '\.specify/scripts/bash/create-new-feature\.sh' <<< "${step5}"
  grep -qE '\.specify/scripts/powershell/create-new-feature\.ps1' <<< "${step5}"
}

@test "step 5 records that the host folder script writes no specification content" {
  local step5
  step5="$(awk '/^5\. \*\*Nominal output\*\*/ { f = 1 } f && /^## / { f = 0 } f' "${DOC}" | tr '\n' ' ')"
  grep -qE 'create-new-feature\.sh' <<< "${step5}"
  grep -qE 'no[[:space:]]+specification[^*]*content' <<< "${step5}"
}
