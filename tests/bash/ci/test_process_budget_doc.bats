#!/usr/bin/env bats
# T005 — Guard for the process budget's discoverability (FR-002, spec 025 US1).
#
# This does not prove the document is READABLE — quickstart.md §1 verifies
# that by inspection. It proves a future edit cannot silently break the path
# from AGENTS.md (loaded automatically every session) to the authoritative
# rule, and cannot silently drop either half of the batching/argument-routing
# rule that PR #31 and feature 024 each had to relearn the hard way.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  DOC="${ROOT}/docs/11-process-budget.md"
  AGENTS="${ROOT}/AGENTS.md"
}

@test "docs/11-process-budget.md exists" {
  [ -f "${DOC}" ]
}

@test "AGENTS.md references docs/11-process-budget.md by path" {
  grep -q "docs/11-process-budget.md" "${AGENTS}"
}

@test "the document names the per-item process prohibition" {
  grep -qi "per-item" "${DOC}"
}

@test "the document names the argument-routing requirement" {
  grep -qi "argument" "${DOC}"
  grep -qi "temp file" "${DOC}"
}

@test "the document names the 128 KiB argument limit" {
  grep -q "128 KiB" "${DOC}"
}

@test "every repository path the document names actually exists" {
  # T037: guards the document's outbound references, not only AGENTS.md's
  # inbound one — the exact link rot T031 found and corrected (the document
  # once claimed a test file existed when it did not).
  #
  # One path is a documented, deliberate exception: the whole-run test is
  # specified but not built (US2 blocked, research.md R5/D7), and the
  # document says so in the same sentence it names the path. That sentence
  # is proof the path is *meant* to be absent, not link rot.
  local known_absent="tests/bash/commands/test_reconcile_run_budget.bats"
  local paths path missing=""
  paths="$(grep -oE '`(scripts|tests|specs|docs)/[A-Za-z0-9_./-]+\.[a-zA-Z0-9]+(:[0-9]+)?`' "${DOC}" \
    | tr -d '`' | sed -E 's/:[0-9]+$//' | sort -u)"
  while IFS= read -r path; do
    [ -z "${path}" ] && continue
    [ "${path}" = "${known_absent}" ] && continue
    [ -e "${ROOT}/${path}" ] || missing="${missing}${path} "
  done <<< "${paths}"
  [ -z "${missing}" ]
}
