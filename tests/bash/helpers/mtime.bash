#!/usr/bin/env bash
# tests/bash/helpers/mtime.bash — one portable "when was this file last
# modified" reading, shared by every suite that asserts a file was NOT
# rewritten.
#
# Deliberately its own file: the two spellings below are not interchangeable,
# and getting their ORDER wrong fails only on Linux, only under load, which is
# the hardest kind of flake to attribute.

# helper_file_mtime <path> — the file's modification time in epoch seconds.
#
# GNU coreutils spells the request `stat -c %Y`; BSD/macOS spells it
# `stat -f %m`. They are NOT symmetric fallbacks, so GNU must come first:
#
#   * On BSD, `-c` is not an option at all. stat prints its usage on stderr,
#     writes NOTHING to stdout and exits non-zero, so `||` cleanly reaches the
#     BSD form and the caller sees one bare number.
#   * On GNU, `-f` IS an option (`--file-system`) and it takes NO argument.
#     The BSD form therefore does not fail there — it means something else:
#     `stat -f %m FILE` asks for the FILE SYSTEM status of two operands, `%m`
#     (which does not exist) and FILE. stat reports the missing one on stderr,
#     exits 1, and still prints FILE's filesystem block on stdout — free
#     blocks and free inodes included. With the BSD form first the caller
#     captures that block, `||` appends the real mtime after it, and the
#     resulting string changes whenever anything else on the host writes to
#     the same filesystem. Under `bats --jobs` that is continuous, which is
#     exactly how two "the file was not touched" assertions began failing on
#     Linux while passing on macOS.
#
# GNU first is the only order in which both hosts answer the question asked.
helper_file_mtime() {
  stat -c %Y "$1" 2> /dev/null || stat -f %m "$1"
}
