#!/usr/bin/env bash
# packaging/lib/surface.sh — the one place the installable surface is derived
# (contracts/surface-derivation.md C2.1-C2.4). `packaging/build-artifact.sh`
# and `packaging/verify-artifact.sh` both source this file; nothing else may
# compute or enumerate the surface.
#
# Delegates exclusion semantics entirely to git (C2.2): no gitignore syntax is
# interpreted here, only `git ls-files` and `git check-ignore` are called.

[[ -n ${_JIRA_PACKAGING_SURFACE:-} ]] && return 0
_JIRA_PACKAGING_SURFACE=1

# packaging_repo_root — the repository root, independent of the caller's
# working directory (C2.4).
packaging_repo_root() {
  git rev-parse --show-toplevel
}

# packaging_derive_surface — print the derived installable surface, one
# repository-relative path per line, sorted. Fails (non-zero, nothing
# printed) on any git error; an empty result is a legitimate output the
# caller must check for itself (C5.2/C5.3 — "cannot determine" is the
# caller's problem to fail on, not this function's to hide).
packaging_derive_surface() {
  local root candidates ignored
  root="$(packaging_repo_root)" || return 1

  candidates="$(git -C "${root}" ls-files)" || return 1
  [[ -n "${candidates}" ]] || return 1

  # `check-ignore --stdin` exits 1 when NONE of the given paths are ignored —
  # that is a legitimate outcome here (nothing excluded), not an error. Exit
  # 128 (or anything else) is a real failure — an unreadable
  # `.extensionignore`, for one — and must NOT be folded into "nothing
  # excluded", or an unreadable exclusion list would silently widen the
  # surface to every tracked file instead of failing the gate (C4.4).
  local ignore_status=0
  ignored="$(git -C "${root}" -c core.excludesFile=.extensionignore \
    check-ignore --no-index --stdin <<< "${candidates}")" || ignore_status=$?
  if ((ignore_status != 0 && ignore_status != 1)); then
    return 1
  fi

  comm -23 <(LC_ALL=C sort <<< "${candidates}") <(LC_ALL=C sort <<< "${ignored}") \
    | grep -vxF '.extensionignore' || true
}
