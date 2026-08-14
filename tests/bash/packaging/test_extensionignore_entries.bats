#!/usr/bin/env bats
# T006 [026] — `.extensionignore` excludes `.git/` and `packaging/`
# (FR-002a, data-model.md "Exclusion list" table).
#
# Before FR-002a, `.extensionignore` lists `.github/`, `.gitignore` and
# `.gitattributes` but not `.git/`, which is why `--dev` copies 6 165 files
# and 38 MB of this repository's history into a consumer tree (research R5).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  IGNORE_FILE="${ROOT}/.extensionignore"
}

@test ".extensionignore exists" {
  [ -f "${IGNORE_FILE}" ]
}

@test ".extensionignore excludes .git/ (FR-002a, research R5)" {
  cd "${ROOT}" || return 1
  run git -c core.excludesFile=.extensionignore check-ignore --no-index -q '.git/HEAD'
  [ "$status" -eq 0 ]
}

@test ".extensionignore excludes packaging/ (research R10)" {
  cd "${ROOT}" || return 1
  run git -c core.excludesFile=.extensionignore check-ignore --no-index -q 'packaging/build-artifact.sh'
  [ "$status" -eq 0 ]
}

@test "each new entry carries an explanatory comment (file's existing style)" {
  # The file's own convention: every pattern is preceded by prose explaining
  # why. A bare pattern with no comment above it is a future mistake.
  run grep -B1 -x '\.git/' "${IGNORE_FILE}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'#'* ]]

  run grep -B1 -x 'packaging/' "${IGNORE_FILE}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'#'* ]]
}
