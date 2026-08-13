#!/usr/bin/env bats
# T017d [009, US2] — Mechanical guard for SC-011/FR-018/FR-019: every OS leg of
# the `unit` job must run Pester in full AND the complete 139-scenario
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

@test "the conformance corpus has exactly the recorded scenario count (157)" {
  # 015 adds four scenarios: us1-field-defaults-option-encoded,
  # us2-field-defaults-option-question, us3-created-count-refused,
  # us4-recorded-value-outside-allowed (70 -> 74).
  # 012 adds ten task sub-task scenarios (74 -> 84).
  # 016 adds two: us1-markdown-rendering, us3-markdown-idempotent (84 -> 86),
  # plus us1-task-markdown-rendering for the 012 overlap, FR-017 (86 -> 87).
  # 017 adds six: us1-target-refusal, us1-stray-markers, us2-label-create,
  # us2-label-backfill, us2-label-second-run, us4-duplicate-probe (87 -> 93).
  # 018 adds six: us2-preserve-human-prefix, us1-plan-added-not-replaced,
  # us3-summary-rename-withheld, us3-summary-rename-proceed,
  # us4-migration-clean, us4-migration-ambiguous (93 -> 99).
  # 018 Phase 8 (convergence) adds seven: sc008-task-tier-boundary,
  # sc008-oversized-description-refused, sc008-two-delimiters-refused,
  # sc008-privacy-prefix-allowed, sc008-privacy-composed-blocked,
  # sc008-deleted-managed-region-restored, sc008-summary-record-edges (99 -> 106).
  # 019 adds one: us4-migration-ambiguous-human — the FR-003 coverage the
  # origin-"bridge" rewrite of us4-migration-ambiguous.json would otherwise
  # remove (106 -> 107).
  # 021 adds two: us021-timing-off, us021-timing-on — invariants T1-T6 of
  # contracts/timing-report.md (107 -> 109).
  # 021 adds one: us021-state-unchanged — the run-state short-circuit,
  # invariant T8 of contracts/timing-report.md §3 (109 -> 110).
  # 021 adds three: us021-state-corrupt, us021-state-version-changed,
  # us021-state-config-changed — the fail-open rows of
  # contracts/run-state.md §3 (110 -> 113).
  # 021 adds four: us021-state-tasks-appeared, us021-state-tasks-deleted,
  # us021-state-first-run, us021-state-ondrift-changed — the remaining
  # contracts/run-state.md §9 rows T020/T021 do not cover (113 -> 117).
  # 021 adds two: us021b-disabled-event, us021b-rejected-target — the FR-027
  # placement rows proving the dispatch/target guards fire before the state
  # phase (117 -> 119).
  # 021 adds three: us022-dry-run-full-preview, us022-dry-run-no-write,
  # us022-force-bypasses-and-records — contracts/run-state.md §3/S6 rows for
  # --dry-run and --force (119 -> 122).
  # 021 adds one: us021-prefetch-basic — contracts/recognition-prefetch.md §6,
  # the base two-run create-then-recognise case (122 -> 123).
  # 021 adds four: us021-prefetch-bulkfetch-400, us021-prefetch-bulkfetch-401,
  # us021-prefetch-deleted-key, us021-prefetch-forbidden-key — the fail-open
  # and per-key-fallback classification rows of
  # contracts/recognition-prefetch.md §6 (123 -> 127).
  # 021 adds four: us021-prefetch-count-61, us021-prefetch-count-101,
  # us021-prefetch-count-61-deleted, us021-prefetch-count-zero — the
  # bulkfetch-chunking counting rows of contracts/recognition-prefetch.md
  # (127 -> 131).
  # 021 adds one: us021-prefetch-immediate-consistency —
  # contracts/recognition-prefetch.md §6, the "ticket created seconds
  # earlier" immediate-consistency acceptance scenario (131 -> 132).
  # 022 adds seven: us022-checklist-two-phases, us022-checklist-unchanged-rerun,
  # us022-checklist-entry-completed, us022-checklist-crlf,
  # us022-switch-to-checklist, us022-switch-to-subtask, us022-config-question
  # (132 -> 139).
  # 023 adds four: us023-story-advances, us023-already-at-target (Phase 4,
  # US1, T056/T057), us023-event-selects-step, us023-no-event-inert
  # (Phase 3, US2, T030/T031) (139 -> 143).
  # 023 adds two: us023-second-event-advances, us023-plan-md-invalidates
  # (Phase 5, US3, T072/T073) (143 -> 145).
  # 023 adds three: us023-two-role-workflows, us023-checklist-mode-inert,
  # us023-legacy-mapping-story-only (Phase 6, US4, T102/T103/T104)
  # (145 -> 148).
  # 023 adds two: us023-parent-halted, us023-parent-flagged (Phase 7, US5,
  # T117) — the parent's synthetic lifecycle entry gets the SAME
  # halt/Flagged treatment a story already does (U8), exercised end to end
  # rather than only at the pure plan_lifecycle level (148 -> 150).
  # 023 adds one: us023-move-rejected (Phase 7, US5, T118) — the mock's new
  # method-keyed fault injection lets a POST to .../transitions be rejected
  # while the GET on the same path stays healthy (150 -> 151).
  # 023 adds one: us023-ambiguous-candidates (Phase 8, US6, T127) — two
  # candidate transitions land on the same declared step name; the mirror
  # invents no preference and names both verbatim (151 -> 152).
  # 023 adds two: us023-gated-move, us023-gated-move-with-field-default
  # (Phase 9, US7, T136) — a gated move is refused and the demanded field
  # named; a recorded field_defaults value of the same name is never
  # substituted for it (rule M4) (152 -> 154).
  # 023 adds two: us023-unreachable-step, us023-unreachable-empty-set
  # (Phase 10, US8, T145) — the declared step is unreachable from the
  # current status; the mirror never forces an intermediate move and names
  # the reachable set (or the empty set) instead (154 -> 156).
  # 023 adds one: us023-sixty-stories-due (Phase 11, US9, T158) — a
  # 60-story specification with every story due a move, byte-identical
  # recorded call sequence on both ports at scale (156 -> 157).
  count="$(find "${SCENARIOS_DIR}" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
  [ "${count}" -eq 157 ]
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
