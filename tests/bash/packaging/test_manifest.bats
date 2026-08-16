#!/usr/bin/env bats
# T060 [027] — Reachability (research R1, plan.md "the mention lesson"):
# `speckit.jira.seed` MUST be declared in `extension.yml` under
# `provides.commands`, bound to NO hook event. `mention` has shipped
# working in both ports since 001 and remains unreachable to this day
# because it was never declared — a feature that ships without its
# declaration has not shipped.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MANIFEST="${ROOT}/extension.yml"
}

_provides_block() {
  # Everything from the `provides:` line up to (excluding) the `hooks:` line.
  awk '/^provides:/{p=1} /^hooks:/{p=0} p' "${MANIFEST}"
}

_hooks_block() {
  awk '/^hooks:/{p=1} /^tags:/{p=0} p' "${MANIFEST}"
}

@test "speckit.jira.seed is declared under provides.commands" {
  [[ "$(_provides_block)" == *"name: speckit.jira.seed"* ]]
}

@test "speckit.jira.seed's file points at commands/speckit.jira.seed.md" {
  local block
  block="$(_provides_block)"
  [[ "${block}" == *"speckit.jira.seed.md"* ]]
}

@test "speckit.jira.seed is bound to no hook event" {
  local hooks
  hooks="$(_hooks_block)"
  [[ "${hooks}" != *"speckit.jira.seed"* ]]
}

@test "the command definition file exists and is shipped content" {
  [ -f "${ROOT}/commands/speckit.jira.seed.md" ]
}
