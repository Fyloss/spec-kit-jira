#!/usr/bin/env bash
# hooks/readme_block.sh — Version-marked managed README-block writer (US5, T064).
#
# Renders the self-documenting README block from the template, stamping the marker
# lines with the single source-of-truth version (FR-024), and splices it into the
# consuming repository's README via the neutral engine byte-splice (FR-025). The
# operation is idempotent: an up-to-date README is left byte-for-byte unchanged and
# reported as such (FR-028); a hand-edited block is regenerated (FR-029); malformed
# markers are refused with zero writes and exit 4 (FR-027).
#
# This is the hooks layer, not the engine: it owns the README/version vocabulary
# and the marker tokens; the engine owns the marker-agnostic byte manipulation.

[[ -n ${_JIRA_HOOK_README_BLOCK:-} ]] && return 0
_JIRA_HOOK_README_BLOCK=1

_readme_block_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_readme_block_dir}/../engine/managed_section.sh"
# shellcheck source=/dev/null
source "${_readme_block_dir}/../lib/config.sh" # config_extension_version — the single version source

: "${EXIT_CONFIG:=4}"

# Stable, version-independent marker tokens used to LOCATE the block regardless of
# which version last stamped it (the rendered block carries the current version).
README_BLOCK_BEGIN_TOKEN='<!-- spec-kit-jira:begin'
README_BLOCK_END_TOKEN='<!-- spec-kit-jira:end'

_readme_block_template() {
  printf '%s' "${SPEC_KIT_JIRA_README_TEMPLATE:-${_readme_block_dir}/../../../templates/readme-block.template}"
}

# readme_block_render — print the version-marked block (markers included), lines
# joined by LF and WITHOUT a trailing newline. The version is read from the single
# source (extension.yml); the template's {{VERSION}} placeholders are substituted.
readme_block_render() {
  local version tmpl body
  version="$(config_extension_version)" || return $?
  tmpl="$(_readme_block_template)"
  if [[ ! -f "${tmpl}" ]]; then
    printf 'readme: block template not found: %s\n' "${tmpl}" >&2
    return "${EXIT_CONFIG}"
  fi
  body="$(cat "${tmpl}")" # command substitution strips the template's trailing newline
  printf '%s' "${body//\{\{VERSION\}\}/${version}}"
}

# readme_block_write <readme-path> [dry-run:true|false] — render the block and
# splice it into the host README (creating it if absent). Prints a status token on
# stdout (created | written | unchanged | refused). Returns 0, or EXIT_CONFIG (4)
# on malformed markers (zero writes). In dry-run the status is computed but the
# file is never touched.
readme_block_write() {
  local path="$1" dry="${2:-false}" block current existed="false" tmp status

  block="$(readme_block_render)" || return $?

  if [[ -f "${path}" ]]; then
    existed="true"
    current="$(cat "${path}"; printf x)"; current="${current%x}"
  else
    current=""
  fi

  tmp="$(mktemp)"
  if ! printf '%s' "${current}" | managed_section_splice \
      "${README_BLOCK_BEGIN_TOKEN}" "${README_BLOCK_END_TOKEN}" "${block}" > "${tmp}"; then
    rm -f "${tmp}"
    printf 'refused'
    return "${EXIT_CONFIG}"
  fi

  if [[ "${existed}" == "true" ]] && cmp -s "${tmp}" "${path}"; then
    status="unchanged"
  elif [[ "${existed}" == "false" ]]; then
    status="created"
  else
    status="written"
  fi

  if [[ "${dry}" != "true" && "${status}" != "unchanged" ]]; then
    mv "${tmp}" "${path}"
  else
    rm -f "${tmp}"
  fi
  printf '%s' "${status}"
  return 0
}
