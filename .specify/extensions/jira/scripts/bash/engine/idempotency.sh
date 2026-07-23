#!/usr/bin/env bash
# engine/idempotency.sh — Zero-churn idempotency diff (US6, T072).
#
# PURE engine functions: zero Jira reads, zero writes, no sink/. A re-run on an
# unchanged corpus must produce zero writes of any kind (FR 030, Constitution II).
# These primitives decide whether a would-be write is churn — comparing the
# desired state against the current state — so the caller can drop no-op actions
# before anything reaches Jira.
#
# Two comparison shapes:
#   idempotency_field_status  — a set of fields to write vs the ticket's current
#                               fields (deep structural equality, key-order
#                               independent).
#   idempotency_managed_status — a managed-section block spliced into host bytes
#                               vs the host itself (a no-op splice is zero churn).

[[ -n ${_JIRA_ENGINE_IDEMPOTENCY:-} ]] && return 0
_JIRA_ENGINE_IDEMPOTENCY=1

_idem_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_idem_dir}/managed_section.sh"

# idempotency_equal <a> <b> — exit 0 if the two strings are byte-identical
# (ordinal), else 1. The primitive both ports share for a raw-bytes decision.
idempotency_equal() {
  [[ "$1" == "$2" ]]
}

# idempotency_field_status <current-fields-json> <desired-fields-json>
# For every key the write would set, compare its value against the same key in the
# current ticket state. Echo "unchanged" iff every desired key is already present
# with a structurally equal value (jq compares objects/arrays by content, not key
# order); otherwise "changed". Writing the desired fields onto a ticket already in
# that state is churn (FR 030) — "unchanged" means the caller MUST skip the write.
idempotency_field_status() {
  local current="$1" desired="$2" result
  result="$(jq -n --argjson cur "${current}" --argjson des "${desired}" '
    [ $des | to_entries[] | (.value == ($cur[.key])) ] | all')"
  if [[ "${result}" == "true" ]]; then printf 'unchanged'; else printf 'changed'; fi
}

# idempotency_managed_status <begin> <end> <new-block>   (stdin: host bytes)
# Splice <new-block> into the host and compare byte-for-byte with the host: echo
# "unchanged" when the splice is a no-op (zero churn), else "changed". Returns 4
# (refused) with no stdout when the host carries malformed markers — the splice's
# own contract, surfaced verbatim.
idempotency_managed_status() {
  local begin="$1" end="$2" block="$3" host spliced rc tmp
  host="$(cat; printf x)"; host="${host%x}"
  tmp="$(mktemp)"
  printf '%s' "${host}" | managed_section_splice "${begin}" "${end}" "${block}" > "${tmp}"
  rc=$?
  if [[ "${rc}" -ne 0 ]]; then rm -f "${tmp}"; return "${rc}"; fi
  spliced="$(cat "${tmp}"; printf x)"; spliced="${spliced%x}"; rm -f "${tmp}"
  if [[ "${host}" == "${spliced}" ]]; then printf 'unchanged'; else printf 'changed'; fi
}
