#!/usr/bin/env bats
# The per-operator naming surface — `teams:`, `personal.yml`, `override` — is
# documented where a consumer meets it.
#
# Two defects motivated this. `templates/personal.yml.template` is the file the
# config ceremony creates in every consuming repository, and 030 added `email`
# to the keys it accepts without the template ever mentioning it — while the
# template's credential warning still said an email "in any value is refused",
# which 030's own exemption table (contracts/connection-settings.md C5.2) had
# just made false. A consumer following that file could not configure the key
# the extension now identifies them by, and was told the attempt would fail.
#
# The second is plainer: `override` — the escape hatch that lets one developer
# ship under a different convention without editing the committed catalogue —
# appeared in no README, neither this repository's nor the managed block spliced
# into consumers'.
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

@test "the personal template documents the email key 030 added" {
  grep -qE '^# *email:' "${PERSONAL}"
}

@test "the personal template does not claim an email is refused everywhere" {
  # 030 C5.2 exempts `email` on this surface. A blanket refusal is now false,
  # and it is false about the one key the extension identifies an operator by.
  # Matched on the blanket phrasing itself rather than on "email … refused":
  # the sentence between them contains `*.atlassian.net`, so any dot-excluding
  # pattern silently matches nothing and the guard passes against the very file
  # it exists to reject.
  local flat
  flat="$(tr '\n' ' ' < "${PERSONAL}")"
  ! grep -qE 'in[[:space:]]+any[[:space:]]+value[[:space:]]+is[[:space:]]+refused' <<< "${flat}"
}

@test "the personal template still refuses the shapes 030 never exempted" {
  # The correction must not become a licence: a token anywhere and a real Jira
  # host anywhere are still refused (C5.3, C5.4).
  local flat
  flat="$(tr '\n' ' ' < "${PERSONAL}")"
  grep -qE 'token' <<< "${flat}"
  grep -qE 'atlassian\.net' <<< "${flat}"
}

@test "the personal template does not call this gitignored file committed" {
  ! grep -qE 'Like every committed config file' "${PERSONAL}"
}

@test "README.md documents the naming surface, override included" {
  grep -qE 'personal\.yml' "${README}"
  grep -qE '^[[:space:]]*override:' "${README}"
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

@test "README does not teach exporting the site URL or the email" {
  ! grep -qE '^export SPEC_KIT_JIRA_BASE_URL=' "${README}"
  ! grep -qE '^export JIRA_EMAIL=' "${README}"
  ! grep -qE "SetEnvironmentVariable\('SPEC_KIT_JIRA_BASE_URL'" "${README}"
  ! grep -qE "SetEnvironmentVariable\('JIRA_EMAIL'" "${README}"
}

@test "README does not teach pasting the raw token into a shell profile" {
  ! grep -qE '^export JIRA_API_TOKEN="your-token"' "${README}"
}

@test "README declares the token through the OS vault on every platform" {
  grep -qE 'JIRA_PAT_COMMAND' "${README}"
  grep -qE 'security find-generic-password' "${README}"
  grep -qE 'secret-tool lookup' "${README}"
}

# NOTE for anyone extending this file: never use `[^.]` as the gap in these
# patterns. Every value they span — paths, hostnames — is dotted, so the class
# matches nothing and the assertion passes against the file it must reject.
@test "README sends the site URL to config.yml and the email to personal.yml" {
  local flat
  flat="$(tr '\n' ' ' < "${README}")"
  grep -qE 'base_url.{0,80}config\.yml' <<< "${flat}"
  grep -qE 'email.{0,80}personal\.yml' <<< "${flat}"
}

@test "the committed config template offers the base_url key" {
  grep -qE '^# *base_url:' "${ROOT}/templates/config.yml.template"
}

# The committed config template's own header went stale with 030 in two ways:
# it sent secrets to a `.env` the bridge no longer reads (only the gitignore
# rule survives, so a pre-030 leftover stays ignored), and it claimed a site
# host is rejected at every key — which is false at `base_url`, the key 030
# moved INTO this file and exempted (C5.2).

@test "the config template does not send secrets to the retired .env" {
  local flat
  flat="$(tr '\n' ' ' < "${ROOT}/templates/config.yml.template")"
  ! grep -qE 'secrets[[:space:]]+live[[:space:]]+in' <<< "${flat}"
}

@test "the config template does not claim a site host is refused at every key" {
  local flat
  flat="$(tr '\n' ' ' < "${ROOT}/templates/config.yml.template")"
  ! grep -qE 'never[[:space:]]+contains.{0,80}atlassian\.net' <<< "${flat}"
}

# --- The token: vault first, environment for CI only -----------------------
#
# The resolution order is unchanged (environment, then JIRA_PAT_COMMAND) and
# both rungs stay supported — .github/workflows/live.yml authenticates through
# the environment variable, so removing that rung would break this repository's
# own live suite. What changed is the posture: a developer's install path
# offers the OS vault and nothing else, and the environment variable is
# documented where it belongs, under CI and containers.

_readme_step3_blocks() {
  awk '/^### 3\./ { f = 1; next } f && /^### / { f = 0 } f' "${README}"
}

@test "no install step offers the raw token variable" {
  ! _readme_step3_blocks | grep -qE 'JIRA_API_TOKEN'
}

@test "every install step declares the retrieval command instead" {
  local n
  n="$(_readme_step3_blocks | grep -cE 'JIRA_PAT_COMMAND')"
  [ "${n}" -ge 3 ]
}

@test "the environment rung is documented, under CI and containers" {
  grep -qE '^#+ .*(CI|container)' "${README}"
  grep -qE 'JIRA_API_TOKEN' "${README}"
}

@test "the vault is shown as a point of extension, not a macOS constraint" {
  grep -qE 'op read' "${README}"
  grep -qE 'pass show' "${README}"
}

@test "the Windows recipe matches CREDENTIALS.md — pwsh -File, not a .cmd" {
  local flat
  flat="$(tr '\n' ' ' < "${README}")"
  grep -qE 'pwsh -NoProfile -File' <<< "${flat}"
  ! grep -qE 'get-jira-token\.cmd' <<< "${flat}"
}

@test "README names the disclosure choice a committed base_url makes" {
  local flat
  flat="$(tr '\n' ' ' < "${README}")"
  grep -qE 'git history' <<< "${flat}"
}

# --- Claims the code contradicts (Copilot, PR #54) --------------------------

@test "nothing claims personal.yml is never written by any script" {
  # False: _config_personal_effect CREATES it when absent (config.sh:884). What
  # is true, and more useful, is that it is created once and never rewritten —
  # an existing file returns `unchanged` (config.sh:873), so hand edits survive.
  local f
  for f in "${README}" "${BLOCK}" "${PERSONAL}" "${ROOT}/docs/06-feature-naming.md"; do
    run bash -c "tr '\n' ' ' < '${f}' | grep -qiE 'no script ever writes|never written by any script'"
    [ "$status" -ne 0 ]
  done
}

@test "nothing says the setup steps use the token variable directly" {
  local flat
  flat="$(tr '\n' ' ' < "${README}")"
  ! grep -qE 'use[[:space:]]+the[[:space:]]+environment[[:space:]]+variable[[:space:]]+directly' <<< "${flat}"
}

# The section terminator must be a markdown HEADING (`## `/`### `), never any
# line starting with `#`: these sections embed YAML whose comments open with
# `# `, so a bare `^#` truncates the first section before its own `base_url`
# and the guard fails against a document that is in fact correct.
@test "all three platform step 5s name the two settings and their files" {
  local body n
  body="$(awk '/^### 5\./ { f = 1; next } f && /^##+ / { f = 0 } f' "${README}")"
  n="$(grep -c 'base_url' <<< "${body}")"
  [ "${n}" -ge 3 ]
  n="$(grep -c 'personal\.yml' <<< "${body}")"
  [ "${n}" -ge 3 ]
}
