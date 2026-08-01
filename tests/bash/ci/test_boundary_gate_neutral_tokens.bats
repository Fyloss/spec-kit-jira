#!/usr/bin/env bats
# CI-definition guard: the engine/sink boundary gate must fail on Jira issue
# keys and on nothing else.
#
# Gate #2 of the Boundary workflow greps every engine script for the issue-key
# shape `[A-Z]{2,}-[0-9]+`. That shape is not exclusive to Jira: this
# repository writes its own requirement labels the same way (FR-011, NFR-004,
# SC-003), and so do standard names (UTF-8, ISO-8601, SHA-256). The gate read
# nine such comment references in the engine layer as Atlassian identifiers and
# failed the build on them — a false positive that says nothing about
# Constitution VIII, and that the fix for is NOT to stop scanning comments: a
# comment naming a real issue key in an engine script is still Jira knowledge
# where the constitution forbids it.
#
# So the gate is exercised here as the workflow runs it — the step's own shell
# block is lifted out of the YAML and executed — against three inputs: the real
# engine layer (must pass), a planted issue key (must fail), and a file of
# neutral tokens (must pass).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  BOUNDARY="${ROOT}/.github/workflows/boundary.yml"
  GATE="${BATS_TEST_TMPDIR}/gate2.sh"
  gate_script >"${GATE}"
}

# Emits the shell block of the "no Atlassian identifier" step, verbatim.
gate_script() {
  awk '
    /^ *- name: .*Atlassian identifier/ { step = 1; next }
    step && /^ *run: \|/                { body = 1; next }
    body && /^ *- name:/                { exit }
    body
  ' "${BOUNDARY}"
}

# Runs the gate with <dir> as the repository root it scans.
run_gate_in() {
  ( cd "$1" && bash "${GATE}" )
}

# Creates an engine layer under a fresh root, holding <content>.
plant_engine() {
  local root="${BATS_TEST_TMPDIR}/$1" content="$2"
  mkdir -p "${root}/scripts/bash/engine"
  printf '%s\n' "${content}" >"${root}/scripts/bash/engine/probe.sh"
  printf '%s' "${root}"
}

@test "the gate's shell block can be lifted out of the workflow" {
  grep -q 'patterns=(' "${GATE}"
  grep -q 'scripts/bash/engine' "${GATE}"
  grep -q 'scripts/powershell/engine' "${GATE}"
}

@test "the gate passes on the engine layer as committed" {
  run run_gate_in "${ROOT}"
  [ "${status}" -eq 0 ]
}

@test "the gate still fails on a Jira issue key in an engine script" {
  root="$(plant_engine keyleak '# mirrored from PROJ-123')"
  run run_gate_in "${root}"
  [ "${status}" -ne 0 ]
}

@test "the gate still fails on a two-letter Jira issue key" {
  root="$(plant_engine shortkey '# mirrored from AB-7')"
  run run_gate_in "${root}"
  [ "${status}" -ne 0 ]
}

@test "the gate passes on requirement labels and standard names" {
  root="$(plant_engine neutral '# FR-011, NFR-004, SC-003, UTF-8, ISO-8601, SHA-256')"
  run run_gate_in "${root}"
  [ "${status}" -eq 0 ]
}

@test "the gate fails on an issue key sharing a line with a requirement label" {
  root="$(plant_engine mixed '# FR-011 is mirrored as PROJ-123')"
  run run_gate_in "${root}"
  [ "${status}" -ne 0 ]
}

@test "the gate still fails on the vendor host and its API verbs" {
  # The host token is assembled from split literals, as the workflow does.
  root="$(plant_engine vendor '# POST https://acme.atlas''sian.net/rest/api/3/issue/create''meta')"
  run run_gate_in "${root}"
  [ "${status}" -ne 0 ]
}
