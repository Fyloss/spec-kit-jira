#!/usr/bin/env bash
# engine/naming.sh — Pure feature-naming engine (002 US3, FR 015).
#
# This module is NEUTRAL (Constitution VIII): it knows nothing about tickets,
# projects, or any tracker. It performs four pure string operations —
#
#   * naming_ticket_number : strip an opaque key's leading project prefix,
#   * naming_expand_pattern: substitute <ID> and <FEATURE_NAME> in a pattern,
#   * naming_slug          : build a folder-safe slug from a free description,
#   * naming_short_name    : prefix the slug, never duplicating the prefix.
#
# A pattern's `/` is preserved verbatim (it creates branch hierarchy only); the
# folder short-name is always a single flat component. The file carries no
# key-shaped literal and no tracker vocabulary (boundary grep in the suite).

[[ -n ${_SPECKIT_ENGINE_NAMING:-} ]] && return 0
_SPECKIT_ENGINE_NAMING=1

# naming_ticket_number <key> — the number component of an opaque key: everything
# after the leading upper-case project prefix and its separating hyphen. A value
# that is not prefix-shaped (no upper-case-led prefix followed by a hyphen) is
# returned unchanged.
naming_ticket_number() {
  local key="$1"
  case "${key}" in
    [A-Z]*-*) printf '%s' "${key##*-}" ;;
    *) printf '%s' "${key}" ;;
  esac
}

# naming_expand_pattern <pattern> <id> <feature-name> — substitute the two
# placeholders. Every other character (including `/`) is preserved verbatim.
naming_expand_pattern() {
  local pattern="$1" id="$2" feat="$3"
  pattern="${pattern//<ID>/${id}}"
  pattern="${pattern//<FEATURE_NAME>/${feat}}"
  printf '%s' "${pattern}"
}

# naming_slug <description> — lower-case, collapse every run of non-alphanumeric
# characters to a single hyphen, and trim leading/trailing hyphens.
naming_slug() {
  local s="$1"
  s="$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "${s}" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${s}"
}

# naming_short_name <folder-prefix> <slug> — the flat folder component: the
# prefix followed by the slug, unless the slug already begins with the prefix (in
# which case the prefix is never duplicated).
naming_short_name() {
  local prefix="$1" slug="$2"
  case "${slug}" in
    "${prefix}"*) printf '%s' "${slug}" ;;
    *) printf '%s%s' "${prefix}" "${slug}" ;;
  esac
}
