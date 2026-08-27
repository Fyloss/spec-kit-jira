#!/usr/bin/env bats
# T025 [US2] — Agent command definition regression (FR-007).
#
# The branch-prefix inference defect lived at the AGENT level: the command
# definition gave the model no key source, so it improvised from the branch
# name. The rewritten commands/speckit.jira-mirror.config.md MUST carry normative,
# grep-testable wording: key/style NEVER inferred from git state in a connected
# run; every branch-derived output belongs to the degraded mode only and is
# provisional; exactly the two new closed questions (style, project key).
# Written FIRST and observed failing against the current definition.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  DOC="${ROOT}/commands/speckit.jira-mirror.config.md"
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
  # The re-invocation is named in the repository-relative per-port form: the
  # install puts nothing on PATH, so a bare executable name would be unrunnable
  # (003 FR-014, FR-018).
  grep -q '.specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh config <KEY>' "${DOC}"
}

# --- T089a [Phase 6, 011] — the field-defaults ceremony, normatively --------

@test "the entry point never prompts for a field default (FR-002)" {
  grep -q 'the entry point does not prompt' "${DOC}"
}

@test "only a field Jira marks required produces a question" {
  grep -q 'Jira'\''s create metadata marks \*\*required\*\*' "${DOC}"
}

@test "an optional field's default is stated through --field-default or written into config.yml by hand (FR-004)" {
  grep -q -- '--field-default <KEY>=<Type>=<Label>=<Value>' "${DOC}"
  grep -q 'writing the entry by hand into `config.yml`'\''s `field_defaults`' "${DOC}"
}

# --- The two questions a run actually produces ------------------------------
#
# A team reported that the ceremony "asked nothing". Both questions it emits
# were undocumented here: the task-mirroring one the entry point prints on
# every run with no value recorded (022), and the board-position mapping the
# agent is to propose (023). A question the definition never names is a
# question the operator never hears.

@test "the definition tells the agent to relay the task-mirroring question" {
  grep -q 'Closed question (task mirroring, 022)' "${DOC}"
  grep -q -- '--task-mirror <KEY>=<subtask|checklist>' "${DOC}"
}

@test "the board-position proposal draws every status from the discovered list" {
  grep -q 'Board-position mapping (023)' "${DOC}"
  grep -q 'The only permitted status names are the ones' "${DOC}"
  grep -q 'projects\[\].statuses\[\]' "${DOC}"
}

@test "a project that already declares phase_status_map is never re-asked" {
  grep -q 'do not re-ask, do not rewrite it' "${DOC}"
}

@test "declining the proposal writes nothing, and is not pressed again" {
  grep -q 'Declining' "${DOC}"
  grep -q 'Do not press a declined proposal a second time' "${DOC}"
}

@test "the one exception to model-independence is stated up front, not buried" {
  grep -q 'with exactly \*\*one\*\* stated exception' "${DOC}"
}
