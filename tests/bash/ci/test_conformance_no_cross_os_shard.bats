#!/usr/bin/env bats
# T017d [009, US2] — Mechanical guard for SC-011/FR-018/FR-019: every OS leg of
# the `unit` job must run Pester in full AND the complete conformance corpus —
# never a shard of it. The corpus size is asserted below and grows with the
# tree; it is deliberately NOT restated here, because a second copy of the
# number is a second thing to forget. Decision 7 permits sharding the
# corpus WITHIN one OS (multiple runners of the SAME os value); it explicitly
# FORBIDS spreading scenarios ACROSS the three OSes, which would leave no host
# proving the whole corpus. This is the guard that makes that mistake
# impossible to land quietly.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CI_YML="${ROOT}/.github/workflows/ci.yml"
  SCENARIOS_DIR="${ROOT}/tests/conformance/scenarios"
}

@test "the conformance corpus has exactly the recorded scenario count (231)" {
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
  # 023 adds one: us023-dry-run-twin (Phase 12, US10, T165) — a --dry-run
  # run under a hook event that resolves a real transition, predicting the
  # move and writing nothing, byte-identical on both ports (157 -> 158).
  # 023 adds one: us023-idempotent-rerun (Phase 13, T167) — a real move,
  # then a second run over unchanged state that short-circuits (021's own
  # mechanism), zero requests of any kind (158 -> 159).
  # 023 adds one: us023-baseline-no-event (Phase 1, T003) — a project that
  # DOES declare a phase_status_map, run with no hook event: byte-for-byte
  # identical to a project declaring none at all (FR-011) (159 -> 160).
  # 023 Phase 14 (convergence) adds one: us023-story-advances-prose (T181) —
  # the us023-story-advances headline move run WITHOUT --json, proving
  # counts.transitioned reaches the default prose report too (160 -> 161).
  # 027 (US5, T069) adds one: us027-no-designators-untouched — the C-1
  # regression pin proving an invocation with neither --parent nor --story
  # is byte-identical to the pre-027 release (161 -> 162).
  # 027 (US1, T089) adds two: us027-three-url-forms, us027-bind-stories —
  # the MVP end to end: designator resolution and two-moment binding
  # (162 -> 164).
  # 027 (US3, T098) adds one: us027-adopt-existing-parent — a named parent
  # is bound, never created, alongside two named stories (164 -> 165).
  # 027 (US6, T106) adds one: us027-human-content-preserved — feature, seed
  # --confirm, then a full reconcile: every human-authored byte survives
  # above the managed boundary marker (165 -> 166).
  # 027 (US7, T119) adds two: us027-decline-resume — decline, then a resume
  # with no flags resupplied confirms cleanly; us027-draft-edit-refused — a
  # decline, an operator edit that deletes the pinned marker, then a resume
  # refuses REF-DRAFT-EDIT (166 -> 168).
  # 027 (US4, T124) adds one: us027-parent-only — a single parent-role
  # designator, no pinning constraint, both drafted user stories created
  # under it on the following reconcile (168 -> 169).
  # 027 (US2, T139) adds three: us027-create-parent — the feature's only two
  # irreversible writes, a free-text parent create plus story binds;
  # us027-reparent-disclosure — the "! reparent" line naming the current
  # parent and child-loss count; us027-scatter-note — no parent designated,
  # an already-parented story discloses without writing (169 -> 172).
  # 027 (Polish, T151) adds fourteen: us027-refuse-{designator,host,
  # unresolved,routing,role,claimed,terminal,multiproject,duplicate,thin,
  # decomp,draft-edit,reseed,exists} — one per refusal class of
  # contracts/seed-cli-contract.md §8, closing FR-039's per-class obligation
  # and SC-006's "14 of 14" (172 -> 186).
  # 027 (Convergence, T160) adds one: us027-safe-hierarchy — FR-014's
  # non-default hierarchy (SAFe-shaped roles: Capability/Feature) binding a
  # parent and a story, proven byte-identical across ports (186 -> 187).
  # 027 (Convergence, T161) adds one: us027-team-managed — FR-014's "identical
  # for team-managed and company-managed" binding a parent and a story on a
  # team_managed project, proven byte-identical across ports (187 -> 188).
  # 028 adds two: us028-template-form-ac (T016, FR-017/SC-007's two-run
  # cross-port proof for the template's own emphasised single-line and
  # wrapped Given/When/Then forms) and us028-template-form-ac-dry-run (T028,
  # FR-019's dry-run sibling) (188 -> 190).
  # 029 (Phase 3, T024) adds three: us29-feature-reuse-question (the reuse
  # question itself, bare key), us29-feature-reuse-question-url (the same
  # via a /browse/ URL, mention-grammar §4), and us29-feature-reuse-no
  # (FR-010's byte-identical answered path) (190 -> 193).
  # 029 (Phase 4-7, per-row conformance, T034/T058/T099) adds seven more
  # contract §2 rows this count fell behind on: us29-feature-reuse-invalid
  # (row 1), us29-feature-reuse-unposed (row 2),
  # us29-feature-reuse-no-contradicts-designator (row 3),
  # us29-feature-unresolvable-mention (row 6),
  # us29-feature-accept-defaults-suppresses (row 8),
  # us29-feature-reuse-yes-auto-accept (row 9/US3 AC1), and
  # us29-feature-reuse-yes-no-issues (row 11) (193 -> 200).
  # 029 (Phase 9, T068's per-row audit) closes the last two rows the sweep
  # found unrepresented — a per-command unit test is not the same obligation
  # as a cross-port byte-equality scenario: us29-feature-mention-with-designator
  # (row 7, mention plus designator together — the designator path wins, no
  # question) and us29-feature-designator-reuse-yes-silent (row 5, a
  # designator-only run with the redundant --reuse yes, accepted in silence)
  # (200 -> 202).
  # 029 (Phase 9, T105/SC-002) adds the headline outcome's own multi-run
  # proof — us29-sc002-reuse-chain: question, --reuse yes auto-accept,
  # seed --confirm, reconcile --dry-run, asserting zero duplicate parents
  # across both ports (202 -> 203).
  # 029 (Phase 9, T120) adds the one proposal shape the audit still lacked:
  # us29-feature-reuse-question-mixed-roles — three detected issues in one
  # question, mixed roles (specification, story, unmapped story), one
  # bulkfetch (203 -> 204).
  # 029 (Phase 11, Convergence, T135) adds the two configuration-report
  # variants T042 recorded as delivered but which no scenario exercised —
  # every existing us29-*.json used a fixture carrying both a populated
  # teams: catalogue and a selection: us29-feature-us6-no-config-mention and
  # its no-mention counterpart (FR-026/FR-027/FR-028, missing config.yml),
  # plus us29-feature-us6-noselect-mention (a catalogue with no selection —
  # its no-mention counterpart was already covered, pre-029, by
  # us3-feature-no-team.json) (204 -> 207).
  # 029 (Phase 11, Convergence, T137) completes T120's proposal-shape set
  # with the one it still lacked: us29-feature-reuse-question-story-only — a
  # story-role issue and no specification-role issue, proving the first
  # question carries the three parent routes rather than posing a second one
  # (FR-038, FR-040) (207 -> 208).
  # 029 (PR review) adds one: us29-feature-reuse-yes-no-issues-multi — the
  # which-issues follow-up on a THREE-key request, pinning contract §3.1's
  # "carries the identical object" cross-port after the fallback was found
  # rebuilding it from the leading key alone (FR-034) (208 -> 209).
  # 030 adds twenty-two: the two-rung credential chain (nothing declared,
  # command absent, non-zero exit, timeout, empty output, env-wins,
  # .env-inert, ceremony-reports), base_url/email now in tracked
  # config.yml (settings-from-files, settings-env-wins, base-url-malformed,
  # email-malformed, settings-missing-both, the C5.4 guard-not-a-hole
  # cross-check table), personal.yml's team-optional ceremony (created,
  # no-teams, created-then-loads, unchanged, dry-run, degraded,
  # idempotent), and the unattended env-only path (209 -> 231).
  # 031 adds five: a config.yml and a personal.yml that each exist but fail
  # to load (config-unloadable, personal-unloadable), a valid zero-team
  # catalogue's silence (zero-team-catalogue), and path resolution's two
  # divergence-surface cases (nested-invocation, no-project) (231 -> 236).
  count="$(find "${SCENARIOS_DIR}" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
  [ "${count}" -eq 236 ]
}

# Everything the conformance job declares, as one block.
conformance_job() {
  awk '
    /^  conformance:/ { on = 1; next }
    on && /^  [a-z-]+:$/ { on = 0 }
    on
  ' "${CI_YML}"
}

@test "the corpus runs on all three OSes (FR-019, SC-011)" {
  # The corpus moved out of `unit` into its own sharded job. What must not
  # move is the rule: every OS this extension ships for proves the whole
  # corpus, because a path-separator or line-ending divergence only that host
  # can expose is exactly what a single-OS run cannot catch.
  os_line="$(conformance_job | grep -E '^ +os: \[')"
  [[ "${os_line}" == *"ubuntu-latest"* ]]
  [[ "${os_line}" == *"macos-latest"* ]]
  [[ "${os_line}" == *"windows-latest"* ]]
}

@test "the shards tile the corpus exactly once per OS (FR-018)" {
  # Decision 7 permits sharding WITHIN one OS and forbids spreading scenarios
  # ACROSS the three. `os` and `shard` must therefore be INDEPENDENT matrix
  # axes — every OS runs every shard — and the shard count must equal the
  # declared total, or each OS would run part of the corpus and no host would
  # prove all of it.
  shard_line="$(conformance_job | grep -E '^ +shard: \[')"
  declared="$(conformance_job | grep -E 'SPEC_KIT_JIRA_SHARD_TOTAL:' | tr -dc '0-9')"
  indices="$(printf '%s' "${shard_line#*[}" | tr -d ' ]' | tr ',' '\n' | grep -c .)"
  [ -n "${declared}" ]
  [ "${indices}" -eq "${declared}" ]
  # A cross-OS split would key the index off the OS instead of its own axis.
  [[ "$(conformance_job | grep -E 'SPEC_KIT_JIRA_SHARD_INDEX:')" == *'matrix.shard'* ]]
}

@test "no OS is excluded from the corpus by a step condition (SC-011)" {
  run awk '
    /Run the conformance corpus/ { print; getline; print; getline; print }
  ' "${CI_YML}"
  [[ "${output}" != *"if:"* ]]
}

@test "windows-latest runs Pester unconditionally in the unit job (SC-011/FR-019)" {
  run awk '
    /Run Pester/ { print; getline; print; getline; print }
  ' "${CI_YML}"
  [[ "${output}" != *"runner.os != .Windows."* ]]
  [[ "${output}" != *"if:"* ]]
}

@test "the unit job no longer carries the corpus (it would run it a second time)" {
  # Leaving the step behind in `unit` would restore the very cost this split
  # removes, and windows-latest would still spend hours on it.
  run awk '
    /^  unit:/ { on = 1; next }
    on && /^  [a-z-]+:$/ { on = 0 }
    on && /ci-conformance\.sh/ { print }
  ' "${CI_YML}"
  [ -z "${output}" ]
}
