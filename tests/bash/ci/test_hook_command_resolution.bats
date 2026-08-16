#!/usr/bin/env bats
# T031 [US3] — Every registered hook resolves to a real command (FR-009, SC-002).
#
# The second half of the reported defect. `extension.yml` declared two commands;
# the registrar registered `speckit.jira.reconcile` under all six after_* events.
# That command had NO file, NO manifest entry, and was not installed. Every
# registered after_* hook pointed at a command the agent could not resolve — so
# even a correctly registered, correctly dispatched hook resolved to nothing.
#
# Three sets must agree, and nothing at runtime checks that they do:
#   1. the `command` of every entry in the top-level `hooks:` block,
#   2. the `name` of every entry in `provides.commands`,
#   3. the files in `commands/`.
#
# The manifest is parsed with awk rather than with the extension's own YAML
# reader: extension.yml uses `>-` folded block scalars, which that reader's
# restricted subset does not model.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MANIFEST="${ROOT}/extension.yml"
}

# declared_commands — the `name:` of every entry under provides.commands.
declared_commands() {
  awk '
    /^provides:/ { inprov = 1; next }
    inprov && /^[^[:space:]#]/ { inprov = 0 }
    inprov && /^[[:space:]]+- name:[[:space:]]*/ { sub(/^[[:space:]]+- name:[[:space:]]*/, ""); print }
  ' "${MANIFEST}"
}

# declared_command_files — the `file:` of every entry under provides.commands.
declared_command_files() {
  awk '
    /^provides:/ { inprov = 1; next }
    inprov && /^[^[:space:]#]/ { inprov = 0 }
    inprov && /^[[:space:]]+file:[[:space:]]*/ { sub(/^[[:space:]]+file:[[:space:]]*/, ""); print }
  ' "${MANIFEST}"
}

# hook_commands — the `command:` of every entry in the top-level hooks: block.
hook_commands() {
  awk '
    /^hooks:/ { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock && /^[[:space:]]+command:[[:space:]]*/ { sub(/^[[:space:]]+command:[[:space:]]*/, ""); print }
  ' "${MANIFEST}"
}

@test "every hooks[].command matches a provides.commands[].name exactly (SC-002)" {
  local declared cmd
  declared="$(declared_commands)"
  [ -n "${declared}" ]
  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    grep -qxF "${cmd}" <<< "${declared}" || {
      printf 'hook references an undeclared command: %s\n' "${cmd}" >&2
      printf 'declared: %s\n' "$(tr '\n' ' ' <<< "${declared}")" >&2
      return 1
    }
  done <<< "$(hook_commands)"
}

@test "every declared command's file: exists on disk (research R7)" {
  local f
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    [ -f "${ROOT}/${f}" ] || {
      printf 'declared command file does not exist: %s\n' "${f}" >&2
      return 1
    }
  done <<< "$(declared_command_files)"
}

@test "every command document's front-matter name matches its manifest declaration" {
  # A document whose front matter disagrees with the manifest is registered under
  # one name and answers to another — the same class of unresolvable reference,
  # one level down.
  local names files i=0
  names="$(declared_commands)"
  files="$(declared_command_files)"
  local n f frontmatter
  while IFS= read -r n && IFS= read -r f <&3; do
    [[ -z "${n}" ]] && continue
    frontmatter="$(awk 'NR > 1 && /^---[[:space:]]*$/ { exit } NR > 1 { print }' "${ROOT}/${f}")"
    grep -qE "^name:[[:space:]]*\"?${n}\"?[[:space:]]*$" <<< "${frontmatter}" || {
      printf '%s declares name != %s\n' "${f}" "${n}" >&2
      return 1
    }
    i=$((i + 1))
  done <<< "${names}" 3<<< "${files}"
  [ "${i}" -eq 4 ]
}

@test "speckit.jira.reconcile is declared, filed and referenced (FR-010, FR-011)" {
  # The command that did not exist. Named explicitly because it is THE finding of
  # research R7 and the co-requisite of the manifest's hook block.
  run grep -qxF 'speckit.jira.reconcile' <<< "$(declared_commands)"
  [ "$status" -eq 0 ]
  [ -f "${ROOT}/commands/speckit.jira.reconcile.md" ]
  run grep -qxF 'speckit.jira.reconcile' <<< "$(hook_commands)"
  [ "$status" -eq 0 ]
}

@test "no hook command uses the short jira.<name> form the host auto-lifts with a warning" {
  local cmd
  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    [[ "${cmd}" == speckit.jira.* ]] || {
      printf 'hook command is not in canonical speckit.<ext>.<name> form: %s\n' "${cmd}" >&2
      return 1
    }
  done <<< "$(hook_commands)"
}

@test "every file in commands/ is declared in the manifest — nothing ships unregistered" {
  local declared f base
  declared="$(declared_command_files)"
  for f in "${ROOT}"/commands/*.md; do
    base="commands/$(basename "${f}")"
    grep -qxF "${base}" <<< "${declared}" || {
      printf 'command file is not declared in extension.yml: %s\n' "${base}" >&2
      return 1
    }
  done
}
