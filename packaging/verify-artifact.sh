#!/usr/bin/env bash
# packaging/verify-artifact.sh — T036/T037/T038 (026): the bounds gate and the
# completeness/purity gates, fail-closed throughout.
#
# usage:
#   verify-artifact.sh bounds <archive.zip> <manifest-file>
#   verify-artifact.sh completeness-purity <archive.zip>
#   verify-artifact.sh all <archive.zip> <manifest-file>
#
# Every failure names the offending path(s), the measured value and the
# ceiling — never a bare count, never only the first offender (C4.1-C4.3,
# C3.5). Every "cannot determine" case — an absent archive, an unreadable or
# unparseable manifest, a git error, an empty derived surface — fails the
# gate rather than passing it silently (C4.4, C5.3).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=packaging/lib/surface.sh
source "${SELF_DIR}/lib/surface.sh"

# Bounds — stated in exactly ONE place, with the rationale beside them
# (contracts/artifact-shape.md C3.1-C3.2): half the host's own ceiling for
# entries, half its byte ceilings, so a doubling of the shipped surface is
# what trips the gate rather than anything a user would experience.
readonly VERIFY_MAX_ENTRIES=256
readonly VERIFY_MAX_UNCOMPRESSED_BYTES=$((25 * 1024 * 1024))
readonly VERIFY_MAX_MEMBER_BYTES=$((5 * 1024 * 1024))
readonly VERIFY_MAX_PATH_BYTES=1024
readonly VERIFY_MAX_COMPONENT_BYTES=128
# Windows-invalid filename characters and reserved device names (C3.3),
# discovered only by a Windows consumer otherwise, after publication.
readonly VERIFY_WINDOWS_RESERVED_RE='^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.[^.]*)?$'

_VERIFY_FAIL=0

_verify_report() {
  printf '%s\n' "$1" >&2
  _VERIFY_FAIL=1
}

# _verify_zip_members <archive> — every member path, one per line. Uses
# Python's zipfile rather than `unzip -Z1`: BSD unzip (macOS) silently
# truncates names near ~1023 bytes ("filename too long--truncating"), which
# would hide exactly the path-length violation this gate exists to catch.
_verify_zip_members() {
  python3 -c '
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as zf:
        for n in zf.namelist():
            print(n)
except Exception:
    sys.exit(1)
' "$1"
}

# verify_bounds <archive> <manifest> — the entry/size/path bounds (C3.1-C3.5).
verify_bounds() {
  local archive="$1" manifest="$2"
  if [[ ! -f "${archive}" ]]; then
    _verify_report "verify-artifact: archive not found: ${archive}"
    return
  fi
  if [[ ! -f "${manifest}" ]]; then
    _verify_report "verify-artifact: manifest not found: ${manifest}"
    return
  fi

  local entries uncompressed largest_bytes largest_path
  entries="$(sed -n 's/^entries: //p' "${manifest}")"
  uncompressed="$(sed -n 's/^uncompressed_bytes: //p' "${manifest}")"
  largest_bytes="$(sed -n 's/^largest_member_bytes: //p' "${manifest}")"
  largest_path="$(sed -n 's/^largest_member_path: //p' "${manifest}")"

  # Exactly one line per field, and a numeric value for every count/size
  # field: a duplicated field or a non-numeric value would otherwise reach
  # `((entries > ceiling))` below, which throws a bash arithmetic syntax
  # error that `set -u` does not catch — the check is silently skipped
  # rather than failing closed. A duplicate is never "first one wins";
  # it fails the same as any other unparseable manifest.
  if [[ "$(wc -l <<< "${entries}")" -ne 1 || "$(wc -l <<< "${uncompressed}")" -ne 1 \
    || "$(wc -l <<< "${largest_bytes}")" -ne 1 || "$(wc -l <<< "${largest_path}")" -ne 1 \
    || ! "${entries}" =~ ^[0-9]+$ || ! "${uncompressed}" =~ ^[0-9]+$ \
    || ! "${largest_bytes}" =~ ^[0-9]+$ || -z "${largest_path}" ]]; then
    _verify_report "verify-artifact: manifest is unparseable: ${manifest}"
    return
  fi

  if ((entries > VERIFY_MAX_ENTRIES)); then
    _verify_report "verify-artifact: too many entries: ${entries} exceeds the ceiling of ${VERIFY_MAX_ENTRIES}"
  fi
  if ((uncompressed > VERIFY_MAX_UNCOMPRESSED_BYTES)); then
    _verify_report "verify-artifact: uncompressed total too large: ${uncompressed} bytes exceeds the ceiling of ${VERIFY_MAX_UNCOMPRESSED_BYTES} bytes"
  fi
  if ((largest_bytes > VERIFY_MAX_MEMBER_BYTES)); then
    _verify_report "verify-artifact: largest member too large: ${largest_path} is ${largest_bytes} bytes, exceeding the ceiling of ${VERIFY_MAX_MEMBER_BYTES} bytes"
  fi

  local members
  members="$(_verify_zip_members "${archive}")"
  if [[ -z "${members}" ]]; then
    _verify_report "verify-artifact: could not list archive members: ${archive}"
    return
  fi

  local m len comp parts
  while IFS= read -r m; do
    [[ -z "${m}" ]] && continue
    len=${#m}
    if ((len > VERIFY_MAX_PATH_BYTES)); then
      _verify_report "verify-artifact: path too long (${len} bytes exceeds the ceiling of ${VERIFY_MAX_PATH_BYTES}): ${m}"
    fi
    IFS='/' read -ra parts <<< "${m}"
    for comp in "${parts[@]}"; do
      [[ -z "${comp}" ]] && continue
      if ((${#comp} > VERIFY_MAX_COMPONENT_BYTES)); then
        _verify_report "verify-artifact: path component too long (${#comp} bytes exceeds the ceiling of ${VERIFY_MAX_COMPONENT_BYTES}) in: ${m}"
      fi
      case "${comp}" in
        *'<'* | *'>'* | *':'* | *'"'* | *'|'* | *'?'* | *'*'*)
          _verify_report "verify-artifact: Windows-invalid character in path component '${comp}': ${m}"
          ;;
      esac
      if [[ "${comp}" =~ ${VERIFY_WINDOWS_RESERVED_RE} ]]; then
        _verify_report "verify-artifact: Windows-reserved device name in path component '${comp}': ${m}"
      fi
    done
  done <<< "${members}"
}

# verify_completeness_purity <archive> — the archive's contents equal the
# derived surface, in both directions (C2.1, surface-derivation.md C4.1-C4.4).
# The derivation is the primary check (fast, no `specify` needed); a real
# `--dev` install corroborates it, exactly as data-model.md's diagram has it.
verify_completeness_purity() {
  local archive="$1"
  if [[ ! -f "${archive}" ]]; then
    _verify_report "verify-artifact: archive not found: ${archive}"
    return
  fi

  local expected archived
  if ! expected="$(packaging_derive_surface)"; then
    _verify_report "verify-artifact: could not derive the installable surface (git error, or an unreadable .extensionignore)"
    return
  fi
  if [[ -z "${expected}" ]]; then
    _verify_report "verify-artifact: derived surface is empty — refusing to treat that as 'nothing missing'"
    return
  fi
  expected="$(LC_ALL=C sort <<< "${expected}")"

  archived="$(_verify_zip_members "${archive}" | sed -e 's#^spec-kit-jira/##' -e '/\/$/d' -e '/^$/d' | LC_ALL=C sort)"
  if [[ -z "${archived}" ]]; then
    _verify_report "verify-artifact: could not list archive members: ${archive}"
    return
  fi

  # `comm` reads under its own ambient collation, not whichever collation
  # sorted `expected`/`archived` above — LC_ALL=C here too (see surface.sh).
  local missing extra
  missing="$(LC_ALL=C comm -23 <(printf '%s\n' "${expected}") <(printf '%s\n' "${archived}"))"
  extra="$(LC_ALL=C comm -13 <(printf '%s\n' "${expected}") <(printf '%s\n' "${archived}"))"

  if [[ -n "${missing}" ]]; then
    _verify_report "verify-artifact: the archive is missing files the reference install produced:"
    _verify_report "${missing}"
  fi
  if [[ -n "${extra}" ]]; then
    _verify_report "verify-artifact: the archive contains files the exclusion list excludes:"
    _verify_report "${extra}"
  fi

  _verify_corroborate_with_dev_install "${expected}"
}

# _verify_corroborate_with_dev_install <expected> — a real `--dev` install,
# checked against the SAME expected set. `specify` is optional here: its
# absence is reported but does not itself fail the gate, since the primary
# check above already ran. `.specify-dev/agent-commands/…` is generated by
# the installer AFTER the copy (research R5) and is excluded, exactly as the
# reference-copy contaminants table in data-model.md records.
_verify_corroborate_with_dev_install() {
  local expected="$1"
  command -v specify > /dev/null 2>&1 || return 0

  # Captured BEFORE cd'ing into the consumer fixture below — packaging_repo_root
  # calls `git rev-parse --show-toplevel`, which would otherwise resolve to the
  # fixture's own (freshly `git init`'d) root instead of this extension's.
  local extension_root
  extension_root="$(packaging_repo_root)" || return

  local repo
  repo="$(mktemp -d)"
  (
    cd "${repo}" || exit 1
    git init -q . > /dev/null 2>&1 || true
    specify init --here --force --integration claude --script sh --ignore-agent-tools \
      > "${repo}/.verify-init.log" 2>&1
  )
  (
    cd "${repo}" || exit 1
    specify extension add --dev "${extension_root}" --force \
      > "${repo}/.verify-dev-install.log" 2>&1
  )

  local reference_dir="${repo}/.specify/extensions/jira-mirror"
  if [[ ! -d "${reference_dir}" ]]; then
    _verify_report "verify-artifact: the --dev corroboration install failed; see ${repo}/.verify-dev-install.log"
    rm -rf "${repo}"
    return
  fi

  local installed
  installed="$(cd "${reference_dir}" && find . -type f -not -path './.specify-dev/*' | sed 's|^\./||' | LC_ALL=C sort)"
  rm -rf "${repo}"

  if [[ "${installed}" != "${expected}" ]]; then
    _verify_report "verify-artifact: the derived surface disagrees with a real --dev install — the two routes no longer agree"
  fi
}

_usage() {
  printf 'usage: %s bounds <archive> <manifest> | completeness-purity <archive> | all <archive> <manifest>\n' \
    "$(basename "$0")" >&2
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    bounds)
      [[ $# -eq 3 ]] || { _usage; exit 1; }
      verify_bounds "$2" "$3"
      ;;
    completeness-purity)
      [[ $# -eq 2 ]] || { _usage; exit 1; }
      verify_completeness_purity "$2"
      ;;
    all)
      [[ $# -eq 3 ]] || { _usage; exit 1; }
      verify_bounds "$2" "$3"
      verify_completeness_purity "$2"
      ;;
    *)
      _usage
      exit 1
      ;;
  esac
  exit "${_VERIFY_FAIL}"
}

main "$@"
