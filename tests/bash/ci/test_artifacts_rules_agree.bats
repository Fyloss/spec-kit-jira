#!/usr/bin/env bats
# T110 [036, Convergence] — the `artifacts` rules are stated THREE times, and
# nothing made them agree.
#
#   1. specs/001-jira-reconcile-engine/contracts/neutral-interchange.schema.json
#   2. the jq programme in scripts/bash/engine/interchange.sh
#   3. the PowerShell validator in scripts/powershell/engine/Interchange.psm1
#
# The published schema is documentation — no runtime code reads it — so a rule
# added to the jq programme and not to the schema leaves the contract quietly
# wrong, and a rule added to one port and not the other is a silent cross-port
# divergence that the conformance corpus only catches if a scenario happens to
# exercise it.
#
# The precedent is not hypothetical: `run-summary.schema.json` sat SEVEN items
# behind both ports across three features, so every run summary was invalid
# against its own published contract for that whole period, because nothing
# compared them.
#
# SCOPE: the `artifacts` key only. The wider document has the same exposure and
# it is pre-existing — widening this guard to cover it belongs to its own spec,
# not to 036 (Principle XV).
#
# This is a BEHAVIOURAL guard, not a text-matching one: it feeds the same
# documents to both validators and asserts they return the same verdict, then
# asserts the schema declares the same field set the validators enforce. Two
# implementations agreeing on a corpus is worth more than three files
# containing the same words.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/neutral-interchange.schema.json"
  VALID="${ROOT}/tests/conformance/fixtures/neutral-valid.json"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/interchange.sh"
}

# Emit the valid fixture with `artifacts` set to <json>.
_doc_with() {
  jq -c --argjson a "$1" '. + {artifacts: $a}' < "${VALID}"
}

# The PowerShell verdict for a document, as "0" (valid) or "1" (refused).
_pwsh_verdict() {
  local doc="$1" f="${BATS_TEST_TMPDIR}/doc.json"
  printf '%s' "${doc}" > "${f}"
  pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/engine/Interchange.psm1' -Force
    if (Test-JiraInterchange -Json (Get-Content -Raw -LiteralPath '${f}')) { '0' } else { '1' }
  " 2> /dev/null | tr -d '[:space:]'
}

# The Bash verdict for the same document, same encoding.
_bash_verdict() {
  if printf '%s' "$1" | interchange_validate > /dev/null 2>&1; then
    printf '0'
  else
    printf '1'
  fi
}

# --- the two validators agree, case by case --------------------------------

@test "T110 both validators return the same verdict on every artifacts case" {
  command -v pwsh > /dev/null 2>&1 || skip "pwsh is not installed on this host"

  local -a cases=(
    '[]'
    '[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"}]'
    '[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"},{"path":"c/a.md","hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":3,"attachment_name":"c__a.md"}]'
    '[{"path":"/abs/spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"}]'
    '[{"path":"../up/spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"}]'
    '[{"path":"a/../b.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"a__b.md"}]'
    '[{"path":"","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"}]'
    '[{"path":"spec.md","size":12,"attachment_name":"spec.md"}]'
    '[{"path":"spec.md","hash":"NOTHEX","size":12,"attachment_name":"spec.md"}]'
    '[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","attachment_name":"spec.md"}]'
    '[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":-1,"attachment_name":"spec.md"}]'
    '[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12}]'
    '[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":""}]'
    '{"spec.md":"x"}'
    '"a string"'
  )

  local disagreements="" c doc b p
  for c in "${cases[@]}"; do
    doc="$(_doc_with "${c}")"
    b="$(_bash_verdict "${doc}")"
    p="$(_pwsh_verdict "${doc}")"
    [ "${b}" = "${p}" ] || disagreements+="  bash=${b} pwsh=${p}  ${c}"$'\n'
  done

  [ -z "${disagreements}" ] || {
    printf 'the two validators disagree on the artifacts rules:\n%s' "${disagreements}" >&2
    return 1
  }
}

# --- the published schema states the same rules ----------------------------

@test "T110 the schema declares the artifacts key the validators enforce" {
  [ "$(jq -r '.properties.artifacts.type' "${SCHEMA}")" = "array" ]
  # OPTIONAL: absence is the off switch, so it must NOT be in `required`.
  [ "$(jq -r '.required | index("artifacts")' "${SCHEMA}")" = "null" ]
}

@test "T110 the schema's required artifact fields are exactly the four the validators check" {
  local want got
  want="$(printf '%s\n' attachment_name hash path size)"
  got="$(jq -r '.properties.artifacts.items.required[]' "${SCHEMA}" | LC_ALL=C sort)"
  [ "${got}" = "${want}" ]
}

@test "T110 the schema forbids an unknown artifact field, as a closed contract must" {
  [ "$(jq -r '.properties.artifacts.items.additionalProperties' "${SCHEMA}")" = "false" ]
}

@test "T110 the schema constrains hash and size the way both validators do" {
  [ "$(jq -r '.properties.artifacts.items.properties.hash.pattern' "${SCHEMA}")" = '^[0-9a-f]{40}$' ]
  [ "$(jq -r '.properties.artifacts.items.properties.size.type' "${SCHEMA}")" = "integer" ]
  [ "$(jq -r '.properties.artifacts.items.properties.size.minimum' "${SCHEMA}")" = "0" ]
  [ "$(jq -r '.properties.artifacts.items.properties.path.minLength' "${SCHEMA}")" = "1" ]
  [ "$(jq -r '.properties.artifacts.items.properties.attachment_name.minLength' "${SCHEMA}")" = "1" ]
}

# --- both builders emit the key on the same condition ----------------------

@test "T110 both ports omit the artifacts key on an empty set and emit it otherwise" {
  command -v pwsh > /dev/null 2>&1 || skip "pwsh is not installed on this host"

  local parse ctx_empty ctx_one
  parse='{"epic":{"title":"E","description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"S","description":{"blocks":[{"type":"paragraph","spans":[{"text":"n","marks":[]}]}]},"priority_logical":"P1"}]}'
  ctx_empty='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ","artifacts":[]}'
  ctx_one='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ","artifacts":[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"}]}'

  local b_empty b_one p_empty p_one
  b_empty="$(interchange_build "${parse}" "${ctx_empty}")"
  b_one="$(interchange_build "${parse}" "${ctx_one}")"
  p_empty="$(pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/engine/Interchange.psm1' -Force
    (Build-JiraNeutralDocument -ParseJson '${parse}' -ContextJson '${ctx_empty}').Document" 2> /dev/null)"
  p_one="$(pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/engine/Interchange.psm1' -Force
    (Build-JiraNeutralDocument -ParseJson '${parse}' -ContextJson '${ctx_one}').Document" 2> /dev/null)"

  # Byte equivalence, not merely "both have the key": the document is compared
  # byte-for-byte across ports and machines (Constitution VI).
  [ "${b_empty}" = "${p_empty}" ]
  [ "${b_one}" = "${p_one}" ]
  [ "$(jq -r 'has("artifacts")' <<< "${b_empty}")" = "false" ]
  [ "$(jq -r 'has("artifacts")' <<< "${b_one}")" = "true" ]
}
