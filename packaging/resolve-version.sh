#!/usr/bin/env bash
# packaging/resolve-version.sh — the one place the extension's version is
# read (contracts/publication.md C1.1-C1.3). Prints `extension.version` on
# stdout, or fails loudly on an absent or empty field.
#
# Uses the SAME sed expression as the existing "Version literal
# single-sourced" CI job (.github/workflows/gates.yml), so there is one
# reading behaviour, not two. That expression matches the indented
# `version:` key under `extension:` — never the top-level `schema_version`
# or `requires.speckit_version`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT}/extension.yml"

if [[ ! -f "${MANIFEST}" ]]; then
  printf 'resolve-version: manifest not found: %s\n' "${MANIFEST}" >&2
  exit 1
fi

version="$(sed -n 's/^[[:space:]]\{1,\}version:[[:space:]]*//p' "${MANIFEST}" | head -n1)"

if [[ -z "${version}" ]]; then
  printf 'resolve-version: extension.version is absent or empty in %s\n' "${MANIFEST}" >&2
  exit 1
fi

printf '%s\n' "${version}"
