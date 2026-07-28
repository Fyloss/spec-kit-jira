#!/usr/bin/env bats
# T057 [US6] — No code path in the Bash port can open the hook registry for
# writing (FR-022, SC-011).
#
# This is the mechanical enforcement of the feature's load-bearing constraint.
# The behavioural test (test_registry_never_written.bats) proves the registry is
# byte-identical after every documented state; this one proves something the
# behavioural test cannot, because no test suite enumerates every future state:
# that the CAPABILITY to write it does not exist in the source at all.
#
# It exists because the guarantee has to survive people. A later feature adding
# "just one small write" in good faith — to repair a missing entry, to realign a
# field, to migrate a leftover — would pass every behavioural test that does not
# happen to exercise its trigger. This check fails the build the moment the
# construct appears, whether or not anything calls it.
#
# Why it matters that this is unconditional: the extension's YAML reader models a
# deliberately restricted subset and drops every comment (research R3), so ANY
# write it performs silently damages a file the operator is invited to edit and
# other extensions co-own. There is no safe write, so there is no exempted state.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPTS="${ROOT}/scripts/bash"
  # Everything that could denote the registry: the literal path, the environment
  # override, and the two local names the code uses for it.
  REGISTRY_TOKENS='extensions\.yml|SPEC_KIT_JIRA_EXTENSIONS_YML|ext_path'
}

# offending <regex> — print matching non-comment lines across the Bash port.
offending() {
  grep -rnE "$1" "${SCRIPTS}" --include='*.sh' \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true
}

@test "no redirection writes to the registry (FR-022)" {
  local bad
  bad="$(offending ">>?[[:space:]]*\"?\\\$\\{?(${REGISTRY_TOKENS})")"
  [ -z "${bad}" ] || { printf 'redirection into the hook registry:\n%s\n' "${bad}" >&2; return 1; }
}

@test "no mv/cp/rm/tee/truncate/sed -i targets the registry (FR-022)" {
  local bad
  bad="$(offending "\\b(mv|cp|rm|tee|truncate|install)\\b[^|]*(${REGISTRY_TOKENS})")"
  [ -z "${bad}" ] || { printf 'file-mutating command targeting the hook registry:\n%s\n' "${bad}" >&2; return 1; }
  bad="$(offending "sed[[:space:]]+-i[^|]*(${REGISTRY_TOKENS})")"
  [ -z "${bad}" ] || { printf 'in-place sed targeting the hook registry:\n%s\n' "${bad}" >&2; return 1; }
}

@test "no mkdir prepares a directory for the registry (FR-022)" {
  # Creating the parent directory is only ever a prelude to creating the file.
  local bad
  bad="$(offending "mkdir[^|]*(${REGISTRY_TOKENS})")"
  [ -z "${bad}" ] || { printf 'mkdir for the hook registry path:\n%s\n' "${bad}" >&2; return 1; }
}

@test "the registry path is never passed to the config-file writer (FR-022)" {
  # config_to_yaml is the serialiser every file this extension DOES own goes
  # through. Reaching it with the registry path is the exact shape of the write
  # this feature removed.
  local bad
  bad="$(offending "config_to_yaml[^|]*(${REGISTRY_TOKENS})")"
  [ -z "${bad}" ] || { printf 'registry path piped to the config serialiser:\n%s\n' "${bad}" >&2; return 1; }
  bad="$(offending "(${REGISTRY_TOKENS})[^|]*\\|[[:space:]]*config_to_yaml")"
  [ -z "${bad}" ] || { printf 'registry path piped to the config serialiser:\n%s\n' "${bad}" >&2; return 1; }
}

@test "the deleted writer has not come back under any name (FR-022, SC-011)" {
  run grep -rnE 'register_hooks_write|_register_hooks_merge|_register_hooks_entry' "${SCRIPTS}" --include='*.sh'
  [ "$status" -ne 0 ]
}

@test "the hooks module names no write construct at all (SC-011)" {
  # Belt and braces on the one module that handles the registry path: it must
  # contain no file-mutating verb whatsoever, on any line, for any file. The
  # module's whole job is to read and classify, so there is nothing it could
  # legitimately be writing.
  local module="${SCRIPTS}/hooks/register_hooks.sh"
  local bad
  bad="$(grep -nE '(^|[^a-z_])(mv|cp|rm|tee|truncate|mkdir|touch)[[:space:]]|sed[[:space:]]+-i|>[[:space:]]*"?\$' "${module}" \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  [ -z "${bad}" ] || { printf 'write construct in the read-only hooks module:\n%s\n' "${bad}" >&2; return 1; }
}

@test "config_to_yaml — the writer for files we DO own — is never reached with the registry" {
  # The serialiser every file this extension owns goes through. A registry path
  # arriving here is the exact shape of the write this feature removed, and the
  # one a later feature would most plausibly reintroduce.
  local bad
  bad="$(grep -rn 'config_to_yaml' "${SCRIPTS}" --include='*.sh' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    | grep -E "${REGISTRY_TOKENS}" || true)"
  [ -z "${bad}" ] || { printf 'registry path reaching the config serialiser:\n%s\n' "${bad}" >&2; return 1; }
}
