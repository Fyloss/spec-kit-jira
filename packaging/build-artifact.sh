#!/usr/bin/env bash
# packaging/build-artifact.sh — T013/T014/T015 (026): derive the installable
# surface (packaging/lib/surface.sh), write a deterministic archive of it
# under a single `spec-kit-jira/` root, and print a machine-readable manifest
# of what was built.
#
# usage: build-artifact.sh <output-zip-path>
#
# Prints, on success, to stdout:
#   entries: <count>
#   uncompressed_bytes: <total>
#   largest_member_bytes: <size>
#   largest_member_path: <repo-relative path>
#
# Fail-closed (contracts/artifact-shape.md C5.1/C5.2): any failing step
# aborts before <output-zip-path> exists; a partially written archive is
# never left on disk.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SELF_DIR}/.." && pwd)"
# shellcheck source=packaging/lib/surface.sh
source "${SELF_DIR}/lib/surface.sh"

OUT="${1:-}"
if [[ -z "${OUT}" ]]; then
  printf 'usage: %s <output-zip-path>\n' "$(basename "$0")" >&2
  exit 1
fi

mapfile -t SURFACE < <(packaging_derive_surface)
if [[ ${#SURFACE[@]} -eq 0 ]]; then
  printf 'build-artifact: derived surface is empty — refusing to build (C5.2)\n' >&2
  exit 1
fi

PYSCRIPT="$(mktemp)"
trap 'rm -f "${OUT}.partial" "${PYSCRIPT}"' EXIT

# One `git ls-files -s` call for the whole surface, never one per file
# (docs/11-process-budget.md) — the git-tracked mode is what gets normalised
# into the archive, never the caller's filesystem mode, so a build is
# reproducible regardless of the local umask (C4.2).
MODES_TSV="$(git -C "${ROOT}" ls-files -s -- "${SURFACE[@]}" \
  | awk -F'\t' '{n = split($1, a, " "); print a[1] "\t" $2}')"

cat > "${PYSCRIPT}" <<'PY'
import os
import sys
import zipfile
import zlib
import pathlib

repo_root, out_path = sys.argv[1], sys.argv[2]
WRAP = "spec-kit-jira"
FIXED_DATE = (2020, 1, 1, 0, 0, 0)  # normalised timestamp (C4.2)

entries = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    mode_str, relpath = line.split("\t", 1)
    entries.append((relpath, int(mode_str, 8)))
entries.sort(key=lambda e: e[0])

dirs = set()
for relpath, _ in entries:
    parts = relpath.split("/")
    for i in range(1, len(parts)):
        dirs.add("/".join(parts[:i]))

DIR_MODE = 0o40755
members = [(f"{WRAP}/", True, DIR_MODE, None)]
for d in sorted(dirs):
    members.append((f"{WRAP}/{d}/", True, DIR_MODE, None))
for relpath, mode in entries:
    members.append((f"{WRAP}/{relpath}", False, mode, relpath))
members.sort(key=lambda m: m[0])  # members emitted in sorted order (C4.2)

partial = out_path + ".partial"
largest_size = -1
largest_path = ""
uncompressed_total = 0

with zipfile.ZipFile(partial, "w") as zf:
    for archive_path, is_dir, mode, relpath in members:
        zi = zipfile.ZipInfo(archive_path, date_time=FIXED_DATE)
        zi.create_system = 3  # unix, so external_attr's high 16 bits are the mode
        if is_dir:
            zi.external_attr = (mode << 16) | 0x10
            zf.writestr(zi, b"", compress_type=zipfile.ZIP_STORED)
            continue
        data = pathlib.Path(repo_root, relpath).read_bytes()
        zi.external_attr = mode << 16
        # Deflate with stored fallback (T014): a tiny or already-dense file
        # can grow under deflate's overhead, so store it as-is instead.
        deflated = zlib.compress(data, 9)
        compress_type = zipfile.ZIP_DEFLATED if len(deflated) < len(data) else zipfile.ZIP_STORED
        zf.writestr(zi, data, compress_type=compress_type, compresslevel=9)
        uncompressed_total += len(data)
        if len(data) > largest_size:
            largest_size = len(data)
            largest_path = relpath

os.replace(partial, out_path)

print(f"entries: {len(members)}")
print(f"uncompressed_bytes: {uncompressed_total}")
print(f"largest_member_bytes: {largest_size}")
print(f"largest_member_path: {largest_path}")
PY

python3 "${PYSCRIPT}" "${ROOT}" "${OUT}" <<< "${MODES_TSV}"
