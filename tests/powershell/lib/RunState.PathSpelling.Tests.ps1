# #46 D1 — Get-JiraRunStatePath must spell its answer, not let the provider
# spell it.
#
# `state_file` is printed to stdout by reconcile's short-circuit
# (commands/Reconcile.psm1), so it is a path spelled back to the OPERATOR and
# it owes the Bash twin byte parity (NFR-1). The twin is one printf:
#
#     printf '%s/state/%s.json' "${JIRA_CONFIG_DIR}" "$(basename "$(dirname …))"
#                                                        — lib/run_state.sh:31
#
# `Join-Path` cannot produce those bytes. It goes through the FileSystem
# provider, which renormalises every separator to the host's own and collapses
# a duplicated one, so on Windows the two ports disagreed in nine conformance
# scenarios and the run still exited 0 — a silent divergence, invisible in the
# stderr channel because there was no error to report (issue #46, FINDINGS §1).
#
# That is quirk 8 of docs/10-windows-portability.md, and this repo has already
# paid for it once: the same defect on sc008-deleted-managed-region-restored
# (byte 138, bash 2f, pwsh 5c) is fixed and commented twelve lines below the
# function this file guards. The rule is in AGENTS.md — reaching the filesystem
# with the primitives is right, spelling a path back with them is not.
#
# WHY THE TRAILING SEPARATOR
#
# A bare separator assertion is Windows-only: on macOS and Linux the provider
# already answers with `/`, so the pre-fix code passes there and the guard
# would protect nothing on the maintainer's own machine. A config dir carrying
# a TRAILING separator separates the two mechanisms on every host — string
# concatenation keeps the duplicate, `Join-Path` collapses it — which is how
# #47's own cross-platform guards were built. Measured on Windows 2026-08-22:
#
#     Join-Path '.specify/jira/' 'state'  ->  .specify\jira\state
#     '.specify/jira/' + 'state'          ->  .specify/jira/state
#
# Get-JiraRunStatePath touches no filesystem — it is a pure string function —
# so these run against relative literals with nothing on disk.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '../../../scripts/powershell/lib/RunState.psm1'
    Import-Module $ModulePath -Force
    $script:SavedConfigDir = $env:JIRA_CONFIG_DIR
}

AfterAll {
    if ($null -eq $script:SavedConfigDir) {
        Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:JIRA_CONFIG_DIR = $script:SavedConfigDir
    }
}

Describe 'Get-JiraRunStatePath — the bytes, not the provider''s idea of them' {

    It 'keeps a trailing separator in the config dir, exactly as the Bash printf does' {
        # The host-independent half: the Bash twin interpolates and would emit
        # the doubled separator, so the PowerShell port owes the same bytes.
        $env:JIRA_CONFIG_DIR = '.specify/jira/'
        Get-JiraRunStatePath -SpecPath 'specs/021-example/spec.md' |
            Should -Be '.specify/jira//state/021-example.json'
    }

    It 'answers in forward slashes for the ordinary config dir' {
        # The real-world case, and the one the nine scenarios hit. Red on
        # Windows before the fix, green everywhere after.
        $env:JIRA_CONFIG_DIR = '.specify/jira'
        Get-JiraRunStatePath -SpecPath 'specs/021-example/spec.md' |
            Should -Be '.specify/jira/state/021-example.json'
    }

    It 'never puts a backslash in the answer, whatever the caller used' {
        # The mirror direction #45 used for the target guard: a caller spelling
        # its spec path with backslashes still gets a forward-slash answer,
        # because the separators come from this function and the config dir,
        # never from the input.
        $env:JIRA_CONFIG_DIR = '.specify/jira'
        $got = Get-JiraRunStatePath -SpecPath 'specs\021-example\spec.md'
        $got | Should -Not -Match '\\'
        $got | Should -Be '.specify/jira/state/021-example.json'
    }

    It 'honours an absolute POSIX config dir without renormalising it' {
        $env:JIRA_CONFIG_DIR = '/srv/repo/.specify/jira'
        Get-JiraRunStatePath -SpecPath 'specs/021-example/spec.md' |
            Should -Be '/srv/repo/.specify/jira/state/021-example.json'
    }
}
