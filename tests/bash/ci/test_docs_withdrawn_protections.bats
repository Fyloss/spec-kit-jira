#!/usr/bin/env bats
# 034 T064 [FR-011] — the documentation STATES what the extension stopped doing,
# and what follows from it.
#
# Every other check in the 034 documentation sweep tests for ABSENCE: the SC-006
# grep proves the retired claims are gone. A phase that deleted the paragraphs
# and wrote nothing in their place would satisfy all of them, and would be the
# worse outcome — an operator who is told nothing has no way to learn that two
# protections were withdrawn on purpose.
#
# Constitution 4.0.0 gave up both knowingly and said so in its own amendment
# report. FR-011 requires the consumer-facing documents to say so too, rather
# than leaving it to be discovered in a diff:
#
#   1. hook registration, and its survival across reinstalls, belong to the HOST;
#   2. a repository whose hooks are absent will simply SEE NOTHING HAPPEN —
#      silence is the signal, because the extension no longer reports on it;
#   3. a hand-disabled hook may be RE-ENABLED BY A REINSTALL without warning.
#
# The two files checked are the ones an operator actually opens: INSTALL.md is
# where installation is documented, and templates/readme-block.template is
# SHIPPED — the ceremony writes it into every consuming repository's own README,
# so it is the only one of the two a consumer sees without visiting this repo.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  INSTALL="${ROOT}/INSTALL.md"
  TEMPLATE="${ROOT}/templates/readme-block.template"
}

# states <file> <regex> — the file makes this statement somewhere.
states() {
  grep -qiE "$2" "$1"
}

@test "INSTALL.md says hook registration belongs to the host (FR-011.1)" {
  states "${INSTALL}" 'specify extension add' || return 1
  states "${INSTALL}" '(host|install)[^.]*(registers|owns|writes)[^.]*hook|hook[^.]*(registration|registry)[^.]*(host|install)'
}

@test "INSTALL.md says an absent hook means nothing happens, with no warning (FR-011.2)" {
  # The protection given up: the extension no longer reports a missing entry, so
  # the operator's only signal is silence. That has to be stated, not implied.
  states "${INSTALL}" 'nothing (will )?happen'
}

@test "INSTALL.md says a reinstall may silently re-enable a disabled hook (FR-011.3)" {
  states "${INSTALL}" 're-?enable' || return 1
  states "${INSTALL}" 'reinstall|specify extension add'
}

@test "the shipped README block says the host owns registration (FR-011.1)" {
  states "${TEMPLATE}" 'specify extension add'
}

@test "the shipped README block states both withdrawn protections (FR-011.2, FR-011.3)" {
  states "${TEMPLATE}" 'nothing (will )?happen' || return 1
  states "${TEMPLATE}" 're-?enable'
}

@test "neither document still claims the extension verifies the registry (SC-006)" {
  # The absence half, asserted here too so this file fails as one unit if the
  # sweep is ever half-applied.
  local f
  for f in "${INSTALL}" "${TEMPLATE}"; do
    run grep -nE 'enable-hook|held_disabled|verifies the hook|hook health' "${f}"
    [ "$status" -ne 0 ] || { printf 'retired claim survives in %s:\n%s\n' "${f}" "${output}" >&2; return 1; }
  done
}
