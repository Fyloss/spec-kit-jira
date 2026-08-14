#!/usr/bin/env bats
# T020a [026] [US1] — README.md, INSTALL.md and templates/readme-block.template
# instruct the Bash bridge THROUGH THE INTERPRETER (`bash <path>`), and none of
# them ever invokes it by bare path (contracts/bridge-invocation.md C2.3, C4.3).
#
# Nothing in the tree pinned these three files before this feature, which is
# how the instance was missed: two existing tests already pinned the three
# command documents (test_agent_doc_invocation.bats,
# test_agent_fallback_block.bats), but a first-time reader meets README.md
# first. The template matters most of the three — it is SHIPPED, and it
# writes this text into every consuming repository's own README.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  BASH_ENTRY='.specify/extensions/jira/scripts/bash/spec-kit-jira.sh'
  DOCS=("${ROOT}/README.md" "${ROOT}/INSTALL.md" "${ROOT}/templates/readme-block.template")
}

@test "each of the three documents exists" {
  local doc
  for doc in "${DOCS[@]}"; do
    [ -f "${doc}" ]
  done
}

@test "each document invokes the Bash entry point through the interpreter, never bare-path" {
  local doc invocations bad
  local pattern="${BASH_ENTRY//./\\.}[[:space:]]+(--help|config|reconcile|feature|mention)"
  for doc in "${DOCS[@]}"; do
    invocations="$(grep -nE "${pattern}" "${doc}" || true)"
    [[ -z "${invocations}" ]] && continue
    bad="$(grep -vE "bash ${pattern}" <<< "${invocations}" || true)"
    if [[ -n "${bad}" ]]; then
      printf '%s invokes the Bash entry point without the "bash " interpreter prefix:\n%s\n' "${doc}" "${bad}" >&2
      return 1
    fi
  done
}

@test "at least one of the three documents demonstrates the interpreter-prefixed invocation" {
  local doc found=0
  for doc in "${DOCS[@]}"; do
    grep -qF "bash ${BASH_ENTRY}" "${doc}" && found=1
  done
  [ "${found}" -eq 1 ]
}
