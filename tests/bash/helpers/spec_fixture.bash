#!/usr/bin/env bash
# tests/bash/helpers/spec_fixture.bash — a parameterised spec.md/tasks.md
# generator: story count, binding state and tasks-per-story are all
# arguments, replacing the ad hoc `_write_large_spec` that
# test_reconcile_large_spec.bats grew for a single, unbound scenario.
#
# Each story carries the Given/When/Then triple the engine renders into both
# a bullet list and an Acceptance Criteria panel, which is what makes a
# generated story's payload realistic rather than a minimal stub.

# helper_make_spec <dir> <story-count> <bound|unbound> [tasks-per-story] —
# writes <dir>/spec.md, and — when <tasks-per-story> is non-zero —
# <dir>/tasks.md. Under `bound`, each story carries its own
# `<!-- speckit-jira story=<id> ticket=<key> -->` marker line so the run
# recognises it instead of creating it; under `unbound`, no marker line is
# written at all.
helper_make_spec() {
  local dir="$1" story_count="$2" mode="$3" tasks_per_story="${4:-0}"
  mkdir -p "${dir}"
  local spec="${dir}/spec.md" i
  {
    printf '%s\n' '# Feature Specification: Widget Management' ''
    printf '%s\n' 'We need to let users manage widgets end to end.' ''
    for ((i = 1; i <= story_count; i++)); do
      printf '### User Story %d - Story number %d (Priority: P1)\n' "${i}" "${i}"
      if [[ "${mode}" == "bound" ]]; then
        printf '<!-- speckit-jira story=%016x ticket=COMP-%d -->\n' "${i}" "${i}"
      fi
      printf '\n'
      printf '%s\n' "As a user, I want outcome ${i}." ''
      printf '%s\n' '- **Given** a precondition' '- **When** I act' \
        "- **Then** outcome ${i} happens" ''
    done
  } > "${spec}"

  if ((tasks_per_story > 0)); then
    local tasks="${dir}/tasks.md" tnum=1 j
    {
      printf '%s\n\n' '# Tasks: Widget Management'
      for ((i = 1; i <= story_count; i++)); do
        for ((j = 1; j <= tasks_per_story; j++)); do
          printf -- '- [ ] T%03d [US%d] Task %d for story %d: given a precondition, when acted, then outcome %d.%d happens\n' \
            "${tnum}" "${i}" "${j}" "${i}" "${i}" "${j}"
          tnum=$((tnum + 1))
        done
      done
    } > "${tasks}"
  fi
}
