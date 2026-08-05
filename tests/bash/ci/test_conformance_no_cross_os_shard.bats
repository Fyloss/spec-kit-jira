#!/usr/bin/env bats
# T017d [009, US2] — Mechanical guard for SC-011/FR-018/FR-019: every OS leg of
# the `unit` job must run Pester in full AND the complete 84-scenario
# conformance corpus — never a shard of it. Decision 7 permits sharding the
# corpus WITHIN one OS (multiple runners of the SAME os value); it explicitly
# FORBIDS spreading scenarios ACROSS the three OSes, which would leave no host
# proving the whole corpus. This is the guard that makes that mistake
# impossible to land quietly.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CI_YML="${ROOT}/.github/workflows/ci.yml"
  SCENARIOS_DIR="${ROOT}/tests/conformance/scenarios"
}

@test "the conformance corpus has exactly the recorded scenario count (96)" {
  # 015 adds four scenarios: us1-field-defaults-option-encoded,
  # us2-field-defaults-option-question, us3-created-count-refused,
  # us4-recorded-value-outside-allowed (70 -> 74).
  # 012 adds ten task sub-task scenarios (74 -> 84).
  # 017 adds six: us1-target-refusal, us1-stray-markers, us2-label-create,
  # us2-label-backfill, us2-label-second-run, us4-duplicate-probe (84 -> 90).
  # 018 adds six: us2-preserve-human-prefix, us1-plan-added-not-replaced,
  # us3-summary-rename-withheld, us3-summary-rename-proceed,
  # us4-migration-clean, us4-migration-ambiguous (90 -> 96).
  count="$(find "${SCENARIOS_DIR}" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
  [ "${count}" -eq 96 ]
}

@test "ci.yml's unit job never shards the corpus across OSes (FR-018)" {
  # If a shard total is configured for the unit job's conformance step at all,
  # it must be 1 (unsharded) — a value > 1 there, on a job whose matrix spans
  # three OSes, is exactly the forbidden shape.
  run awk '
    /^  unit:/ { in_unit = 1 }
    /^  [a-z-]+:$/ && !/^  unit:/ { in_unit = 0 }
    in_unit && /SPEC_KIT_JIRA_SHARD_TOTAL/ { print }
  ' "${CI_YML}"
  if [ -n "${output}" ]; then
    [[ "${output}" == *": 1"* || "${output}" == *"=1"* || "${output}" == *"'"'"'1'"'"'"* ]]
  fi
}

@test "windows-latest runs Pester unconditionally in the unit job (SC-011/FR-019)" {
  run awk '
    /Run Pester/ { print; getline; print; getline; print }
  ' "${CI_YML}"
  [[ "${output}" != *"runner.os != .Windows."* ]]
  [[ "${output}" != *"if:"* ]]
}

@test "windows-latest runs the conformance corpus unconditionally in the unit job (SC-011)" {
  run awk '
    /Run the conformance corpus/ { print; getline; print; getline; print }
  ' "${CI_YML}"
  [[ "${output}" != *"if:"* ]]
}
