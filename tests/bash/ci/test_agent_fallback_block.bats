#!/usr/bin/env bats
# T085 [US5] — The bridge-unavailable fallback block, verbatim (FR-030).
#
# This check exists because of a finding that changes what "check the messages"
# can mean. The reported error message — the one that named a machine-wide CLI
# that was never how this extension is delivered, and told the developer to run
# `/speckit-jira-conifg` — exists NOWHERE in this repository. Not in a script,
# not in a command document. The assistant composed it, after the procedure told
# it to run a bare `spec-kit-jira` that a consuming repository does not have.
#
# T044's scan of committed literals cannot see prose that is never committed. So
# the enforceable control is different in kind: for the one state the bridge
# cannot report on — because it never starts — pin the exact words in the
# document the assistant reads, instruct it to emit them rather than improvise,
# and check mechanically that the document still contains them.
#
# Three properties of the block are load-bearing, and each maps to a defect in
# the reported message:
#   1. it names the TRUE cause — a missing file at a known path — instead of a
#      machine-wide "CLI not installed";
#   2. it states plainly that the host command SUCCEEDED, so a normal degraded
#      state does not read as a failure;
#   3. every literal in it is runnable as written: two real paths and one host
#      command. Nothing invites the assistant to recall a name from memory, which
#      is how `/speckit-jira-conifg` was produced.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  DOCS_DIR="${ROOT}/commands"
  mapfile -t DOCS < <(find "${DOCS_DIR}" -name '*.md' -type f | LC_ALL=C sort)

  # The block, fixed in contracts/bridge-invocation.md C4 (supersedes 003's
  # reconcile-command.md wording). Byte for byte.
  read -r -d '' BLOCK << 'EOF' || true
Jira bridge not available: the entry point
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh (or, on Windows,
.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1) was not found.
This spec-kit command completed normally and nothing was mirrored to Jira. To
restore the bridge, reinstall the extension with `specify extension add --dev
<path-to-spec-kit-jira> --force`.
EOF
}

@test "each of the three command documents contains the block VERBATIM (FR-030)" {
  [ "${#DOCS[@]}" -eq 3 ]
  local doc
  for doc in "${DOCS[@]}"; do
    grep -qF -- "${BLOCK}" "${doc}" || {
      # grep -F with a multi-line pattern matches the whole run of lines.
      printf '%s does not contain the fallback block verbatim\n' "${doc}" >&2
      printf 'expected:\n%s\n' "${BLOCK}" >&2
      return 1
    }
  done
}

@test "each document instructs the assistant to emit it EXACTLY, not describe it (FR-030)" {
  # Without this instruction the block is just text the assistant may summarise,
  # and summarising is precisely how the reported message came to exist.
  local doc
  for doc in "${DOCS[@]}"; do
    grep -qF 'exactly as written' "${doc}" || {
      printf '%s carries the block but does not require it verbatim\n' "${doc}" >&2
      return 1
    }
    grep -qiE 'do not (paraphrase|compose)' "${doc}" || {
      printf '%s does not forbid composing an explanation for this state\n' "${doc}" >&2
      return 1
    }
  done
}

@test "the block names the true cause — a missing file, not a missing CLI (FR-030, C4)" {
  [[ "${BLOCK}" == *'was not found.'* ]]
  # The wording the reported message used, and which was never true of this
  # extension: it is not delivered as a machine-wide CLI at all.
  [[ "${BLOCK}" != *'CLI not installed'* ]]
}

@test "no command document mentions permissions for this cause anywhere (FR-005, C4)" {
  # 014 narrows the sixth degraded cause to absent-only; a lost executable bit
  # is never a cause again, in the block, the lead-in prose, or a table row.
  local doc
  for doc in "${DOCS[@]}"; do
    run grep -niE 'is not executable|executable bit' "${doc}"
    [ "$status" -ne 0 ] || {
      printf '%s still mentions a permission cause:\n%s\n' "${doc}" "$output" >&2
      return 1
    }
  done
}

@test "the block states that the host command completed normally (FR-030, FR-015)" {
  [[ "${BLOCK}" == *'This spec-kit command completed normally'* ]]
  [[ "${BLOCK}" == *'nothing was'* ]]
}

@test "every literal inside the block is runnable as written (FR-030, FR-018)" {
  # The two per-port entry points exist at the paths the block names...
  [[ "${BLOCK}" == *'.specify/extensions/jira/scripts/bash/spec-kit-jira.sh'* ]]
  [[ "${BLOCK}" == *'.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1'* ]]
  [ -f "${ROOT}/scripts/bash/spec-kit-jira.sh" ]
  [ -f "${ROOT}/scripts/powershell/spec-kit-jira.ps1" ]

  # ...and the reinstall command is the official one, in the form the operator
  # actually runs. The line break between `--dev` and the placeholder is part
  # of the verbatim wrap (C4), so compare against the newline-flattened block.
  local flat="${BLOCK//$'\n'/ }"
  [[ "${flat}" == *'specify extension add --dev <path-to-spec-kit-jira> --force'* ]]

  # Nothing in the block names an assistant command, so there is nothing for the
  # assistant to misremember — the failure mode that produced `/speckit-jira-conifg`.
  run grep -qE 'speckit[.-]jira' <<< "${BLOCK}"
  [ "$status" -ne 0 ]
}
