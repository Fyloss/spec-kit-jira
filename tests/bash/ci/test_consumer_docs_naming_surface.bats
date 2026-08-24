#!/usr/bin/env bats
# The per-operator naming surface — `teams:`, `personal.yml`, `override` — is
# documented where a consumer meets it.
#
# `override` is the escape hatch that lets one developer ship under a different
# convention without editing the committed catalogue. It appeared in no README:
# neither this repository's, nor the managed block spliced into consumers'.
# Only `templates/personal.yml.template` mentioned it, and only in passing.
#
# Assertions are grep-testable statements about wording, as in
# test_consumer_docs_invocation.bats: for a document, the wording IS the
# behaviour.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  PERSONAL="${ROOT}/templates/personal.yml.template"
  BLOCK="${ROOT}/templates/readme-block.template"
  README="${ROOT}/README.md"
}

@test "all three documents exist" {
  [ -f "${PERSONAL}" ]
  [ -f "${BLOCK}" ]
  [ -f "${README}" ]
}

@test "README.md documents the naming surface, override included" {
  grep -qE 'personal\.yml' "${README}"
  grep -qE '^\s*override:' "${README}"
  grep -qE 'folder_prefix' "${README}"
  grep -qE 'branch_pattern' "${README}"
}

@test "README.md says the override is reported every time it fires" {
  local flat
  flat="$(tr '\n' ' ' < "${README}")"
  grep -qE 'override_used' <<< "${flat}"
}

@test "the managed block tells a consumer the naming convention exists" {
  grep -qE 'personal\.yml' "${BLOCK}"
  grep -qE 'override' "${BLOCK}"
}

# --- The connection settings, after 030 -------------------------------------
#
# 030 moved the site URL into the committed `config.yml` and the email into
# `personal.yml`, leaving the environment variables as overrides. The config
# ceremony's own degraded-run message already says so — "add it to config.yml
# (or export SPEC_KIT_JIRA_BASE_URL)" — but README.md still taught exporting
# all three into a shell profile as THE setup step, on all three platforms.
#
# The token is the one value that must never reach a file. It is declared as a
# retrieval command against the OS vault (JIRA_PAT_COMMAND) so the operator
# never handles it directly.
