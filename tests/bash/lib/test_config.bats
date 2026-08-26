#!/usr/bin/env bats
# T028 [US4] — Config storage layer: two-layer load/merge, schema validation,
# credential-shape rejection (FR-023, exit 4), and the single-source version
# reader (FR-021/022, SC-006).
#
# The config files are YAML but no `yq` is available at runtime (deps are
# curl/jq/git), so lib/config.sh parses the controlled config subset itself.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  PS_LIB="${ROOT}/scripts/powershell/lib"
  EXT_YML="${ROOT}/extension.yml"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${DIR}"
}

# Write a minimal valid team config.yml into $DIR.
write_valid_team() {
  cat > "${DIR}/config.yml" <<'YAML'
# Team config (committable, credential-free).
projects:
  - key: PROJ
    style: company_managed
    issue_types:
      Epic: "10001"
      Story: "10002"
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "billing-"
    project: PROJ
routing_default: PROJ
privacy:
  allowlist:
    - support.example.atlassian.net
YAML
}

# --- Version single-source (T032) -------------------------------------------

@test "config_extension_version reads the version field from extension.yml" {
  run config_extension_version
  [ "$status" -eq 0 ]
  # Must equal the literal in extension.yml — the single source of truth.
  expected="$(grep -E '^[[:space:]]+version:' "${EXT_YML}" | head -n1 | sed -E 's/^[[:space:]]+version:[[:space:]]*//')"
  [ "$output" = "${expected}" ]
}

@test "config_assert_single_version_source rejects a stray version marker (FR-022)" {
  mkdir -p "${DIR}"
  printf '0.9.9\n' > "${DIR}/VERSION"
  JIRA_CONFIG_DIR="${DIR}" run config_assert_single_version_source
  [ "$status" -eq 4 ]
  [[ "$output" == *"VERSION"* ]]
}

@test "config_assert_single_version_source passes when no stray marker exists" {
  JIRA_CONFIG_DIR="${DIR}" run config_assert_single_version_source
  [ "$status" -eq 0 ]
}

# --- YAML subset parsing -----------------------------------------------------

@test "config_yaml_to_json parses mappings, sequences, and quoted scalars" {
  write_valid_team
  json="$(config_yaml_to_json "${DIR}/config.yml")"
  [ "$(printf '%s' "${json}" | jq -r '.routing_default')" = "PROJ" ]
  [ "$(printf '%s' "${json}" | jq -r '.projects[0].style')" = "company_managed" ]
  [ "$(printf '%s' "${json}" | jq -r '.projects[0].issue_types.Epic')" = "10001" ]
  [ "$(printf '%s' "${json}" | jq -r '.projects[0].priority_map.P2')" = "Medium" ]
  [ "$(printf '%s' "${json}" | jq -r '.routing[0].match.folder_prefix')" = "billing-" ]
  [ "$(printf '%s' "${json}" | jq -r '.privacy.allowlist[0]')" = "support.example.atlassian.net" ]
}

@test "config_yaml_to_json coerces true/false to JSON booleans" {
  cat > "${DIR}/c.yml" <<'YAML'
generation:
  design_section: false
YAML
  json="$(config_yaml_to_json "${DIR}/c.yml")"
  [ "$(printf '%s' "${json}" | jq -r '.generation.design_section')" = "false" ]
  [ "$(printf '%s' "${json}" | jq -r '.generation.design_section | type')" = "boolean" ]
}

# --- Unicode and punctuated mapping keys (007, contracts/yaml-key-grammar.md) -

@test "the bug report's own document round-trips whole (007 FR-002, FR-004)" {
  local input='{"resolved_ids":{"JET":{
    "issue_types":{"Récit":"10004","Story":"10005"},
    "priorities":{"Faible":"4","Élevée":"1"},
    "statuses":{"Terminé":"10002","Won'\''t Do":"10004","À faire":"10001","完了":"10003"},
    "style":"company_managed"}}}'
  printf '%s' "${input}" | config_to_yaml > "${DIR}/rt.yml"
  local back
  back="$(config_yaml_to_json "${DIR}/rt.yml")"
  [ "$(jq -cS . <<< "${input}")" = "$(jq -cS . <<< "${back}")" ]
}

@test "keys in four different scripts read back bare (007 FR-002)" {
  printf '%s\n' \
    'Größe: "3"' \
    'Приоритет: "2"' \
    '完了: "10003"' \
    'Done (QA): "10005"' \
    'high/low: "6"' \
    > "${DIR}/scripts.yml"
  json="$(config_yaml_to_json "${DIR}/scripts.yml")"
  [ "$(jq -r '.["Größe"]' <<< "${json}")" = "3" ]
  [ "$(jq -r '.["Приоритет"]' <<< "${json}")" = "2" ]
  [ "$(jq -r '.["完了"]' <<< "${json}")" = "10003" ]
  [ "$(jq -r '.["Done (QA)"]' <<< "${json}")" = "10005" ]
  [ "$(jq -r '.["high/low"]' <<< "${json}")" = "6" ]
}

@test "a bare apostrophe key still parses (guards the non-quote-aware bare scan, 007 R1)" {
  printf '%s\n' "Won't Do: \"7\"" > "${DIR}/apos.yml"
  json="$(config_yaml_to_json "${DIR}/apos.yml")"
  [ "$(jq -r ".[\"Won't Do\"]" <<< "${json}")" = "7" ]
}

@test "a bare URL value is still a scalar, not a key (007 FR-003)" {
  printf 'site: https://example.atlassian.net\n' > "${DIR}/url.yml"
  json="$(config_yaml_to_json "${DIR}/url.yml")"
  [ "$(jq -r '.site' <<< "${json}")" = "https://example.atlassian.net" ]
}

@test "keys requiring writer quoting survive the write-read round trip (007 FR-004, FR-005)" {
  local input='{"a":{"Blocked: waiting on QA":"5","Sprint # 2":"6","- pending":"7","  padded  ":"8"}}'
  printf '%s' "${input}" | config_to_yaml > "${DIR}/quoted.yml"
  local back
  back="$(config_yaml_to_json "${DIR}/quoted.yml")"
  [ "$(jq -cS . <<< "${input}")" = "$(jq -cS . <<< "${back}")" ]
}

@test "every emitted key is double-quoted (007 contract yaml-key-grammar.md §2.1)" {
  printf '%s' '{"a":{"Élevée":"1"}}' | config_to_yaml > "${DIR}/emitted.yml"
  grep -q '"Élevée": "1"' "${DIR}/emitted.yml"
}

# --- The writer against a text-mode jq (Windows) -----------------------------
#
# On Windows the `jq` on PATH is the native jq.exe and its stdout is a text-mode
# stream: every `\n` it writes leaves the process as CRLF. config_to_yaml is the
# port's largest MULTI-LINE jq read and the only one whose bytes land in a file
# the operator keeps, so it is where that CR was first seen: the Bash port wrote
# config.local.yml CRLF-terminated while the PowerShell twin — which joins with
# an explicit `n and writes through File::WriteAllText — wrote LF, and
# ci-conformance.sh failed the written-files diff on windows-latest only.
#
# A POSIX host cannot reproduce a text-mode stream natively, so it is supplied
# by a stub `jq` on PATH — the real jq with a CR appended to each output line,
# the same faithful emulation tests/bash/conformance/test_run_scenario_crlf_jq.bats
# uses for the harness's own reads.
@test "the writer emits LF line endings even when jq's stdout is text-mode (Windows)" {
  local stub="${DIR}/stub"
  mkdir -p "${stub}"
  # `command jq` inside the stub would re-enter it, so resolve the real binary
  # by path here, BEFORE the stub shadows the name.
  cat > "${stub}/jq" << EOF
#!/usr/bin/env bash
set -o pipefail
"$(command -v jq)" "\$@" | sed \$'s/\$/\\r/'
EOF
  chmod +x "${stub}/jq"

  local input='{"resolved_ids":{"COMP":{"style":"company_managed","style_source":"api"}}}'
  # Two things this subshell has to get right, and both bite silently.
  # `hash -r`: an earlier test in this file has already run jq, and the
  # inherited hash table would resolve the name straight to the real binary.
  # Re-sourcing output.sh: its guard is installed by PROBING jq at source time,
  # and setup() sourced it while the real jq was still the one on PATH — a
  # process that starts with a text-mode jq, which is the Windows case, probes
  # the stub and installs it.
  ( PATH="${stub}:${PATH}"; hash -r
    unset _JIRA_LIB_OUTPUT; source "${LIB_DIR}/output.sh"
    printf '%s' "${input}" | config_to_yaml ) > "${DIR}/crlf.yml"

  # The written bytes are the contract (NFR-1): not one CR anywhere. Counted
  # rather than `! grep -q`, which `set -e` ignores by rule — a negated pipeline
  # cannot fail a bats test, and this assertion has to.
  local crs
  crs="$(LC_ALL=C tr -dc '\r' < "${DIR}/crlf.yml" | wc -c | tr -d '[:space:]')"
  [ "${crs}" -eq 0 ]
  # And stripping it cost the document nothing.
  [ "$(jq -cS . <<< "${input}")" = "$(jq -cS . <<< "$(config_yaml_to_json "${DIR}/crlf.yml")")" ]
}

# --- Escape decoding (013, contracts/yaml-string-escaping.md §2) ------------

@test "a quoted-legacy escaped sequence item decodes to the label with an embedded quote (013 contract §2.4)" {
  cat > "${DIR}/a.yml" <<'EOF'
allowed:
  - "Platform \"legacy\""
EOF
  json="$(config_yaml_to_json "${DIR}/a.yml")"
  [ "$(jq -r '.allowed[0]' <<< "${json}")" = 'Platform "legacy"' ]
}

@test "a double backslash in a quoted scalar decodes to one backslash (013 contract §2.4)" {
  cat > "${DIR}/b.yml" <<'EOF'
k: "Delivery\\Platform"
EOF
  json="$(config_yaml_to_json "${DIR}/b.yml")"
  [ "$(jq -r '.k' <<< "${json}")" = 'Delivery\Platform' ]
}

@test "a trailing escaped backslash does not swallow the closing delimiter (013 contract §2.1 rule 2)" {
  cat > "${DIR}/c.yml" <<'EOF'
allowed:
  - "trailing\\"
  - "second"
EOF
  json="$(config_yaml_to_json "${DIR}/c.yml")"
  [ "$(jq -r '.allowed[0]' <<< "${json}")" = 'trailing\' ]
  [ "$(jq -r '.allowed[1]' <<< "${json}")" = 'second' ]
}

@test "an escaped backslash followed by an escaped quote decodes to backslash-quote, two characters (013 contract §2.4)" {
  cat > "${DIR}/d.yml" <<'EOF'
k: "\\\""
EOF
  json="$(config_yaml_to_json "${DIR}/d.yml")"
  [ "$(jq -r '.k' <<< "${json}")" = '\"' ]
}

@test "the escaped form decodes identically as a sequence item and as a mapping value (013 contract §2.4)" {
  cat > "${DIR}/e.yml" <<'EOF'
seq:
  - "Platform \"legacy\""
val: "Platform \"legacy\""
EOF
  json="$(config_yaml_to_json "${DIR}/e.yml")"
  [ "$(jq -r '.seq[0]' <<< "${json}")" = "$(jq -r '.val' <<< "${json}")" ]
  [ "$(jq -r '.val' <<< "${json}")" = 'Platform "legacy"' ]
}

@test "an escaped quote inside a double-quoted scalar does not end the string at a following # (013 FR-011)" {
  cat > "${DIR}/tricky.yml" <<'EOF'
tricky: "a \" # b"
EOF
  json="$(config_yaml_to_json "${DIR}/tricky.yml")"
  [ "$(jq -r '.tricky' <<< "${json}")" = 'a " # b' ]
}

@test "an escaped quote inside a quoted key is decoded, not treated as the closing delimiter (013 FR-010, contract §2.3)" {
  cat > "${DIR}/key.yml" <<'EOF'
"say \"x\"": v
EOF
  json="$(config_yaml_to_json "${DIR}/key.yml")"
  [ "$(jq -r 'keys[0]' <<< "${json}")" = 'say "x"' ]
  [ "$(jq -r '.[keys[0]]' <<< "${json}")" = "v" ]
}

# --- Escape encoding (013, contracts/yaml-string-escaping.md §1) -----------

@test "a value with an embedded double quote is emitted with the exact escaped bytes (013 contract §1.3)" {
  local out
  out="$(printf '%s' '{"k":"Platform \"legacy\""}' | config_to_yaml)"
  [[ "${out}" == *'"k": "Platform \"legacy\""'* ]]
}

@test "a value with a single backslash is emitted doubled (013 contract §1.3)" {
  local out
  out="$(printf '%s' '{"k":"Delivery\\Platform"}' | config_to_yaml)"
  [[ "${out}" == *'"k": "Delivery\\Platform"'* ]]
}

@test "a value with both a quote and a backslash is emitted backslash-first (013 contract §1.1, §1.3)" {
  local out
  out="$(printf '%s' '{"k":"Group \"A\\B\""}' | config_to_yaml)"
  [[ "${out}" == *'"k": "Group \"A\\B\""'* ]]
}

@test "a value that is exactly backslash-quote round-trips without double-escaping (013 contract §1.3)" {
  local out
  out="$(printf '%s' '{"k":"\\\""}' | config_to_yaml)"
  [[ "${out}" == *'"k": "\\\""'* ]]
}

@test "a value with neither character is emitted byte-identically to before this feature (013 contract §1.3)" {
  local out
  out="$(printf '%s' '{"k":"clean"}' | config_to_yaml)"
  [[ "${out}" == *'"k": "clean"'* ]]
}

@test "a mapping key containing a double quote is emitted escaped and reads back identical (013 FR-010, FR-014)" {
  local out
  out="$(printf '%s' '{"say \"hi\"":"1"}' | config_to_yaml)"
  [[ "${out}" == *'"say \"hi\""'* ]]
  printf '%s' "${out}" > "${DIR}/qkey.yml"
  local json
  json="$(config_yaml_to_json "${DIR}/qkey.yml")"
  [ "$(jq -r 'keys[0]' <<< "${json}")" = 'say "hi"' ]
}

# --- Compatibility guards: must stay green throughout (013 FR-012/013, 007 R1, 013 research R2) -

@test "an unrecognised backslash escape stays literal, both backslashes kept (013 FR-012)" {
  cat > "${DIR}/path.yml" <<'EOF'
path: "C:\Users\shared"
EOF
  json="$(config_yaml_to_json "${DIR}/path.yml")"
  [ "$(jq -r '.path' <<< "${json}")" = 'C:\Users\shared' ]
}

@test "a single-quoted scalar is never decoded (013 FR-013, contract §2.2)" {
  cat > "${DIR}/single.yml" <<'EOF'
single: 'a\"b'
EOF
  json="$(config_yaml_to_json "${DIR}/single.yml")"
  [ "$(jq -r '.single' <<< "${json}")" = 'a\"b' ]
}

@test "a bare apostrophe key still parses, guarding the non-escape-aware bare scan (007 research R1)" {
  cat > "${DIR}/apos.yml" <<'EOF'
Won't Do: "10004"
EOF
  json="$(config_yaml_to_json "${DIR}/apos.yml")"
  [ "$(jq -r 'keys[0]' <<< "${json}")" = "Won't Do" ]
  [ "$(jq -r '.[keys[0]]' <<< "${json}")" = "10004" ]
}

@test "a literal TAB inside a quoted scalar round-trips unchanged (013 research R2)" {
  printf 'k: "a\tb"\n' > "${DIR}/tab.yml"
  json="$(config_yaml_to_json "${DIR}/tab.yml")"
  [ "$(jq -r '.k' <<< "${json}")" = "$(printf 'a\tb')" ]
}

# --- Privacy guard: must stay green throughout (013 FR-024, Constitution IX) -

@test "a malformed line with an escaped quote before a credential-shaped token is still redacted (013 FR-024)" {
  cat > "${DIR}/leak2.yml" <<'EOF'
resolved_ids:
  JET:
    bad "a \" # ATATT3xFfGF0secrettoken
EOF
  local status=0
  config_yaml_to_json "${DIR}/leak2.yml" 2> "${DIR}/err2.txt" > /dev/null || status=$?
  [ "$status" -eq 4 ]
  local firstline
  firstline="$(sed -n 1p "${DIR}/err2.txt")"
  [[ "${firstline}" != *"ATATT3xFfGF0secrettoken"* ]]
  [ "$(grep -c '\[redacted\]' <<< "${firstline}")" -ge 1 ]
}

@test "a key containing a double quote is written and round-trips (013 contract §1, was: refused on write, 007 research R3)" {
  local out status=0
  out="$(printf '%s' '{"a":{"say \"hi\"":"1"}}' | config_to_yaml)" || status=$?
  [ "$status" -eq 0 ]
  [[ "$out" == *'"say \"hi\""'* ]]
  printf '%s' "${out}" > "${DIR}/key.yml"
  local json
  json="$(config_yaml_to_json "${DIR}/key.yml")"
  [ "$(jq -r '.a | keys[0]' <<< "${json}")" = 'say "hi"' ]
}

@test "a string value containing a double quote is written and round-trips (013 contract §1, was: refused on write, 007 research R3)" {
  local out status=0
  out="$(printf '%s' '{"a":{"k":"say \"hi\""}}' | config_to_yaml)" || status=$?
  [ "$status" -eq 0 ]
  [[ "$out" == *'"say \"hi\""'* ]]
  printf '%s' "${out}" > "${DIR}/val.yml"
  local json
  json="$(config_yaml_to_json "${DIR}/val.yml")"
  [ "$(jq -r '.a.k' <<< "${json}")" = 'say "hi"' ]
}

# --- Round-trip corpus (013, User Story 2, T030) ----------------------------

@test "a run of consecutive backslashes is preserved in count after a round trip (013 FR-006, edge case)" {
  local raw='a\\\b'
  local json out decoded
  json="$(jq -n --arg v "${raw}" '{k:$v}')"
  out="$(printf '%s' "${json}" | config_to_yaml)"
  printf '%s' "${out}" > "${DIR}/backslashes.yml"
  decoded="$(config_yaml_to_json "${DIR}/backslashes.yml" | jq -r '.k')"
  [ "${decoded}" = "${raw}" ]
}

@test "a quote adjacent to the delimiter round-trips as literal content (013 edge case)" {
  local raw='"quoted"'
  local json out decoded
  json="$(jq -n --arg v "${raw}" '{k:$v}')"
  out="$(printf '%s' "${json}" | config_to_yaml)"
  printf '%s' "${out}" > "${DIR}/adjacent.yml"
  decoded="$(config_yaml_to_json "${DIR}/adjacent.yml" | jq -r '.k')"
  [ "${decoded}" = "${raw}" ]
}

@test "a quoted and an unquoted variant of a label stay distinct values after a round trip (013 FR-006 invariant I5)" {
  local rawA='Platform "legacy"'
  local rawB='Platform legacy'
  local json out decoded
  json="$(jq -n --arg a "${rawA}" --arg b "${rawB}" '{a:$a,b:$b}')"
  out="$(printf '%s' "${json}" | config_to_yaml)"
  printf '%s' "${out}" > "${DIR}/distinct.yml"
  decoded="$(config_yaml_to_json "${DIR}/distinct.yml")"
  [ "$(jq -r '.a' <<< "${decoded}")" = "${rawA}" ]
  [ "$(jq -r '.b' <<< "${decoded}")" = "${rawB}" ]
  [ "$(jq -r '.a' <<< "${decoded}")" != "$(jq -r '.b' <<< "${decoded}")" ]
}

# --- Determinism (013 FR-017, quickstart Scenario 5, T034) ------------------

@test "write, read, write yields a byte-identical file for a document holding a quoted label (013 FR-017, quickstart Scenario 5)" {
  local json='{"k":"Platform \"legacy\""}'
  local out1 out2 decoded
  out1="$(printf '%s' "${json}" | config_to_yaml)"
  printf '%s' "${out1}" > "${DIR}/det.yml"
  decoded="$(config_yaml_to_json "${DIR}/det.yml")"
  out2="$(printf '%s' "${decoded}" | config_to_yaml)"
  [ "${out1}" = "${out2}" ]
}

# --- Wedged-configuration recovery (013 US3, quickstart Scenario 1, T036) --

@test "a pre-seeded file already holding the escaped form loads and rewrites byte-identically (013 US3, quickstart Scenario 1)" {
  cat > "${DIR}/wedged.yml" <<'EOF'
"allowed":
  - "Platform \"legacy\""
EOF
  local json
  json="$(config_yaml_to_json "${DIR}/wedged.yml")"
  [ "$(jq -r '.allowed[0]' <<< "${json}")" = 'Platform "legacy"' ]
  local rewritten
  rewritten="$(printf '%s' "${json}" | config_to_yaml)"
  [ "${rewritten}" = "$(cat "${DIR}/wedged.yml")" ]
}

# --- Line-break refusal (013 FR-020, contract §1.4, §4) ---------------------

@test "a string value containing a line break (LF) is refused at exit 4, nothing written, value never printed (013 FR-020)" {
  local out status=0
  out="$(printf '%s' '{"k":"before\nafter"}' | config_to_yaml 2>"${DIR}/err.txt")" || status=$?
  [ "$status" -eq 4 ]
  [ -z "$out" ]
  local err
  err="$(cat "${DIR}/err.txt")"
  [[ "$err" == *"k"* ]]
  [[ "$err" != *"before"* ]]
  [[ "$err" != *"after"* ]]
}

@test "a string value containing a bare CR is refused at exit 4 (013 FR-020, contract §4)" {
  local out status=0
  out="$(printf '%s' '{"k":"before\rafter"}' | config_to_yaml 2>"${DIR}/err.txt")" || status=$?
  [ "$status" -eq 4 ]
  [ -z "$out" ]
  local err
  err="$(cat "${DIR}/err.txt")"
  [[ "$err" == *"k"* ]]
  [[ "$err" != *"before"* ]]
  [[ "$err" != *"after"* ]]
}

@test "a document with two unrepresentable paths reports both, deduplicated and in the same order (013 US4, research R5)" {
  local out status=0
  out="$(printf '%s' '{"a":"before\nafter","b":"before\nafter"}' | config_to_yaml 2>"${DIR}/err.txt")" || status=$?
  [ "$status" -eq 4 ]
  [ -z "$out" ]
  [ "$(sed -n 1p "${DIR}/err.txt")" = 'config: a: a string value here contains a line break, which this writer cannot represent' ]
  [ "$(sed -n 2p "${DIR}/err.txt")" = 'config: b: a string value here contains a line break, which this writer cannot represent' ]
  [ "$(wc -l < "${DIR}/err.txt" | tr -d ' ')" = "2" ]
}

@test "two-path refusal listing orders ordinally, not culture-sensitively (013 FR-023, contract §4)" {
  local out status=0
  out="$(printf '%s' '{"Won'"'"'t Do":"before\nafter","Won-t Do":"before\nafter"}' | config_to_yaml 2>"${DIR}/err.txt")" || status=$?
  [ "$status" -eq 4 ]
  [ -z "$out" ]
  [ "$(sed -n 1p "${DIR}/err.txt")" = "config: Won't Do: a string value here contains a line break, which this writer cannot represent" ]
  [ "$(sed -n 2p "${DIR}/err.txt")" = 'config: Won-t Do: a string value here contains a line break, which this writer cannot represent' ]
  [ "$(wc -l < "${DIR}/err.txt" | tr -d ' ')" = "2" ]
}

# --- Fail-closed on a line that cannot be interpreted (007, contracts/parse-failure.md) -

@test "a malformed line fails closed with the exact three-line message (007 FR-007 to FR-009)" {
  printf 'resolved_ids:\n  JET:\n    this line has no delimiter\n' > "${DIR}/bad.yml"
  local out status=0
  out="$(config_yaml_to_json "${DIR}/bad.yml" 2>"${DIR}/err.txt")" || status=$?
  [ "$status" -eq 4 ]
  [ -z "$out" ]
  [ "$(sed -n 1p "${DIR}/err.txt")" = "config: ${DIR}/bad.yml:3: cannot parse this line as a mapping entry: this line has no delimiter" ]
  [ "$(sed -n 2p "${DIR}/err.txt")" = 'config: a key must be followed by ": " — quote the key if it contains a colon, e.g. "Blocked: waiting": "10001"' ]
  [ "$(sed -n 3p "${DIR}/err.txt")" = "config: re-run /speckit.jira.config to regenerate ${DIR}/bad.yml from the Jira instance." ]
  [ "$(wc -l < "${DIR}/err.txt" | tr -d ' ')" = "3" ]
}

@test "the reported line number counts blank and comment lines (007 FR-009)" {
  printf '# a comment\n\nresolved_ids:\n  JET:\n    broken\n' > "${DIR}/bad2.yml"
  local status=0
  config_yaml_to_json "${DIR}/bad2.yml" 2> "${DIR}/err.txt" > /dev/null || status=$?
  [ "$status" -eq 4 ]
  [[ "$(sed -n 1p "${DIR}/err.txt")" == *":5:"* ]]
}

@test "a '- jira' sequence item is not a parse failure (007 contract yaml-key-grammar.md §1.4)" {
  printf 'installed:\n- jira\n' > "${DIR}/seq.yml"
  local status=0
  json="$(config_yaml_to_json "${DIR}/seq.yml" 2>"${DIR}/err.txt")" || status=$?
  [ "$status" -eq 0 ]
  [ ! -s "${DIR}/err.txt" ]
  [ "$(jq -r '.installed[0]' <<< "${json}")" = "jira" ]
}

@test "a malformed line carrying credential-shaped content is redacted (007 FR-009, Constitution IV)" {
  printf 'resolved_ids:\n  JET:\n    ATATT3xFfGF0 someone@example.com https://acme.atlassian.net\n' > "${DIR}/leak.yml"
  local status=0
  config_yaml_to_json "${DIR}/leak.yml" 2> "${DIR}/err.txt" > /dev/null || status=$?
  [ "$status" -eq 4 ]
  local firstline
  firstline="$(sed -n 1p "${DIR}/err.txt")"
  [[ "${firstline}" == *"${DIR}/leak.yml:3:"* ]]
  [[ "${firstline}" != *"ATATT3xFfGF0"* ]]
  [[ "${firstline}" != *"someone@example.com"* ]]
  [[ "${firstline}" != *"acme.atlassian.net"* ]]
  [ "$(grep -c '\[redacted\]' <<< "${firstline}")" -ge 1 ]
}

@test "a key repeated at the same mapping level fails, naming both lines (007 FR-016)" {
  printf 'statuses:\n  "Terminé": "1"\n  "Terminé": "2"\n' > "${DIR}/dup.yml"
  local status=0
  config_yaml_to_json "${DIR}/dup.yml" 2> "${DIR}/err.txt" > /dev/null || status=$?
  [ "$status" -eq 4 ]
  local firstline
  firstline="$(sed -n 1p "${DIR}/err.txt")"
  [[ "${firstline}" == *"${DIR}/dup.yml:3:"* ]]
  [[ "${firstline}" == *"duplicate key"* ]]
  [[ "${firstline}" == *"line 2"* ]]
}

@test "the same key at two different mapping levels stays legal (007 yaml-key-grammar.md §1.5)" {
  printf 'resolved_ids:\n  COMP:\n    statuses:\n      "To Do": "1"\n  TEAM:\n    statuses:\n      "To Do": "2"\n' > "${DIR}/nodup.yml"
  json="$(config_yaml_to_json "${DIR}/nodup.yml")"
  [ "$(jq -r '.resolved_ids.COMP.statuses["To Do"]' <<< "${json}")" = "1" ]
  [ "$(jq -r '.resolved_ids.TEAM.statuses["To Do"]' <<< "${json}")" = "2" ]
}

# --- Valid load --------------------------------------------------------------

@test "config_load accepts a valid team config (exit 0) and emits merged JSON" {
  write_valid_team
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${output}" | jq -r '.routing_default')" = "PROJ" ]
}

@test "config_load merges config.local overrides over the team config" {
  write_valid_team
  cat > "${DIR}/config.local.yml" <<'YAML'
site_alias: prod
overrides:
  routing_default: OTHER
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${output}" | jq -r '.routing_default')" = "OTHER" ]
}

@test "config_load fails when config.yml is absent (exit 4)" {
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
}

@test "config_load keeps sibling projects when a local override touches only one" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
  - key: OPS
    style: team_managed
routing_default: PROJ
YAML
  cat > "${DIR}/config.local.yml" <<'YAML'
overrides:
  projects:
    - key: PROJ
      style: team_managed
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects | length' <<< "${output}")" -eq 2 ]
  [ "$(jq -r '.projects[0].key' <<< "${output}")" = "PROJ" ]
  [ "$(jq -r '.projects[0].style' <<< "${output}")" = "team_managed" ]
  [ "$(jq -r '.projects[1].key' <<< "${output}")" = "OPS" ]
}

# --- T006 [030] — _cfg_credential_errors with an exempt-path argument -------
# (data-model.md §4, contracts/connection-settings.md §5)

@test "T006 — a credential-shaped value at an exempt path passes" {
  local out
  out="$(printf '%s' '{"base_url":"someone@example.com"}' | _cfg_credential_errors base_url)"
  [ -z "${out}" ]
}

@test "T006 — every other path still refuses, even with an exempt path declared" {
  local out
  out="$(printf '%s' '{"other_key":"someone@example.com"}' | _cfg_credential_errors base_url)"
  [[ "${out}" == *"other_key: email address"* ]]
}

@test "T006 — privacy stays exempt unconditionally, independent of the exempt-path list" {
  local out
  out="$(printf '%s' '{"privacy":{"allowlist":["someone@example.com"]}}' | _cfg_credential_errors)"
  [ -z "${out}" ]
  out="$(printf '%s' '{"privacy":{"allowlist":["someone@example.com"]}}' | _cfg_credential_errors base_url)"
  [ -z "${out}" ]
}

@test "T006 — ^ATATT is refused even at an exempt path (C5.3, never exempted)" {
  local out
  out="$(printf '%s' '{"base_url":"ATATT3xFfGF0secrettoken"}' | _cfg_credential_errors base_url)"
  [[ "${out}" == *"base_url: Atlassian API token"* ]]
}

# --- Credential-shape rejection (FR-023, exit 4) -----------------------------

@test "config_load rejects an ATATT token shape in the team layer (exit 4)" {
  write_valid_team
  cat >> "${DIR}/config.yml" <<'YAML'
site_url: ATATT3xFfGF0secrettoken
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"credential"* ]]
  # The secret value itself is NEVER echoed (NFR-3).
  [[ "$output" != *"ATATT3xFfGF0secrettoken"* ]]
}

@test "config_load rejects a real *.atlassian.net host as a coordinate (exit 4)" {
  write_valid_team
  cat > "${DIR}/config.local.yml" <<'YAML'
overrides:
  site: acme.atlassian.net
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"credential"* ]]
}

@test "config_load rejects an email address shape (exit 4)" {
  write_valid_team
  cat >> "${DIR}/config.yml" <<'YAML'
owner: someone@example.com
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
}

@test "config_load does NOT scan privacy.allowlist for atlassian hosts (FR-053)" {
  # support.example.atlassian.net lives under privacy.allowlist in the valid
  # fixture; the allowlist is exempt from credential-shape scanning.
  write_valid_team
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

# --- T011 [030] — the whole base_url table (connection-settings.md §2.2,
# data-model.md §2/§2a) -------------------------------------------------------

@test "T011 — base_url accepts a bare https URL" {
  write_valid_team
  printf 'base_url: "https://team.atlassian.net"\n' >> "${DIR}/config.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

@test "T011 — base_url accepts http at the three loopback literals" {
  local literal
  for literal in "127.0.0.1" "localhost" "[::1]"; do
    write_valid_team
    printf 'base_url: "http://%s:4000"\n' "${literal}" >> "${DIR}/config.yml"
    JIRA_CONFIG_DIR="${DIR}" run config_load
    [ "$status" -eq 0 ]
    rm -f "${DIR}/config.yml"
  done
}

@test "T011 — base_url refuses a trailing slash" {
  write_valid_team
  printf 'base_url: "https://team.atlassian.net/"\n' >> "${DIR}/config.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"base_url is invalid"* ]]
}

@test "T011 — base_url refuses a path" {
  write_valid_team
  printf 'base_url: "https://team.atlassian.net/jira"\n' >> "${DIR}/config.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"base_url is invalid"* ]]
}

@test "T011 — base_url refuses a scheme-less host" {
  write_valid_team
  printf 'base_url: "team.atlassian.net"\n' >> "${DIR}/config.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"base_url is invalid"* ]]
}

@test "T011 — base_url refuses an empty declaration" {
  write_valid_team
  printf 'base_url: ""\n' >> "${DIR}/config.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"base_url is invalid"* ]]
}

@test "T011 — base_url refuses http to a non-loopback host" {
  write_valid_team
  printf 'base_url: "http://team.atlassian.net"\n' >> "${DIR}/config.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"base_url is invalid"* ]]
}

@test "T011 — base_url refuses http to a private-range address (not loopback)" {
  write_valid_team
  printf 'base_url: "http://192.168.1.10"\n' >> "${DIR}/config.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"base_url is invalid"* ]]
}

@test "T011 — an absent base_url is accepted" {
  write_valid_team
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

@test "T011 — C2.7: a malformed SPEC_KIT_JIRA_BASE_URL with no base_url in the file is passed through unvalidated" {
  write_valid_team
  export SPEC_KIT_JIRA_BASE_URL="not a url at all"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  unset SPEC_KIT_JIRA_BASE_URL
}

# --- Schema validation -------------------------------------------------------

@test "config_load rejects a missing routing_default (exit 4)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"routing_default"* ]]
}

@test "config_load rejects an invalid project style enum (exit 4)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: bespoke
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"style"* ]]
}

@test "config_load rejects a phase_status_map that is not a mapping to status names (exit 4, T074)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map: "not-a-mapping"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"phase_status_map"* ]]
}

@test "config_load accepts a valid phase_status_map and halted_statuses (T074)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
    halted_statuses:
      - "Blocked"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

@test "config_load rejects a halted_statuses that is neither a list nor a string (exit 4, T074)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    halted_statuses:
      count: 3
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"halted_statuses"* ]]
}

@test "config_load rejects an unknown top-level key (exit 4)" {
  write_valid_team
  cat >> "${DIR}/config.yml" <<'YAML'
mystery: value
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"unknown"* ]]
}

# --- T075/T088 [Phase 9] — the `hierarchy` schema (010, contracts/role-mapping.md §6.1, §2) ---

@test "T075 — projects[].hierarchy that is not an object refuses, exit 4" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    hierarchy: "Epic"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"projects[0].hierarchy must be a mapping of role to issue type name"* ]]
}

@test "T075 — an unknown role in projects[].hierarchy refuses, naming the closed role set" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    hierarchy:
      epic: Epic
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'projects[0].hierarchy declares unknown role `epic`; the roles are specification, story, task'* ]]
}

@test "T075 — an empty projects[].hierarchy.<role> value refuses (non-empty issue type name required)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    hierarchy:
      specification: ""
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"projects[0].hierarchy.specification must be a non-empty issue type name"* ]]
}

@test "T075 — a valid projects[].hierarchy declaration loads cleanly" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    hierarchy:
      specification: Epic
      story: Story
      task: "Sous-tâche"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

@test "T075 — a non-object resolved_ids.<KEY>.roles refuses, exit 4" {
  write_valid_team
  cat > "${DIR}/config.local.yml" <<'YAML'
resolved_ids:
  PROJ:
    roles: "Epic"
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"resolved_ids.PROJ.roles must be a mapping"* ]]
}

@test "T075 — an unknown role in resolved_ids.<KEY>.roles refuses, exit 4" {
  write_valid_team
  cat > "${DIR}/config.local.yml" <<'YAML'
resolved_ids:
  PROJ:
    roles:
      epic:
        logical_name: "Epic"
        id: "10001"
        hierarchy_level: "1"
        subtask: false
        source: declared
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'resolved_ids.PROJ.roles declares unknown role `epic`'* ]]
}

@test "T075 — resolved_ids.<KEY>.roles.<role>.source outside declared|operator|derived refuses, exit 4" {
  write_valid_team
  cat > "${DIR}/config.local.yml" <<'YAML'
resolved_ids:
  PROJ:
    roles:
      specification:
        logical_name: "Epic"
        id: "10001"
        hierarchy_level: "1"
        subtask: false
        source: guessed
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"resolved_ids.PROJ.roles.specification.source is invalid"* ]]
}

@test "T075 — a valid resolved_ids.<KEY>.roles block loads cleanly" {
  write_valid_team
  cat > "${DIR}/config.local.yml" <<'YAML'
resolved_ids:
  PROJ:
    roles:
      specification:
        logical_name: "Epic"
        id: "10001"
        hierarchy_level: "1"
        subtask: false
        source: declared
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

# --- Cross-port parity -------------------------------------------------------

@test "config_yaml_to_json is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  write_valid_team
  bash_json="$(config_yaml_to_json "${DIR}/config.yml")"
  ps_json="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Config.psm1' -Force
    [Console]::Out.Write((ConvertFrom-JiraConfigYaml -Path '${DIR}/config.yml'))
  ")"
  [ "$bash_json" = "$ps_json" ]
}

@test "config_extension_version is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash_v="$(config_extension_version)"
  ps_v="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Config.psm1' -Force
    [Console]::Out.Write((Get-JiraExtensionVersion))
  ")"
  [ "$bash_v" = "$ps_v" ]
}

@test "an apostrophe map key (e.g. a Won't Do status) survives the YAML round-trip" {
  # Regression (002 US1): the writer emits discovered status names verbatim and
  # a name like "Won't Do" is a legal map key; the reader must not stop the
  # mapping there — keys sorted after it (style, style_source) were dropped.
  printf '%s' '{"resolved_ids":{"TEAM":{"statuses":{"Done":"13","Won'\''t Do":"14"},"style":"team_managed","style_source":"api"}}}' \
    | config_to_yaml > "${DIR}/local.yml"
  json="$(config_yaml_to_json "${DIR}/local.yml")"
  [ "$(printf '%s' "${json}" | jq -r '.resolved_ids.TEAM.statuses["Won'\''t Do"]')" = "14" ]
  [ "$(printf '%s' "${json}" | jq -r '.resolved_ids.TEAM.style')" = "team_managed" ]
  [ "$(printf '%s' "${json}" | jq -r '.resolved_ids.TEAM.style_source')" = "api" ]
}

# =============================================================================
# T008 [003] — The operator disable record (FR-007, FR-029, data-model)
# =============================================================================
#
# `specify extension add` writes `enabled: true` unconditionally on every
# install and upgrade (research R5), so the hook registry cannot carry the
# operator's decision across a reinstall. The decision is recorded HERE instead,
# in the gitignored local binding, which lives outside .specify/extensions/ and
# therefore survives (Constitution V). The registry is never edited to match —
# that would be a write, and FR-022 forbids it.

@test "reading an absent disable record yields the empty set" {
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

@test "reading a local binding with no hooks key yields the empty set" {
  printf 'site_alias: "prod"\n' > "${DIR}/config.local.yml"
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

@test "a written disable record round-trips" {
  run config_hooks_disabled_add after_implement "${DIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "recorded" ]
  [ "$(config_hooks_disabled_read "${DIR}")" = '["after_implement"]' ]
}

@test "recording an already-recorded event is unchanged, and never duplicates it" {
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  run config_hooks_disabled_add after_implement "${DIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
  [ "$(config_hooks_disabled_read "${DIR}" | jq 'length')" -eq 1 ]
}

@test "the record is ordered so two runs write byte-identical bytes (FR-003)" {
  config_hooks_disabled_add after_tasks "${DIR}" > /dev/null
  config_hooks_disabled_add after_clarify "${DIR}" > /dev/null
  [ "$(config_hooks_disabled_read "${DIR}")" = '["after_clarify","after_tasks"]' ]
}

@test "an unknown event name is reported and IGNORED rather than failing the run" {
  # The file is human-editable; a typo must not break mirroring (data-model).
  printf 'hooks:\n  disabled:\n    - after_implement\n    - after_typo\n' > "${DIR}/config.local.yml"
  # `run` folds stderr into $output, so read the value through a plain
  # substitution and the report through a separate, stderr-only run.
  [ "$(config_hooks_disabled_read "${DIR}" 2> /dev/null)" = '["after_implement"]' ]
  # The report goes to stderr, naming the offending value.
  run bash -c "source '${LIB_DIR}/config.sh'; config_hooks_disabled_read '${DIR}' 2>&1 >/dev/null"
  [[ "$output" == *"after_typo"* ]]
}

@test "recording an unknown event name is reported and does not fail the run" {
  run config_hooks_disabled_add not_an_event "${DIR}"
  [ "$status" -eq 0 ]
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

@test "--dry-run predicts the record write without performing it (Constitution XI)" {
  run config_hooks_disabled_add after_plan "${DIR}" true
  [ "$status" -eq 0 ]
  [ "$output" = "recorded" ]
  [ ! -f "${DIR}/config.local.yml" ]
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

@test "releasing an event clears it from the record (FR-007, FR-029)" {
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  config_hooks_disabled_add after_plan "${DIR}" > /dev/null
  run config_hooks_disabled_remove after_implement "${DIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "released" ]
  [ "$(config_hooks_disabled_read "${DIR}")" = '["after_plan"]' ]
}

@test "releasing an unrecorded event is a no-op reported as such" {
  run config_hooks_disabled_remove after_implement "${DIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "unrecorded" ]
}

@test "--dry-run predicts the release without performing it (Constitution XI)" {
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  run config_hooks_disabled_remove after_implement "${DIR}" true
  [ "$status" -eq 0 ]
  [ "$output" = "released" ]
  [ "$(config_hooks_disabled_read "${DIR}")" = '["after_implement"]' ]
}

@test "the record preserves the operator's site_alias and overrides" {
  printf 'overrides:\n  routing_default: OPS\nsite_alias: "prod"\n' > "${DIR}/config.local.yml"
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  json="$(config_yaml_to_json "${DIR}/config.local.yml")"
  [ "$(jq -r '.site_alias' <<< "$json")" = "prod" ]
  [ "$(jq -r '.overrides.routing_default' <<< "$json")" = "OPS" ]
  [ "$(jq -r '.hooks.disabled[0]' <<< "$json")" = "after_implement" ]
}

@test "schema validation accepts the hooks key in the local binding (T012)" {
  write_valid_team
  printf 'hooks:\n  disabled:\n    - after_implement\n' > "${DIR}/config.local.yml"
  run config_load "${DIR}"
  [ "$status" -eq 0 ]
}

@test "an empty collection survives the YAML round-trip — the writer is a fixed point of the reader" {
  # Regression (003 T010): config_to_yaml emits `key: []` and `key: {}` for empty
  # collections, but the reader returned them as the STRINGS "[]" and "{}". The
  # module header claims the writer is "a FIXED POINT of the reader", and it was
  # not. The hook-registry reader tripped over it: a registry carrying
  # `after_plan: []` — which is what our own serialiser writes — classified as
  # unreadable instead of as an event with no entries.
  printf '%s' '{"a":[],"b":{},"c":"x"}' | config_to_yaml > "${DIR}/rt.yml"
  json="$(config_yaml_to_json "${DIR}/rt.yml")"
  [ "$(jq -r '.a | type' <<< "$json")" = "array" ]
  [ "$(jq -r '.a | length' <<< "$json")" -eq 0 ]
  [ "$(jq -r '.b | type' <<< "$json")" = "object" ]
  [ "$(jq -r '.b | length' <<< "$json")" -eq 0 ]
  [ "$(jq -r '.c' <<< "$json")" = "x" ]
}

@test "a quoted [] is still a STRING — only the bare flow form is a collection" {
  printf 'a: "[]"\nb: "{}"\n' > "${DIR}/q.yml"
  json="$(config_yaml_to_json "${DIR}/q.yml")"
  [ "$(jq -r '.a | type' <<< "$json")" = "string" ]
  [ "$(jq -r '.b | type' <<< "$json")" = "string" ]
}

@test "a block sequence at its parent key's indentation is read (003 T010 regression)" {
  # THE registry-reading bug. PyYAML — which is what `specify extension add`
  # serialises the hook registry with — emits block sequences at the SAME
  # indentation as their parent key, not indented under it. Both forms are valid
  # YAML and the second is PyYAML's default:
  #
  #     hooks:
  #       before_specify:
  #       - extension: jira        <- indent 2, same as the key
  #
  # This reader required a GREATER indent, so it stopped at the key and returned
  # null for its value. The consequence was not subtle: the hook registry of every
  # real installation parsed as `{"installed":null}`, so hook health reported the
  # file unreadable on a perfectly healthy repository.
  printf '%s\n' \
    'installed:' \
    '- jira' \
    'settings:' \
    '  auto_execute_hooks: true' \
    'hooks:' \
    '  before_specify:' \
    '  - extension: jira' \
    '    command: speckit.jira.feature' \
    '    enabled: true' \
    '  after_plan:' \
    '  - extension: jira' \
    '    command: speckit.jira.reconcile' \
    > "${DIR}/pyyaml.yml"
  json="$(config_yaml_to_json "${DIR}/pyyaml.yml")"
  [ "$(jq -r '.installed[0]' <<< "$json")" = "jira" ]
  [ "$(jq -r '.settings.auto_execute_hooks' <<< "$json")" = "true" ]
  [ "$(jq -r '.hooks.before_specify | length' <<< "$json")" -eq 1 ]
  [ "$(jq -r '.hooks.before_specify[0].command' <<< "$json")" = "speckit.jira.feature" ]
  [ "$(jq -r '.hooks.before_specify[0].enabled' <<< "$json")" = "true" ]
  [ "$(jq -r '.hooks.after_plan[0].command' <<< "$json")" = "speckit.jira.reconcile" ]
}

@test "both sequence indentations produce the SAME parse — the forms are equivalent" {
  printf '%s\n' 'hooks:' '  after_plan:' '  - command: a' '  - command: b' > "${DIR}/flat.yml"
  printf '%s\n' 'hooks:' '  after_plan:' '    - command: a' '    - command: b' > "${DIR}/deep.yml"
  [ "$(config_yaml_to_json "${DIR}/flat.yml")" = "$(config_yaml_to_json "${DIR}/deep.yml")" ]
}

@test "an EMPTY local binding is tolerated, not a config error (003 T013)" {
  # Releasing the last held event leaves the local binding with nothing in it, so
  # the writer emits an empty document. Reading that back must be a no-op, not a
  # refusal — otherwise clearing the last disabled hook would break every
  # subsequent run of the ceremony.
  write_valid_team
  printf '\n' > "${DIR}/config.local.yml"
  run config_load "${DIR}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.routing_default' <<< "$output")" = "PROJ" ]
}

@test "releasing the last held event leaves a loadable local binding (003 T012)" {
  write_valid_team
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  config_hooks_disabled_remove after_implement "${DIR}" > /dev/null
  run config_load "${DIR}"
  [ "$status" -eq 0 ]
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

# =============================================================================
# T022 [030] — config_resolve_connection: sets the variable only when unset or
# empty, never overwrites a non-empty value, treats the empty string as unset
# (plan.md §Key design decision, contracts/connection-settings.md §1)
# =============================================================================

@test "T022 — sets SPEC_KIT_JIRA_BASE_URL from config.yml when unset" {
  write_valid_team
  printf 'base_url: "https://team.atlassian.net"\n' >> "${DIR}/config.yml"
  unset SPEC_KIT_JIRA_BASE_URL
  JIRA_CONFIG_DIR="${DIR}" config_resolve_connection "${DIR}"
  [ "${SPEC_KIT_JIRA_BASE_URL}" = "https://team.atlassian.net" ]
  unset SPEC_KIT_JIRA_BASE_URL
}

@test "T022 — never overwrites a non-empty SPEC_KIT_JIRA_BASE_URL" {
  write_valid_team
  printf 'base_url: "https://team.atlassian.net"\n' >> "${DIR}/config.yml"
  export SPEC_KIT_JIRA_BASE_URL="https://preset.example.invalid"
  JIRA_CONFIG_DIR="${DIR}" config_resolve_connection "${DIR}"
  [ "${SPEC_KIT_JIRA_BASE_URL}" = "https://preset.example.invalid" ]
  unset SPEC_KIT_JIRA_BASE_URL
}

@test "T022 — treats an empty SPEC_KIT_JIRA_BASE_URL as unset" {
  write_valid_team
  printf 'base_url: "https://team.atlassian.net"\n' >> "${DIR}/config.yml"
  export SPEC_KIT_JIRA_BASE_URL=""
  JIRA_CONFIG_DIR="${DIR}" config_resolve_connection "${DIR}"
  [ "${SPEC_KIT_JIRA_BASE_URL}" = "https://team.atlassian.net" ]
  unset SPEC_KIT_JIRA_BASE_URL
}

@test "T022 — sets JIRA_EMAIL from personal.yml when unset" {
  write_valid_team
  printf 'email: op@example.com\n' > "${DIR}/personal.yml"
  unset JIRA_EMAIL
  JIRA_CONFIG_DIR="${DIR}" config_resolve_connection "${DIR}"
  [ "${JIRA_EMAIL}" = "op@example.com" ]
  unset JIRA_EMAIL
}

@test "T022 — never overwrites a non-empty JIRA_EMAIL" {
  write_valid_team
  printf 'email: op@example.com\n' > "${DIR}/personal.yml"
  export JIRA_EMAIL="preset@example.invalid"
  JIRA_CONFIG_DIR="${DIR}" config_resolve_connection "${DIR}"
  [ "${JIRA_EMAIL}" = "preset@example.invalid" ]
  unset JIRA_EMAIL
}

@test "T022 — treats an empty JIRA_EMAIL as unset" {
  write_valid_team
  printf 'email: op@example.com\n' > "${DIR}/personal.yml"
  export JIRA_EMAIL=""
  JIRA_CONFIG_DIR="${DIR}" config_resolve_connection "${DIR}"
  [ "${JIRA_EMAIL}" = "op@example.com" ]
  unset JIRA_EMAIL
}

@test "T022 — tolerant of an absent config.yml (US4 unattended/env-only path)" {
  unset SPEC_KIT_JIRA_BASE_URL JIRA_EMAIL
  run config_resolve_connection "${DIR}"
  [ "$status" -eq 0 ]
}

@test "T022 — fails closed on a present-but-malformed config.yml (C6.2)" {
  printf 'projects:\n  - key: PROJ\nbase_url: "not-a-url"\n' > "${DIR}/config.yml"
  unset SPEC_KIT_JIRA_BASE_URL
  run config_resolve_connection "${DIR}"
  [ "$status" -eq 4 ]
}

# =============================================================================
# Regression [030, discovered via us030-guard-not-a-hole scenario authoring]:
# a truly empty (0-byte) config.local.yml parses to jq `null`, and every
# schema/credential jq program assumes an object — `keys_unsorted[]`/`has(...)`
# on a null top level is a jq RUNTIME ERROR (exit 5, stderr redirected to
# /dev/null), which `pipefail` turned into a silent EXIT_CONFIG (4) with NO
# located message at all. An empty config.local.yml/personal.yml is a normal
# state (nothing resolved locally yet, or an operator-blanked file), not a
# malformed one.
# =============================================================================

@test "an empty (0-byte) config.local.yml is accepted, not a silent crash" {
  write_valid_team
  : > "${DIR}/config.local.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

@test "an empty (0-byte) personal.yml is accepted, not a silent crash" {
  : > "${DIR}/personal.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_personal_load "${DIR}" '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "false" ]
}

# =============================================================================
# 031 Phase 4 — configuration is found from the repository, not the shell
# (config_resolve_dir, contract C1.1/C1.2, FR-007/FR-014/FR-015)
# =============================================================================

@test "031, T023: resolution order is JIRA_CONFIG_DIR, then SPECIFY_INIT_DIR, then the nearest ancestor carrying .specify/ (C1.1, FR-014, FR-015)" {
  local rootA rootB explicit out
  # Resolved through pwd -P: config_resolve_dir spells the WALK and
  # SPECIFY_INIT_DIR branches through the physical cwd (see its own comment
  # in lib/config.sh), so the expectation must match on a host where mktemp's
  # own directory sits under a symlink (macOS /var -> /private/var).
  rootA="$(cd "$(mktemp -d)" && pwd -P)"
  mkdir -p "${rootA}/.specify" "${rootA}/sub"
  rootB="$(cd "$(mktemp -d)" && pwd -P)"
  mkdir -p "${rootB}/.specify"
  # NOT resolved — an explicit JIRA_CONFIG_DIR is honoured verbatim (C1.1),
  # never silently rewritten, on either port.
  explicit="$(mktemp -d)"

  # (a) neither override set ⇒ the nearest ancestor's .specify/ wins.
  out="$(cd "${rootA}/sub" && unset JIRA_CONFIG_DIR SPECIFY_INIT_DIR && config_resolve_dir)"
  [ "${out}" = "${rootA}/.specify/jira" ]

  # (b) SPECIFY_INIT_DIR wins over an ancestor the walk WOULD otherwise find
  #     (rootA/.specify/, reachable from rootA/sub) — proving priority, not
  #     mere availability.
  out="$(cd "${rootA}/sub" && unset JIRA_CONFIG_DIR && SPECIFY_INIT_DIR="${rootB}" config_resolve_dir)"
  [ "${out}" = "${rootB}/.specify/jira" ]

  # (c) an explicit JIRA_CONFIG_DIR wins over both.
  out="$(cd "${rootA}/sub" && JIRA_CONFIG_DIR="${explicit}" SPECIFY_INIT_DIR="${rootB}" config_resolve_dir)"
  [ "${out}" = "${explicit}" ]

  rm -rf "${rootA}" "${rootB}" "${explicit}"
}

@test "031, T024: the walk goes upward only and stops at the filesystem root (C1.2)" {
  local root out status_
  root="$(mktemp -d)"
  mkdir -p "${root}/a/b/c"
  # A decoy .specify/ only reachable by DESCENDING from a/b/c — proves the
  # walk never descends, only ever goes up.
  mkdir -p "${root}/a/b/c/decoy/.specify"
  status_=0
  out="$(cd "${root}/a/b/c" && unset JIRA_CONFIG_DIR SPECIFY_INIT_DIR && config_resolve_dir)" || status_=$?
  [ "${status_}" -eq 1 ]
  [ -z "${out}" ]
  rm -rf "${root}"
}

@test "031: config_resolve_dir always returns an absolute path, even for a relative explicit override (FR-009)" {
  local somedir out
  somedir="$(cd "$(mktemp -d)" && pwd -P)"
  out="$(cd "${somedir}" && JIRA_CONFIG_DIR="./relative-jira" config_resolve_dir)"
  [ "${out}" = "${somedir}/relative-jira" ]
  rm -rf "${somedir}"
}
