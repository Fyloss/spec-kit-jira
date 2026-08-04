#!/usr/bin/env bats
# T014 [US1] — The manifest's hook declaration (FR-001 – FR-004, research R1/R8/R9).
#
# This is the check that would have caught the reported defect at its source:
# `extension.yml` had no `hooks:` block at all, so `specify extension add`
# registered nothing and the extension was inert from install.
#
# Four properties are asserted, and every one of them is silent when it breaks:
#
#   * PLACEMENT — `hooks:` must be a TOP-LEVEL key. `ExtensionManifest.validate()`
#     reads `self.data.get("hooks")` from the manifest root, so a block nested
#     under `provides:` still VALIDATES (the manifest has commands) and registers
#     nothing at all (research R1). Nothing warns.
#   * COVERAGE — exactly the seven declared events, no more (Principle XV) and no
#     fewer. The host purges our entries from events the manifest no longer
#     declares, so this block is the complete, self-cleaning set (research R9).
#   * DISPATCH — `optional: false` on every entry. `optional` decides whether the
#     step HAPPENS, not whether a failure propagates: for `optional: true` the
#     host merely prints the command and a prompt (research R4). The old
#     registrar wrote `optional: true` with a comment claiming it made the hook
#     non-blocking, which is why a correctly registered hook still never ran.
#   * CONDITION — no entry may declare one. A hook with a non-empty `condition`
#     is SKIPPED by the agent (research R8), which would reintroduce the defect
#     through a different door.
#
# The manifest is parsed with awk rather than with the extension's own YAML
# reader: extension.yml uses `>-` folded block scalars, which that reader's
# restricted subset does not model.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MANIFEST="${ROOT}/extension.yml"
  EXPECTED_EVENTS="after_analyze after_clarify after_implement after_plan after_specify after_tasks before_specify"
}

# manifest_block <key> — print the lines of a top-level block, excluding its
# header. A block runs until the next line that starts in column 0.
manifest_block() {
  awk -v key="$1" '
    $0 ~ "^" key ":[[:space:]]*$" { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock { print }
  ' "${MANIFEST}"
}

# hook_events — the event names declared under the top-level hooks: block.
hook_events() {
  manifest_block hooks | awk '/^  [A-Za-z_]+:[[:space:]]*$/ { sub(/:.*/, ""); gsub(/ /, ""); print }'
}

@test "hooks: is a TOP-LEVEL key of extension.yml (research R1)" {
  run grep -cE '^hooks:[[:space:]]*$' "${MANIFEST}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "hooks: is NOT nested under provides: — a nested block validates and registers nothing" {
  # The failure mode this guards is silent: the install succeeds, the manifest
  # validates, and no hook is ever registered.
  run bash -c "cd '${ROOT}' && awk '
    /^provides:/ { inprov = 1; next }
    inprov && /^[^[:space:]#]/ { inprov = 0 }
    inprov && /^[[:space:]]+hooks:/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' extension.yml"
  [ "$status" -ne 0 ]
}

@test "exactly the seven declared events, no more and no fewer (research R9)" {
  local actual
  actual="$(hook_events | LC_ALL=C sort | tr '\n' ' ')"
  [ "${actual% }" = "${EXPECTED_EVENTS}" ]
}

@test "before_specify fires the feature command; every after_* fires reconcile" {
  local cmd
  cmd="$(manifest_block hooks | awk '/^  before_specify:/ { f = 1; next } f && /^  [A-Za-z_]+:/ { f = 0 } f && /command:/ { print $2; exit }')"
  [ "${cmd}" = "speckit.jira.feature" ]

  local e
  for e in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
    cmd="$(manifest_block hooks | awk -v ev="  ${e}:" '$0 ~ "^" ev { f = 1; next } f && /^  [A-Za-z_]+:/ { f = 0 } f && /command:/ { print $2; exit }')"
    [ "${cmd}" = "speckit.jira.reconcile" ]
  done
}

@test "every hook entry declares optional: false (FR-004, research R4)" {
  # One `optional: false` per declared event, and not one `optional: true`.
  local n_events n_optional
  n_events="$(hook_events | wc -l | tr -d ' ')"
  n_optional="$(manifest_block hooks | grep -cE '^[[:space:]]+optional:[[:space:]]*false[[:space:]]*$' || true)"
  [ "${n_optional}" -eq "${n_events}" ]
  run bash -c "cd '${ROOT}' && awk '
    /^hooks:/ { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock && /optional:[[:space:]]*true/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' extension.yml"
  [ "$status" -ne 0 ]
}

@test "no hook entry declares a condition — it would suppress agent dispatch (research R8)" {
  run bash -c "manifest_block() { awk -v key=hooks '
    \$0 ~ \"^\" key \":[[:space:]]*\$\" { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock { print }
  ' '${MANIFEST}'; }; manifest_block | grep -qE '^[[:space:]]+condition:'"
  [ "$status" -ne 0 ]
}

@test "every hook entry carries a human-readable description (Principle XVI)" {
  local n_events n_desc
  n_events="$(hook_events | wc -l | tr -d ' ')"
  n_desc="$(manifest_block hooks | grep -cE '^[[:space:]]+description:[[:space:]]*[^[:space:]]' || true)"
  [ "${n_desc}" -eq "${n_events}" ]
}

@test "no hook entry declares priority or prompt — the host writes its defaults" {
  run bash -c "awk '
    /^hooks:/ { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock && /^[[:space:]]+(priority|prompt):/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' '${MANIFEST}'"
  [ "$status" -ne 0 ]
}

@test "requires.speckit_version stays >=0.13.0 — this feature does not raise the floor (FR-010, 014)" {
  # Raising the floor would fix the defect only for hosts nobody currently
  # runs and repair no existing tree (research R1) — forbidden outright by
  # FR-010. This is a regression pin, not a red-first test: it is green from
  # the day it is written, guarding the version bump in extension.yml.
  run bash -c "cd '${ROOT}' && awk '
    /^requires:/ { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock && /^[[:space:]]+speckit_version:/ { print; found = 1 }
    END { exit(found ? 0 : 1) }
  ' extension.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'">=0.13.0"'* ]]
}

@test "the manifest's event set and the reader's classified set are identical" {
  # An event added to one and forgotten in the other would ship half-wired: the
  # install would register a hook nothing reports on, or the report would name an
  # event the install never registers (data-model § Lifecycle event, Validation).
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/hooks/register_hooks.sh"
  local from_manifest from_reader
  from_manifest="$(hook_events | LC_ALL=C sort | tr '\n' ' ')"
  from_reader="$(printf '%s\n' "${HOOK_EVENTS[@]}" | LC_ALL=C sort | tr '\n' ' ')"
  [ "${from_manifest}" = "${from_reader}" ]
}
