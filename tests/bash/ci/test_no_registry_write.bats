#!/usr/bin/env bats
# 034 [FR-001, FR-010, SC-002] — No code path in the Bash port can open the hook
# registry AT ALL: not for writing, and now not for reading either.
#
# This file used to enumerate write verbs — redirection, mv/cp/rm/tee/truncate,
# sed -i, mkdir, the config serialiser — because a write can be spelled many
# ways and the extension still legitimately READ the file. Constitution 4.0.0
# withdrew that permission and widened the prohibition: an extension that cannot
# repair a fact must not assert it, so this port must not open
# `.specify/extensions.yml` in any state, for any purpose.
#
# That makes the check categorically simpler AND stronger. A path the port
# cannot name cannot be written, so the absence test below subsumes every
# write-verb test it replaces. There is no exempted state and no safe spelling.
#
# It exists because the guarantee has to survive people. A later feature adding
# "just one small read" in good faith — to warn about a missing entry, to
# classify a duplicate, to check a version — would pass every behavioural test
# that does not happen to exercise its trigger. This fails the build the moment
# the token appears, whether or not anything calls it.
#
# SPEC_KIT_JIRA_GUARD_ROOT points the scan at a different tree, which is how
# this guard is demonstrated RED against the pre-change port (034 T007):
#
#   PRE=$(mktemp -d) && git archive HEAD scripts | tar -x -C "$PRE"
#   SPEC_KIT_JIRA_GUARD_ROOT="$PRE/scripts/bash" bats tests/bash/ci/test_no_registry_write.bats
#
# A guard nobody has watched fail is not known to work: two of three guards
# shipped in a previous feature here were inert, and an inert guard is silent
# about it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPTS="${SPEC_KIT_JIRA_GUARD_ROOT:-${ROOT}/scripts/bash}"
  # Everything that could denote the registry: the literal path and the
  # environment override that used to redirect it. `ext_path`, the old local
  # name, is gone with the code that declared it.
  REGISTRY_TOKENS='extensions\.yml|SPEC_KIT_JIRA_EXTENSIONS_YML'
  # NO file-level allowlist, deliberately. scan() already drops comment lines,
  # so the prohibition's own explanatory comments are exempt by construction. A
  # file exemption on top of that could only ever let real CODE through — it
  # would weaken the guard rather than express it.
}

# scan <regex> — matching NON-COMMENT lines across the port.
scan() {
  grep -rnE "$1" "${SCRIPTS}" --include='*.sh' \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true
}

@test "the guard reads a non-empty tree — the instrument check" {
  # If SCRIPTS pointed at nothing, every test below would pass while checking
  # nothing at all. That failure mode is invisible from the outside, so it is
  # asserted first and explicitly.
  [ -d "${SCRIPTS}" ]
  local n
  n="$(find "${SCRIPTS}" -name '*.sh' | wc -l | tr -d ' ')"
  [ "${n}" -gt 20 ]
}

@test "the registry is never named outside an explanatory comment (FR-001, SC-002)" {
  # The load-bearing test. A path that cannot be named cannot be opened — for
  # reading or for writing — so this subsumes every write-verb check this file
  # used to carry.
  local bad
  bad="$(scan "${REGISTRY_TOKENS}")"
  [ -z "${bad}" ] || { printf 'the hook registry is named in shipped code:\n%s\n' "${bad}" >&2; return 1; }
}

@test "the deleted reader has not come back under any name (FR-001)" {
  # The module and every symbol it exported. A reintroduction under a new file
  # name still has to spell one of these to be useful.
  local bad
  bad="$(find "${SCRIPTS}" -name 'register_hooks.sh')"
  [ -z "${bad}" ] || { printf 'the deleted hooks module is back: %s\n' "${bad}" >&2; return 1; }
  bad="$(scan 'register_hooks_|HOOK_EXTENSION_ID|HOOK_COMMAND|HOOK_BEFORE_')"
  [ -z "${bad}" ] || { printf 'a symbol of the deleted reader is back:\n%s\n' "${bad}" >&2; return 1; }
}

@test "no read verb is aimed at a registry-shaped path (FR-001)" {
  # Subsumed by the absence test above, and kept anyway: it names the failure
  # concretely when someone reintroduces a read, which is friendlier than a
  # bare "the registry is named here".
  local bad
  bad="$(scan '(cat|source|\.|jq|read|<)[^|]*extensions\.yml')"
  [ -z "${bad}" ] || { printf 'a read aimed at the hook registry:\n%s\n' "${bad}" >&2; return 1; }
}

@test "the operator disable record has no reader or writer left (FR-005)" {
  # `hooks.disabled` was the only thing the extension wrote in response to what
  # it read in the registry. Retired with it; its accessors must not survive.
  local bad
  bad="$(scan 'config_hooks_disabled')"
  [ -z "${bad}" ] || { printf 'the retired disable record is still accessed:\n%s\n' "${bad}" >&2; return 1; }
}
