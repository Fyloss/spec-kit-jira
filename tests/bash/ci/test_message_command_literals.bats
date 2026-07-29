#!/usr/bin/env bats
# T044 [US5] — Every command literal in every message is runnable as spelled
# (FR-018, SC-009).
#
# The reported defect told the developer to run `/speckit-jira-conifg`. That
# command resolves to nothing. It was never in this repository — the assistant
# composed it — but the same class of error is committed too, and nothing checked
# for it: a command name is just a string in a `printf`, and a wrong one only
# fails in front of a user.
#
# FR-018 names three classes of literal, and all three are checked here over
# `scripts/bash/**` and `commands/*.md`:
#
#   (a) AN ASSISTANT COMMAND OF THIS EXTENSION — must exactly match a name in
#       `provides.commands`. This is the class that catches `/speckit-jira-conifg`.
#
#   (b) AN INVOCATION OF THE BRIDGE — must be given in the repository-relative,
#       per-port form, never as a bare executable name. The install puts NOTHING
#       on PATH, so `spec-kit-jira config` names a command that does not exist in
#       a consuming repository: this is the class that produced the reported
#       "spec-kit-jira CLI not installed" message.
#
#   (c) A HOST COMMAND — must be given in the form the operator actually runs.
#
# What this check CANNOT reach is prose the assistant composes at runtime, which
# is never committed anywhere. That gap is closed differently, by pinning the
# words in the document the assistant reads: see test_agent_fallback_block.bats.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MANIFEST="${ROOT}/extension.yml"
  # Files in scope: every Bash port script, every command document, and the
  # documentation the install SHIPS — the managed README block template lands in
  # every consuming repository, and README.md / INSTALL.md are where an operator
  # copies a command from before any of our code has run. A wrong literal there
  # fails in front of exactly the user who has no way to know better.
  mapfile -t SCOPE < <(
    find "${ROOT}/scripts/bash" -name '*.sh' -type f
    find "${ROOT}/commands" -name '*.md' -type f
    find "${ROOT}/templates" -name '*.template' -type f
    printf '%s\n' "${ROOT}/README.md" "${ROOT}/INSTALL.md"
  )
}

declared_commands() {
  awk '
    /^provides:/ { inprov = 1; next }
    inprov && /^[^[:space:]#]/ { inprov = 0 }
    inprov && /^[[:space:]]+- name:[[:space:]]*/ { sub(/^[[:space:]]+- name:[[:space:]]*/, ""); print }
  ' "${MANIFEST}"
}

# =============================================================================
# (a) Assistant commands
# =============================================================================

@test "every /speckit.jira.* literal matches a declared command name (FR-018 class a)" {
  local declared hits name file
  declared="$(declared_commands)"
  [ -n "${declared}" ]

  # Every command-shaped literal in the dotted form, with or without the slash.
  hits="$(grep -ohE '/?speckit\.jira\.[a-z0-9_-]+' "${SCOPE[@]}" | sed 's|^/||' | LC_ALL=C sort -u)"
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    grep -qxF "${name}" <<< "${declared}" || {
      printf 'message names an undeclared command: %s\n' "${name}" >&2
      file="$(grep -lE "/?${name//./\\.}" "${SCOPE[@]}" | head -n3 | tr '\n' ' ')"
      printf 'seen in: %s\n' "${file}" >&2
      printf 'declared: %s\n' "$(tr '\n' ' ' <<< "${declared}")" >&2
      return 1
    }
  done <<< "${hits}"
}

@test "no message uses the hyphenated /speckit-jira-* form — it resolves to nothing" {
  # This is the exact shape of the reported `/speckit-jira-conifg`: the agent
  # substitutes hyphens for dots when recalling a name from memory, and the
  # result is not a command. Only the dotted form is ever registered.
  run grep -nE '/speckit-jira-[a-z0-9-]+' "${SCOPE[@]}"
  [ "$status" -ne 0 ]
}

# =============================================================================
# (b) Bridge invocations
# =============================================================================

@test "every bridge invocation uses the repository-relative per-port path (FR-014, FR-018 class b)" {
  # An invocation is the bridge name followed by one of its subcommands. The
  # allowed forms are the two entry-point paths and nothing else; a bare name is
  # exactly the assumption that produced the reported defect.
  local bad
  bad="$(grep -nE '(^|[^/])spec-kit-jira(\.sh|\.ps1)?[[:space:]]+(config|reconcile|mention|feature)\b' "${SCOPE[@]}" || true)"
  if [[ -n "${bad}" ]]; then
    printf 'bridge invoked by a bare name (must be the repository-relative per-port path):\n%s\n' "${bad}" >&2
    return 1
  fi
}

@test "the two per-port entry points exist at the paths the messages name" {
  # A message is only runnable as spelled if the path it spells is real.
  [ -f "${ROOT}/scripts/bash/spec-kit-jira.sh" ]
  [ -f "${ROOT}/scripts/powershell/spec-kit-jira.ps1" ]
  # And the Bash entry point must be executable, or invoking it by path — which
  # is what every command document instructs — cannot work after install.
  [ -x "${ROOT}/scripts/bash/spec-kit-jira.sh" ]
}

@test "no message or documented flag names --repair-hooks — it no longer exists (T073)" {
  # It was removed because it existed only to write the hook registry, which
  # FR-022 forbids. A message naming a flag that is now a usage error would be
  # the worst of both worlds.
  #
  # Comment lines in the scripts are exempt: explaining WHY the flag is gone is
  # exactly the kind of note that stops it being reintroduced. Command documents
  # are not exempt — everything in them is read by the assistant as instruction.
  local bad
  bad="$(grep -nE 'repair-hooks' "${SCOPE[@]}" | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "${bad}" ]]; then
    printf 'the removed --repair-hooks flag is still named:\n%s\n' "${bad}" >&2
    return 1
  fi
}

# =============================================================================
# (c) Host commands
# =============================================================================

@test "every 'specify extension add' instruction is spelled as the operator runs it (FR-018 class c)" {
  # An INSTRUCTION carries arguments; a bare `specify extension add` inside prose
  # that explains what the host does is a reference, not something to copy and
  # run, so only the argument-carrying occurrences are checked. Two runnable
  # forms exist and both are accepted: the archive install an operator of a
  # consuming repository runs, and the dev install with --force, which is what
  # someone working on the extension itself runs. Anything else is a third
  # spelling nobody can execute.
  local bad
  bad="$(grep -nE 'specify extension add[[:space:]]+[^`]' "${SCOPE[@]}" \
    | grep -vE 'specify extension add --dev <path-to-spec-kit-jira> --force' \
    | grep -vE 'specify extension add jira --from https://github\.com/Fyloss/spec-kit-jira/archive/refs/heads/main\.zip' || true)"
  if [[ -n "${bad}" ]]; then
    printf 'host install command not in its runnable form:\n%s\n' "${bad}" >&2
    return 1
  fi
}

# =============================================================================
# Cross-check: the literals the reader emits at runtime
# =============================================================================

@test "the repair hints the reader emits pass all three classes (FR-018)" {
  # The hint strings are assembled at runtime from constants, so checking the
  # source is not quite checking the message. Build each one and check the result.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/hooks/register_hooks.sh"
  local work hint declared
  declared="$(declared_commands)"
  work="$(mktemp -d)"

  # missing -> the official install command, in its runnable form.
  hint="$(register_hooks_health "${work}/absent.yml" | jq -r '.repair_hint')"
  [[ "${hint}" == *"specify extension add --dev <path-to-spec-kit-jira> --force"* ]]

  # held disabled -> the release flag on a declared command.
  printf 'hooks: {}\n' > "${work}/e.yml"
  hint="$(register_hooks_health "${work}/e.yml" '["after_plan"]' | jq -r '.repair_hint')"
  [[ "${hint}" == *"/speckit.jira.config --enable-hook after_plan"* ]]
  grep -qxF 'speckit.jira.config' <<< "${declared}"

  # No hint may contain a bare bridge invocation.
  run grep -qE '(^|[^/])spec-kit-jira(\.sh|\.ps1)?[[:space:]]+(config|reconcile)' <<< "${hint}"
  [ "$status" -ne 0 ]

  rm -rf "${work}"
}
