#!/usr/bin/env bats
# T055 [US6] — The hook registry is byte-identical after every command in every
# documented state (FR-022, FR-023, SC-007, SC-012).
#
# This is the headline guarantee of the feature, and it is stated without
# exemption on purpose. The consuming project asked a direct question — does the
# configuration ceremony overwrite our `.specify/extensions.yml`? — and the honest
# answer required removing the writer rather than narrowing it.
#
# Why "narrow it" was not enough (research R3): this extension's YAML reader
# models a deliberately restricted subset and drops every comment, so ANY write
# it performs silently damages a file the operator is invited to edit and other
# extensions co-own. The registry is also written by the host and by other
# extensions, so a second writer on it is a coordination problem with no good
# solution. There is no safe write, so there is no exempted state — and this
# suite is what makes that testable: one seeded registry carrying everything a
# real one carries, run through every documented state.
#
# The seed is deliberately hostile to a round-trip: operator comments (which the
# reader drops), an unusual key order (which the writer would sort), and a
# foreign extension's entries (which a merge could reorder). If any command ever
# re-serialises this file, one of these WILL change.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  EXT="${SPEC_KIT_JIRA_EXTENSIONS_YML}"

  # A minimal committed config so the ceremony gets past its config read.
  {
    printf 'projects:\n'
    printf '  - key: TEAM\n'
    printf 'routing_default: TEAM\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"

  SPEC="${WORK}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Untouched' '' 'A spec that mirrors to Jira.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${SPEC}"

  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
  unset SPEC_KIT_JIRA_BASE_URL
  unset SPEC_KIT_JIRA_HOOK_EVENT
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  rm -rf "${WORK}"
}

# seed_registry [mutator-jq] — write the hostile seed. The optional jq program
# mutates the structure first, which is how each documented state is produced
# without giving up the comments and ordering the assertion depends on.
seed_registry() {
  cat > "${EXT}" << 'YAML'
# Our team's hook registry. Please keep the comments — they are the only record
# of why after_implement is off.
installed:
- jira
- git
settings:
  auto_execute_hooks: true
hooks:
  after_plan:
  - extension: git          # the other extension's entry, and it stays put
    command: speckit.git.commit
    enabled: true
  - extension: jira
    command: speckit.jira.reconcile
    enabled: true
    optional: false
    priority: 10
    prompt: Execute speckit.jira.reconcile?
    description: Mirror the implementation plan into Jira Cloud.
    condition: null
  before_specify:
  - extension: jira
    command: speckit.jira.feature
    enabled: true
    optional: false
    priority: 10
    prompt: Execute speckit.jira.feature?
    description: Resolve the Jira ticket and name the feature before creation.
    condition: null
YAML
}

# run_every_command — the ceremony and the reconcile entry point, in both real
# and dry-run form. Failures are expected in several states and are irrelevant:
# what is under test is the file, not the exit code.
run_every_command() {
  cmd_config config --json > /dev/null 2>&1 || true
  cmd_config config --dry-run --json > /dev/null 2>&1 || true
  cmd_reconcile reconcile --json "${SPEC}" > /dev/null 2>&1 || true
  cmd_reconcile reconcile --dry-run --json "${SPEC}" > /dev/null 2>&1 || true
}

# assert_untouched <label> — checksum AND full text, before and after.
assert_untouched() {
  local label="$1" before_sum after_sum
  before_sum="$(shasum -a 256 < "${EXT}" | awk '{print $1}')"
  cp "${EXT}" "${WORK}/before.yml"
  run_every_command
  after_sum="$(shasum -a 256 < "${EXT}" | awk '{print $1}')"
  [ "${before_sum}" = "${after_sum}" ] || {
    printf 'state "%s": the registry checksum changed\n' "${label}" >&2
    diff -u "${WORK}/before.yml" "${EXT}" >&2 || true
    return 1
  }
  diff -q "${WORK}/before.yml" "${EXT}" > /dev/null || {
    printf 'state "%s": the registry text changed\n' "${label}" >&2
    return 1
  }
}

@test "healthy: every command leaves the registry byte-identical (SC-007)" {
  seed_registry
  # Complete the registry so the state is genuinely healthy.
  local e cmd
  for e in after_specify after_clarify after_tasks after_implement after_analyze; do
    cmd=speckit.jira.reconcile
    {
      printf '  %s:\n' "${e}"
      printf '  - extension: jira\n    command: %s\n    enabled: true\n' "${cmd}"
      printf '    optional: false\n    priority: 10\n'
      printf '    prompt: Execute %s?\n' "${cmd}"
      printf '    description: Mirror.\n    condition: null\n'
    } >> "${EXT}"
  done
  assert_untouched "healthy"
}

@test "one entry missing: reported, never registered (FR-025, SC-007)" {
  seed_registry
  assert_untouched "incomplete"
}

@test "one entry disabled: recorded in OUR file, the registry untouched (FR-007)" {
  seed_registry
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  # Flip the plan entry to disabled by hand, as an operator would.
  sed -i.bak 's/^    enabled: true$/    enabled: false/' "${EXT}" && rm -f "${EXT}.bak"
  assert_untouched "disabled"
  # The decision was captured — in the local binding, not by editing the registry.
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}" | jq -r 'length')" -ge 1 ]
}

@test "a leftover pre-manifest entry: reported, never removed (FR-028, SC-007)" {
  seed_registry
  # An entry with our command and NO owning extension — the shape the install
  # cannot purge and we may not either.
  {
    printf '  after_tasks:\n'
    printf '  - command: speckit.jira.reconcile\n    enabled: true\n    optional: true\n'
  } >> "${EXT}"
  assert_untouched "duplicated"
}

@test "an unreadable registry: reported, never rewritten (FR-024, SC-007)" {
  printf '%s\n' \
    '# a file we cannot read, and must not touch' \
    'hooks:' \
    '  after_plan: &anchor' \
    '    - extension: jira' > "${EXT}"
  assert_untouched "unreadable"
}

@test "a repository that is not configured: the registry is still untouched (SC-007)" {
  seed_registry
  rm -f "${JIRA_CONFIG_DIR}/config.yml"
  assert_untouched "not configured"
}

@test "the operator's comments survive every run (SC-012)" {
  seed_registry
  run_every_command
  grep -q 'Please keep the comments' "${EXT}"
  grep -q 'the only record' "${EXT}"
  grep -q "the other extension's entry, and it stays put" "${EXT}"
}

@test "the unusual key order survives every run (FR-023, SC-012)" {
  # `installed` before `settings` before `hooks`, and `after_plan` before
  # `before_specify` — neither is the order our serialiser would produce, so a
  # re-serialisation would be visible here even if the content were preserved.
  seed_registry
  run_every_command
  local keys
  keys="$(grep -nE '^(installed|settings|hooks):' "${EXT}" | cut -d: -f2 | tr '\n' ' ')"
  [ "${keys}" = "installed settings hooks " ]
  local events
  events="$(grep -oE '^  (after_plan|before_specify):' "${EXT}" | tr -d ' :' | tr '\n' ' ')"
  [ "${events}" = "after_plan before_specify " ]
}

@test "a foreign extension's entry survives every run (FR-006, SC-012)" {
  seed_registry
  run_every_command
  grep -q 'command: speckit.git.commit' "${EXT}"
  grep -q 'extension: git' "${EXT}"
}

@test "no command CREATES the registry when it is absent (FR-022)" {
  rm -f "${EXT}"
  run_every_command
  [ ! -f "${EXT}" ]
}
