#!/usr/bin/env bats
# Guard for tests/bash/helpers/mtime.bash.
#
# Two suites assert that an unchanged file was never rewritten, and both do it
# by reading the file's mtime before and after. They read it through
# `helper_file_mtime`, and that helper tries the GNU spelling first for a
# reason that is invisible on a BSD host:
#
#   GNU's `-f` is `--file-system` and takes NO argument, so the BSD form
#   `stat -f %m FILE` does not fail on Linux — it prints FILE's filesystem
#   block (free blocks, free inodes) and exits 1 because the operand `%m`
#   does not exist. A BSD-first helper therefore returns that block with the
#   real mtime appended by `||`, and the value changes every time anything
#   else on the host touches the same filesystem. Under `bats --jobs` the two
#   readings differ and the "file was not touched" assertions fail — which is
#   precisely what happened on the Ubuntu runner while macOS stayed green.
#
# macOS cannot reproduce that natively, so the GNU semantics are supplied by a
# stub on PATH. The stub makes the defect deterministic on EVERY host: with a
# BSD-first helper both assertions below fail, with a GNU-first helper both
# pass.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/mtime.bash"

  # A `stat` with GNU coreutils semantics: -c takes the format, -f is a
  # no-argument flag, a missing operand is reported on stderr and exits 1
  # while the readable operands still print. Its filesystem block reports a
  # DIFFERENT free-block count on every call, standing in for the other
  # parallel jobs writing to the runner's /tmp.
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "${STUB_DIR}"
  cat > "${STUB_DIR}/stat" << 'STUB'
#!/usr/bin/env bash
mode=file
fmt=""
operands=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f) mode=fs ;;
    -c) fmt="$2"; shift ;;
    *) operands+=("$1") ;;
  esac
  shift
done
rc=0
for operand in ${operands[@]+"${operands[@]}"}; do
  if [ ! -e "${operand}" ]; then
    echo "stat: cannot stat '${operand}': No such file or directory" >&2
    rc=1
    continue
  fi
  if [ "${mode}" = fs ]; then
    free="$(cat "${STUB_FREE_COUNTER}")"
    echo "$((free + 1))" > "${STUB_FREE_COUNTER}"
    printf '  File: "%s"\n' "${operand}"
    printf 'Blocks: Total: 20971520 Free: %s Available: %s\n' "${free}" "${free}"
  else
    case "${fmt}" in
      %Y) printf '1700000000\n' ;;
      *) printf '?\n' ;;
    esac
  fi
done
exit "${rc}"
STUB
  chmod +x "${STUB_DIR}/stat"
  STUB_FREE_COUNTER="${BATS_TEST_TMPDIR}/free"
  echo 1000 > "${STUB_FREE_COUNTER}"
  export STUB_FREE_COUNTER
  PATH="${STUB_DIR}:${PATH}"
}

@test "the mtime reading is a bare epoch second, never a filesystem block" {
  local f; f="${BATS_TEST_TMPDIR}/spec.md"
  printf 'content' > "${f}"
  local m; m="$(helper_file_mtime "${f}")"
  [[ "${m}" =~ ^[0-9]+$ ]]
}

@test "two readings of an untouched file are identical while the filesystem churns" {
  local f; f="${BATS_TEST_TMPDIR}/spec.md"
  printf 'content' > "${f}"
  local before after
  before="$(helper_file_mtime "${f}")"
  after="$(helper_file_mtime "${f}")"
  [ "${before}" = "${after}" ]
}

@test "the helper still answers on a host that only understands the BSD spelling" {
  # The stub's GNU branch removed: -c is rejected the way BSD stat rejects it
  # (usage on stderr, nothing on stdout, non-zero), so only the second form
  # can answer. Guards the fallback the GNU-first order depends on.
  cat > "${STUB_DIR}/stat" << 'STUB'
#!/usr/bin/env bash
if [ "$1" = "-c" ]; then
  echo "usage: stat [-FLnq] [-f format] [file ...]" >&2
  exit 1
fi
printf '1700000000\n'
STUB
  chmod +x "${STUB_DIR}/stat"
  local f; f="${BATS_TEST_TMPDIR}/spec.md"
  printf 'content' > "${f}"
  [ "$(helper_file_mtime "${f}")" = "1700000000" ]
}
