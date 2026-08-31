#!/usr/bin/env bash
# engine/artifact_set.sh — the feature directory as the engine sees it
# (036 data-model.md §1; research R4/R5/R7; FR-001, FR-005, FR-007, FR-023).
#
# Every file the repository does not ignore, at any depth, with its content
# hash, its size, and the name it will carry as an attachment. NEUTRAL layer:
# this module knows nothing about Jira — it would be identical if the sink
# were something else — and it never sources anything under sink/.
#
# THE PROCESS BUDGET IS THE DESIGN, not an optimisation of it. A feature
# directory can hold dozens of files, this runs on the reconcile path, and
# `docs/11-process-budget.md` forbids a spawn per item. So:
#
#   * enumeration is ONE `git ls-files --cached --others --exclude-standard`,
#     which also applies the ignore rules for us (FR-007) — the alternative,
#     `git check-ignore` per file, is the per-item spawn itself;
#   * hashing is ONE `git hash-object --no-filters --stdin-paths`, paths fed on
#     STDIN;
#   * sizing is ONE `xargs -0 wc -c`;
#   * assembly is ONE `jq`.
#
# And in the same breath — the half of that rule this repository has dropped
# three times — NONE of those payloads travels on a command line. Paths go to
# `git hash-object` on stdin and to `wc` through `xargs`, which does its own
# splitting against the host's real cap. The binding cap is never this
# machine's: Windows counts the whole command line against ~32767 bytes, Linux
# caps one argument at 128 KiB, macOS caps nothing, and it is the tightest that
# has to hold.
#
# `xargs` is the one place the spawn count is not literally constant: it splits
# its input when the accumulated command line would exceed the host's cap. That
# is bounded by TOTAL PATH BYTES, not by item count, and it is the correct
# behaviour rather than a compromise — xargs exists to keep exactly this
# promise. For any plausible feature directory it is a single `wc`.

[[ -n ${_JIRA_ENGINE_ARTIFACT_SET:-} ]] && return 0
_JIRA_ENGINE_ARTIFACT_SET=1

_ARTIFACT_SET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ARTIFACT_SET_DIR}/../lib/output.sh" # json_canonical

# artifact_set_flatten <relative-path> — the attachment name for that path
# (research R7, FR-005).
#
# A top-level artifact keeps its exact filename, because that is what a reader
# expects to see in the attachment panel. A nested one joins its segments with
# `__`, which reads as a path separator to anyone who has seen one and cannot
# be produced by a single `/` replacement colliding with an ordinary name.
#
# Pure string work: no subshell, no external process, whatever the depth.
artifact_set_flatten() {
  local path="$1"
  printf '%s' "${path//\//__}"
}

# _artifact_set_paths <feature-dir> <out-file> — write the non-ignored files
# under <feature-dir>, NUL-separated and relative to it, to <out-file>.
#
# `-z` is not optional: `git ls-files` quotes any path containing a space or a
# non-ASCII byte unless it is asked for NUL-separated output, and a quoted path
# is not a path. Splitting on NUL is also the only split that cannot be broken
# by a newline in a filename.
#
# It writes to a FILE rather than stdout-for-capture, and that is not a style
# choice: `$( … )` silently discards NUL bytes ("ignored null byte in input"),
# so capturing `-z` output into a variable destroys the very separator that
# makes it safe. The tests caught this; the warning is easy to miss in a run
# that otherwise looks like it worked.
_artifact_set_paths() {
  local dir="$1" out="$2"
  # Scoped to the directory by running IN it, so the paths come back relative
  # already and nothing has to strip a prefix that might itself contain the
  # separator we are about to flatten.
  (cd "${dir}" 2> /dev/null && git ls-files --cached --others --exclude-standard -z -- . 2> /dev/null) > "${out}" || true
}

# artifact_set_build <feature-dir> — print the artifact set as a canonical
# JSON array, sorted byte-wise on `path` (data-model §1).
#
# Prints `[]` for a directory holding nothing publishable. That is a legitimate
# state — a specification whose folder holds only ignored files — and not an
# error: returning non-zero here would turn an empty feature directory into a
# failed run.
artifact_set_build() {
  local dir="$1"
  [[ -d "${dir}" ]] || {
    printf '[]'
    return 0
  }

  # Every intermediate travels through a file, so nothing here is bounded by an
  # environment or argument cap — and so the NUL separator survives.
  local tmp
  tmp="$(mktemp -d)" || return 1

  _artifact_set_paths "${dir}" "${tmp}/rel_z"
  if [[ ! -s "${tmp}/rel_z" ]]; then
    rm -rf "${tmp}"
    printf '[]'
    return 0
  fi

  # Read the NUL-separated list into an array once. `mapfile -d ''` is the
  # only split that survives a newline inside a filename.
  local -a rel=()
  mapfile -t -d '' rel < "${tmp}/rel_z"

  # Two parallel lists, same order. `rel` is what the set reports and what
  # crosses the engine/sink boundary; `abs` is what the two batched readers are
  # given.
  #
  # The split is forced by MEASURED behaviour, not by preference:
  # `git hash-object --stdin-paths` resolves a relative path against the
  # REPOSITORY ROOT, not the process's current directory — `cd`-ing into the
  # feature directory first does not change that, and the call fails with
  # "could not open '<path>' for reading". Absolute paths resolve correctly
  # from anywhere. Feeding them on stdin costs nothing, since no command line
  # is involved either way.
  local p
  : > "${tmp}/rel"
  : > "${tmp}/abs"
  for p in "${rel[@]}"; do
    printf '%s\n' "${p}" >> "${tmp}/rel"
    printf '%s/%s\n' "${dir}" "${p}" >> "${tmp}/abs"
  done

  # Hashes: one process, paths on stdin, output in input order.
  local hashes_rc=0
  git hash-object --no-filters --stdin-paths < "${tmp}/abs" > "${tmp}/hashes" 2> /dev/null || hashes_rc=$?
  if ((hashes_rc != 0)); then
    rm -rf "${tmp}"
    return 1
  fi

  # Sizes: one `xargs`, which does its own splitting against the host's real
  # cap. `wc -c` prints "<size> <path>" and appends a "total" line when it was
  # given more than one file; the jq programme below reads sizes positionally
  # from the same order instead of parsing those lines back, so neither the
  # total line nor a path containing spaces can confuse it — but the total line
  # must still be dropped, or it shifts every subsequent index.
  tr '\n' '\0' < "${tmp}/abs" | xargs -0 wc -c 2> /dev/null \
    | awk '$2 != "total" { print $1 }' > "${tmp}/sizes" || true

  # `wc` emits a trailing total for a multi-file invocation, and one per split
  # when xargs split. Rather than guess how many, take the first N values that
  # line up with N paths — awk below pairs them by index and drops the rest.
  local count="${#rel[@]}"

  # Every path handed to jq goes through json_path_arg. The jq on PATH under
  # git-bash is a NATIVE Windows binary and resolves none of MSYS's virtual
  # paths, so a bare `/tmp/tmp.X` from mktemp is unopenable there — measured on
  # the Windows probe, where it killed 12 of 231 conformance scenarios with an
  # empty stdout. `< file` is exempt because bash opens it; `--rawfile` is not,
  # because jq does.
  local out
  out="$(jq -Rn --argjson n "${count}" \
    --rawfile rel "$(json_path_arg "${tmp}/rel")" \
    --rawfile hashes "$(json_path_arg "${tmp}/hashes")" \
    --rawfile sizes "$(json_path_arg "${tmp}/sizes")" '
      def lines: split("\n") | map(select(length > 0));
      ($rel    | lines) as $p |
      ($hashes | lines) as $h |
      ($sizes  | lines) as $s |
      [ range(0; $n) as $i
        | { path: $p[$i],
            hash: ($h[$i] // ""),
            size: (($s[$i] // "0") | tonumber),
            attachment_name: ($p[$i] | gsub("/"; "__")) } ]
      | sort_by(.path)
    ')" || {
    rm -rf "${tmp}"
    return 1
  }

  rm -rf "${tmp}"
  printf '%s' "${out}" | json_canonical
}

# artifact_set_collisions <set-json> — print one line per group of artifacts
# sharing an attachment name, as `<name>: <path> <path> …`; print nothing when
# every name is unique (FR-005, data-model §1 "Validation").
#
# Reachable only through a literal `__` in a real filename, which is why it
# warns and withholds rather than mangling further: guessing a second
# disambiguation would produce a name no reader could map back to a path.
artifact_set_collisions() {
  local set_json="$1"
  jq -r '
    group_by(.attachment_name)
    | map(select(length > 1))
    | .[]
    | "\(.[0].attachment_name): \(map(.path) | join(" "))"
  ' <<< "${set_json}"
}
