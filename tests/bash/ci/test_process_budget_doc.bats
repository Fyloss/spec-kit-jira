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

# The test above pinned Linux's cap alone, and that is exactly the shape of
# reasoning that let the defect hide: HELPER_ARGV_SIZE_LIMIT was calibrated to
# 131072 while Windows' CreateProcess cap is four times tighter, so a detector
# written for this defect stayed green through fourteen instances of it. A
# document that names only the loosest cap invites the same recalibration back.
# Pin the tightest one, and pin the rule that ranks them.
# A prose rule wraps wherever the paragraph happens to reflow, so these match
# against the file with newlines flattened to spaces. A line-anchored grep here
# would go red on a pure reflow — a false failure that teaches the next editor
# to weaken the guard rather than keep the rule.
_flat() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '; }

@test "the document names Windows' tighter per-argument cap" {
  _flat "${DOC}" | grep -qE "32[  ]?767"
}

@test "the document says the binding cap is the tightest supported host's" {
  _flat "${DOC}" | grep -qiE "tightest cap across (the )?supported hosts"
}

@test "AGENTS.md carries the same host-ranking rule, not just the Linux cap" {
  # AGENTS.md is loaded into every session; docs/11 is only read on purpose.
  # If the short version says "Linux caps a single argument at 128 KiB" and
  # stops there, the rule is wrong in the one place everyone actually sees it.
  _flat "${AGENTS}" | grep -qE "32[  ]?767"
  _flat "${AGENTS}" | grep -qiE "tightest across supported hosts"
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
