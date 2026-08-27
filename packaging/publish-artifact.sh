#!/usr/bin/env bash
# packaging/publish-artifact.sh — T043 (026): the publication DECISIONS —
# tag-versus-manifest cross-check, two asset names from one archive, refusal
# to overwrite — live here rather than in release.yml, so bats can drive them
# directly with a `gh` stub on PATH (contracts/publication.md C2.7).
#
# usage: publish-artifact.sh <tag> <archive-path>
#
# Creates the GitHub Release for <tag> if none exists yet (SC-008 "zero
# manual steps" requires it: pushing a tag does not itself create a Release
# object, and `…/releases/latest/download/…` resolves against one — settling
# the open question at contracts/publication.md C2.7). Every `gh` call goes
# through the one _gh() indirection below.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Global, not `local` to main(): an EXIT trap fires after main() has already
# returned, so a `local` work dir would be out of scope by the time the trap
# runs, tripping `set -u` on cleanup.
WORK_DIR=""
trap '[[ -n "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"' EXIT

_gh() {
  command gh "$@"
}

_usage() {
  printf 'usage: %s <tag> <archive-path>\n' "$(basename "$0")" >&2
}

main() {
  local tag="${1:-}" archive="${2:-}"
  if [[ -z "${tag}" || -z "${archive}" ]]; then
    _usage
    exit 1
  fi
  if [[ ! -f "${archive}" ]]; then
    printf 'publish-artifact: archive not found: %s\n' "${archive}" >&2
    exit 1
  fi

  local version
  version="$("${SELF_DIR}/resolve-version.sh")" || exit 1

  # Accepts both `v1.2.3` and `1.2.3` tag spellings (C2.2).
  local tag_version="${tag#v}"
  if [[ "${tag_version}" != "${version}" ]]; then
    printf 'publish-artifact: tag names version "%s" but extension.yml says "%s" — refusing to publish\n' \
      "${tag_version}" "${version}" >&2
    exit 1
  fi

  WORK_DIR="$(mktemp -d)"

  # Two names, one archive (A4): both copies carry identical bytes because
  # both come from the SAME built file, never from separate builds.
  local stable_name="spec-kit-jira-mirror.zip"
  local pinned_name="spec-kit-jira-mirror-${version}.zip"
  cp "${archive}" "${WORK_DIR}/${stable_name}"
  cp "${archive}" "${WORK_DIR}/${pinned_name}"

  if ! _gh release view "${tag}" > /dev/null 2>&1; then
    if ! _gh release create "${tag}" --title "${tag}" --notes "spec-kit-jira ${version}"; then
      printf 'publish-artifact: could not create the release for tag %s\n' "${tag}" >&2
      exit 1
    fi
  fi

  local existing
  if ! existing="$(_gh release view "${tag}" --json assets --jq '.assets[].name' 2>&1)"; then
    printf 'publish-artifact: could not read the existing assets for %s: %s\n' "${tag}" "${existing}" >&2
    exit 1
  fi

  local name
  for name in "${stable_name}" "${pinned_name}"; do
    if grep -qxF "${name}" <<< "${existing}"; then
      printf 'publish-artifact: %s already carries an asset named %s — refusing to overwrite it silently\n' \
        "${tag}" "${name}" >&2
      exit 1
    fi
  done

  local -a uploaded=()
  local path base
  for path in "${WORK_DIR}/${stable_name}" "${WORK_DIR}/${pinned_name}"; do
    base="$(basename "${path}")"
    if ! _gh release upload "${tag}" "${path}"; then
      printf 'publish-artifact: upload failed for %s — removing any asset this run already attached, so no partially-correct release is left\n' \
        "${base}" >&2
      local u
      for u in "${uploaded[@]}"; do
        _gh release delete-asset "${tag}" "${u}" --yes > /dev/null 2>&1 || true
      done
      exit 1
    fi
    uploaded+=("${base}")
  done
}

main "$@"
