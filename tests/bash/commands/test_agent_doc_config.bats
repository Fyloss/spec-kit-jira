#!/usr/bin/env bats
# T025 [US2] — Agent command definition regression (FR-007).
#
# The branch-prefix inference defect lived at the AGENT level: the command
# definition gave the model no key source, so it improvised from the branch
# name. The rewritten commands/speckit.jira.config.md MUST carry normative,
# grep-testable wording: key/style NEVER inferred from git state in a connected
# run; every branch-derived output belongs to the degraded mode only and is
# provisional; exactly the two new closed questions (style, project key).
# Written FIRST and observed failing against the current definition.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  DOC="${ROOT}/commands/speckit.jira.config.md"
}

@test "the definition forbids git-state inference in a connected run (FR-007)" {
  grep -q 'in a connected run the project key and the project style are NEVER inferred from git state' "${DOC}"
  grep -q 'branch names, branch prefixes, folder names, remote names' "${DOC}"
}

@test "the definition marks every branch-derived output as degraded-mode-only and provisional" {
  grep -q 'branch-derived output belongs to the degraded mode only and is provisional' "${DOC}"
}

@test "the definition documents the degraded-mode announcement and re-run guidance" {
  grep -q 'degraded mode' "${DOC}"
  grep -qi 're-run' "${DOC}"
}

@test "the style closed question offers exactly the two enum values via --style" {
  grep -q 'Closed question (project style)' "${DOC}"
  grep -q -- '--style <KEY>=company_managed' "${DOC}"
  grep -q -- '--style <KEY>=team_managed' "${DOC}"
}

@test "the project-key closed question is asked over the discovered list only" {
  grep -q 'Closed question (project key)' "${DOC}"
  grep -q 'accessible projects' "${DOC}"
  grep -q 'spec-kit-jira config <KEY>' "${DOC}"
}
