#!/usr/bin/env bats
# T078 [US2] — The no-heuristic guarantee (003 FR-012, US2 AS-5).
#
# FR-012 forbids any similarity, order, recency or issue-type path from EXISTING
# in any code path — not merely from being reached. Two tickets whose titles
# match the spec's exactly still refuse; permuting the candidate order, the
# apparent recency (key number) and the issue type changes nothing.
#
# The structural half of the guarantee is asserted too: the classifier is fed
# candidates carrying titles, dates and types, and its output is byte-identical
# to the same run with those fields absent — it cannot be reading them.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/adoption.sh"
  PREFIX="speckit-adopt:"
  CFG='{"routing_default":"ADO"}'
  REPO="acme/app"
  SPECS='[{"folder":"003-label-based-adoption","story_ordinals":[]}]'
  LABEL="speckit-adopt:003-label-based-adoption"
}

classify() {
  adoption_classify "$(adoption_targets "${SPECS}" "${PREFIX}" "${CFG}")" "$1" '[]' "${REPO}"
}

# two_candidates <extraA-json> <extraB-json> — two equally labelled candidates,
# each merged with the given extra fields.
two_candidates() {
  local a="$1" b="$2"
  [ -z "${a}" ] && a='{}'
  [ -z "${b}" ] && b='{}'
  jq -cn --argjson a "${a}" --argjson b "${b}" --arg l "${LABEL}" '
    [ ({key:"ADO-2", project_key:"ADO", labels:[$l], parent_key:null, identity:null} + $a),
      ({key:"ADO-9", project_key:"ADO", labels:[$l], parent_key:null, identity:null} + $b) ]'
}

@test "two candidates whose titles match the spec's title EXACTLY still refuse" {
  local cands
  cands="$(two_candidates \
    '{"summary":"Label-Based Adoption"}' \
    '{"summary":"Label-Based Adoption"}')"
  run classify "${cands}"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.refusals[0].reason' <<< "$output")" = "several-candidates" ]
}

@test "one exact title match and one unrelated title STILL refuses — no tie-break" {
  local cands
  cands="$(two_candidates \
    '{"summary":"Label-Based Adoption"}' \
    '{"summary":"Something else entirely"}')"
  run classify "${cands}"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.refusals[0].reason' <<< "$output")" = "several-candidates" ]
}

@test "permuting the candidate ORDER changes nothing (FR-012)" {
  local forward reverse a b
  forward="$(two_candidates)"
  reverse="$(jq -c 'reverse' <<< "${forward}")"
  a="$(classify "${forward}")"
  b="$(classify "${reverse}")"
  [ "$a" = "$b" ]
  [ "$(jq -r '.refusals[0].reason' <<< "$a")" = "several-candidates" ]
}

@test "permuting apparent RECENCY changes nothing (FR-012)" {
  local older newer a b
  older="$(two_candidates '{"created":"2019-01-01"}' '{"created":"2026-01-01"}')"
  newer="$(two_candidates '{"created":"2026-01-01"}' '{"created":"2019-01-01"}')"
  a="$(classify "${older}")"
  b="$(classify "${newer}")"
  [ "$a" = "$b" ]
  [ "$(jq -r '.bindings | length' <<< "$a")" -eq 0 ]
}

@test "permuting the ISSUE TYPE changes nothing (FR-012)" {
  local epic_first story_first a b
  epic_first="$(two_candidates '{"issuetype":"Epic"}' '{"issuetype":"Story"}')"
  story_first="$(two_candidates '{"issuetype":"Story"}' '{"issuetype":"Epic"}')"
  a="$(classify "${epic_first}")"
  b="$(classify "${story_first}")"
  [ "$a" = "$b" ]
  [ "$(jq -r '.bindings | length' <<< "$a")" -eq 0 ]
}

@test "titles, dates and types are not read AT ALL — the plan is byte-identical without them" {
  # Structural: enriching the candidates with every field a heuristic could use
  # must not move a single byte of the plan.
  local bare rich
  bare="$(classify "$(two_candidates)")"
  rich="$(classify "$(two_candidates \
    '{"summary":"Label-Based Adoption","created":"2026-07-27","issuetype":"Epic","status":"In Progress"}' \
    '{"summary":"Label-Based Adoption","created":"2019-01-01","issuetype":"Story","status":"Done"}')")"
  [ "$bare" = "$rich" ]
}

@test "a SINGLE candidate binds regardless of how unlike the spec its title is" {
  # The converse guard: the binding signal is the label, so an unrelated title
  # never withholds a binding either.
  local cands
  cands="$(jq -cn --arg l "${LABEL}" \
    '[{key:"ADO-1", project_key:"ADO", labels:[$l], parent_key:null, identity:null, summary:"zzz unrelated"}]')"
  run classify "${cands}"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.bindings[0].reason' <<< "$output")" = "label-match" ]
}

@test "the engine source carries no similarity, recency or issue-type vocabulary" {
  # FR-012 forbids such a path from EXISTING, so the modules are grepped for the
  # vocabulary any implementation of one would need. COMMENTS are excluded: the
  # header documents the prohibition and necessarily names what is prohibited.
  local pattern='summary|\btitle\b|similar|fuzzy|levenshtein|score|recen|issuetype|issue_type|sort_by\(\.created'
  # `strip` drops `#` comment lines and PowerShell `<# … #>` help blocks.
  local strip="awk '/<#/{c=1} !c && \$0 !~ /^[[:space:]]*#/ {print} /#>/{c=0}'"
  run bash -c "${strip} '${ROOT}/scripts/bash/engine/adoption.sh' | grep -icE '${pattern}'"
  [ "$output" = "0" ]
  run bash -c "${strip} '${ROOT}/scripts/powershell/engine/Adoption.psm1' | grep -icE '${pattern}'"
  [ "$output" = "0" ]
}

@test "the plan's binding reason enum has exactly two members (data-model §7.1)" {
  # There is no third value, because there is no third way a candidate is chosen.
  local cands
  cands="$(jq -cn --arg l "${LABEL}" \
    '[{key:"ADO-1", project_key:"ADO", labels:[$l], parent_key:null, identity:null}]')"
  run classify "${cands}"
  local reason
  reason="$(jq -r '.bindings[0].reason' <<< "$output")"
  [[ "${reason}" == "label-match" || "${reason}" == "explicit-binding" ]]
}
