#!/usr/bin/env bash
# tests/bash/helpers/seed_fixture.bash — T002/T004 (027): a seeded-repo
# fixture builder for the "seed a spec from existing Jira issues" feature.
#
# helper_seed_config writes a committed config.yml carrying a `hierarchy`
# block (specification/story role -> issue-type name) and a `teams:`
# catalogue entry for project routing (the same routing mechanism
# commands/feature.sh already resolves `eff_project` from), plus a
# gitignored personal.yml selecting that team. helper_seed_config_safe
# writes the FR-014 non-default-hierarchy variant: SAFe-shaped role names
# (Capability/Feature) rather than the default Epic/Story.

# helper_seed_config <config-dir> [project-key] [team-id] — default hierarchy
# (Epic/Story), project routing via a single team.
helper_seed_config() {
  local dir="$1" pkey="${2:-PROJ}" team="${3:-proj}"
  mkdir -p "${dir}"
  {
    printf 'projects:\n'
    printf '  - key: %s\n' "${pkey}"
    printf '    hierarchy:\n'
    printf '      specification: Epic\n'
    printf '      story: Story\n'
    printf 'routing_default: %s\n' "${pkey}"
    printf 'teams:\n'
    printf '  - id: %s\n' "${team}"
    printf '    project: %s\n' "${pkey}"
    printf '    folder_prefix: "%s-"\n' "${team}"
    printf '    branch_pattern: "%s-<ID>/<FEATURE_NAME>"\n' "${team}"
  } > "${dir}/config.yml"
  printf 'team: %s\n' "${team}" > "${dir}/personal.yml"
}

# helper_seed_config_safe <config-dir> [project-key] [team-id] — FR-014: a
# non-default hierarchy — SAFe-shaped roles, renamed types (Capability for
# the specification role, Feature for the story role).
helper_seed_config_safe() {
  local dir="$1" pkey="${2:-SAFE}" team="${3:-safe}"
  mkdir -p "${dir}"
  {
    printf 'projects:\n'
    printf '  - key: %s\n' "${pkey}"
    printf '    hierarchy:\n'
    printf '      specification: Capability\n'
    printf '      story: Feature\n'
    printf 'routing_default: %s\n' "${pkey}"
    printf 'teams:\n'
    printf '  - id: %s\n' "${team}"
    printf '    project: %s\n' "${pkey}"
    printf '    folder_prefix: "%s-"\n' "${team}"
    printf '    branch_pattern: "%s-<ID>/<FEATURE_NAME>"\n' "${team}"
  } > "${dir}/config.yml"
  printf 'team: %s\n' "${team}" > "${dir}/personal.yml"
}
