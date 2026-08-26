#!/usr/bin/env bash
# tests/conformance/install-harness.sh — T001: the scratch-repo install harness.
#
# Makes "what the official install actually writes" observable. Without it User
# Story 1 cannot be tested at all: the whole claim of feature 003 is that
# `specify extension add` alone registers the seven lifecycle events, and that
# claim is only checkable against a real install into a real scratch repository.
#
# The harness is a SOURCEABLE library (bats sources it) that also runs
# standalone: executed directly it performs a fresh install into a temporary
# directory and prints the resulting registry.
#
#   source tests/conformance/install-harness.sh
#   harness_require || skip "${HARNESS_SKIP_REASON}"
#   repo="$(harness_new_repo)"          # specify init --here --integration claude
#   harness_seed_registry "${repo}" '…' # optional pre-existing registry content
#   harness_install "${repo}"           # specify extension add --dev <root>
#   harness_install "${repo}" --force   # repeated reinstall
#   harness_registry "${repo}"          # print .specify/extensions.yml
#   harness_registry_checksum "${repo}" # checksum over that file
#   harness_cleanup "${repo}"
#
# Nothing here writes outside the scratch directory it creates.

[[ -n ${_JIRA_INSTALL_HARNESS:-} ]] && return 0
_JIRA_INSTALL_HARNESS=1

_harness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The extension repository under test: two levels above tests/conformance/.
HARNESS_EXTENSION_ROOT="${HARNESS_EXTENSION_ROOT:-$(cd "${_harness_dir}/../.." && pwd)}"

# The registry path inside a consuming repository.
HARNESS_REGISTRY_REL='.specify/extensions.yml'

# Set by harness_require when the harness cannot run.
HARNESS_SKIP_REASON=''

# harness_require — 0 when the `specify` CLI is available, 1 otherwise with a
# clear reason in HARNESS_SKIP_REASON. Callers skip rather than fail: the CLI is
# a developer tool, not a runtime dependency of this extension.
harness_require() {
  HARNESS_SKIP_REASON=''
  if ! command -v specify > /dev/null 2>&1; then
    HARNESS_SKIP_REASON="the 'specify' CLI is not installed — install it with: uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
    return 1
  fi
  return 0
}

# harness_new_repo — create a scratch directory, run `specify init --here
# --integration claude` in it, and print its absolute path. The caller owns the
# directory and removes it with harness_cleanup.
#
# `--force` because `git init` already made the directory non-empty and the CLI
# would otherwise stop for confirmation; `--ignore-agent-tools` because the agent
# binary is irrelevant to what this harness observes — the contents of
# `.specify/extensions.yml`.
harness_new_repo() {
  local repo
  repo="$(mktemp -d)"
  (
    cd "${repo}" || exit 1
    git init -q . > /dev/null 2>&1 || true
    specify init --here --integration claude --force --ignore-agent-tools \
      > "${repo}/.harness-init.log" 2>&1
  ) || {
    printf 'install-harness: specify init failed; see %s/.harness-init.log\n' "${repo}" >&2
    printf '%s' "${repo}"
    return 1
  }
  printf '%s' "${repo}"
}

# harness_seed_registry <repo> <yaml-text> — place pre-existing registry content
# (a foreign extension's entries, an operator comment, a leftover pre-manifest
# entry) before the install runs. This is how the "neighbourly" and "leftover"
# states are set up.
harness_seed_registry() {
  local repo="$1" content="$2"
  mkdir -p "${repo}/.specify"
  printf '%s\n' "${content}" > "${repo}/${HARNESS_REGISTRY_REL}"
}

# harness_install <repo> [extra args…] — run `specify extension add --dev <root>`
# inside the repository. Repeated calls with --force are the reinstall path.
harness_install() {
  local repo="$1"
  shift
  (
    cd "${repo}" || exit 1
    specify extension add --dev "${HARNESS_EXTENSION_ROOT}" "$@" > "${repo}/.harness-install.log" 2>&1
  )
}

# harness_uninstall <repo> — run `specify extension remove jira-mirror`. `--force`
# skips the interactive confirmation, which would otherwise hang a test run.
harness_uninstall() {
  local repo="$1"
  (
    cd "${repo}" || exit 1
    specify extension remove jira-mirror --force > "${repo}/.harness-uninstall.log" 2>&1
  )
}

# harness_registry <repo> — print the registry, or nothing when it does not exist.
harness_registry() {
  local repo="$1" path="${1}/${HARNESS_REGISTRY_REL}"
  [[ -f "${path}" ]] || return 0
  cat "${path}"
}

# harness_registry_path <repo> — the absolute registry path.
harness_registry_path() {
  printf '%s' "${1}/${HARNESS_REGISTRY_REL}"
}

# harness_registry_checksum <repo> — a stable checksum over the registry file.
# The SC-007 assertions compare this before and after each command run. An
# absent file checksums as the empty string, so "absent" and "present but empty"
# stay distinguishable from a real digest.
harness_registry_checksum() {
  local path="${1}/${HARNESS_REGISTRY_REL}"
  [[ -f "${path}" ]] || return 0
  if command -v shasum > /dev/null 2>&1; then
    shasum -a 256 < "${path}" | awk '{print $1}'
  else
    sha256sum < "${path}" | awk '{print $1}'
  fi
}

# harness_entries_for <repo> <event> — print one line per registry entry under
# the event, as `<extension>\t<command>\t<enabled>\t<optional>`. Absent fields
# print as `-`. Parsed with the extension's own reader so the harness needs no
# yq; the reader's restricted subset is adequate for what the install writes.
harness_entries_for() {
  local repo="$1" event="$2" path="${1}/${HARNESS_REGISTRY_REL}"
  [[ -f "${path}" ]] || return 0
  # shellcheck source=/dev/null
  source "${HARNESS_EXTENSION_ROOT}/scripts/bash/lib/config.sh"
  local json
  json="$(config_yaml_to_json "${path}" 2> /dev/null)" || return 0
  jq -r --arg e "${event}" '
    (.hooks[$e] // []) | .[] |
    [ (.extension // "-"), (.command // "-"),
      (.enabled | tostring), (.optional | tostring) ] | @tsv
  ' <<< "${json}"
}

# harness_cleanup <repo> — remove a scratch repository.
harness_cleanup() {
  local repo="$1"
  [[ -n "${repo}" && -d "${repo}" && "${repo}" == /* ]] || return 0
  rm -rf "${repo}"
}

# Standalone: install into a fresh scratch repository and print the registry.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if ! harness_require; then
    printf 'install-harness: skipped — %s\n' "${HARNESS_SKIP_REASON}" >&2
    exit 0
  fi
  _repo="$(harness_new_repo)"
  harness_install "${_repo}"
  printf '# %s/%s\n' "${_repo}" "${HARNESS_REGISTRY_REL}"
  harness_registry "${_repo}"
  harness_cleanup "${_repo}"
fi
