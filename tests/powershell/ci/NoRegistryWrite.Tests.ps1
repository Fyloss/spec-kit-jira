# 034 [FR-001, FR-010, SC-002] — No code path in the PowerShell port can open the
# hook registry AT ALL: not for writing, and now not for reading either. Twin of
# tests/bash/ci/test_no_registry_write.bats.
#
# This file used to enumerate write verbs — Set-Content, Out-File, the .NET
# writers, redirection — because a write can be spelled many ways and the
# extension still legitimately READ the file. Constitution 4.0.0 withdrew that
# permission and widened the prohibition: an extension that cannot repair a fact
# must not assert it, so this port must not open `.specify/extensions.yml` in any
# state, for any purpose.
#
# That makes the check categorically simpler AND stronger. A path the port cannot
# name cannot be written, so the absence test below subsumes every write-verb
# test it replaces. There is no exempted state and no safe spelling.
#
# SPEC_KIT_JIRA_GUARD_ROOT points the scan at a different tree, which is how this
# guard is demonstrated RED against the pre-change port (034 T007):
#
#   PRE=$(mktemp -d); git archive HEAD scripts | tar -x -C "$PRE"
#   $env:SPEC_KIT_JIRA_GUARD_ROOT="$PRE/scripts/powershell"; Invoke-Pester …
#
# A guard nobody has watched fail is not known to work: two of three guards
# shipped in a previous feature here were inert, and an inert guard is silent
# about it.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:ScanRoot = if ($env:SPEC_KIT_JIRA_GUARD_ROOT) {
        $env:SPEC_KIT_JIRA_GUARD_ROOT
    } else {
        Join-Path $script:Root 'scripts/powershell'
    }
    $script:Files = Get-ChildItem -LiteralPath $script:ScanRoot -Recurse -Include '*.psm1', '*.ps1' -File

    # Everything that could denote the registry: the literal path and the
    # environment override that used to redirect it. The local names the code
    # used for it are gone with the code that declared them.
    $script:RegistryToken = 'extensions\.yml|SPEC_KIT_JIRA_EXTENSIONS_YML'

    # NO file-level allowlist, deliberately. Select-CodeLine already drops
    # comment lines, so the prohibition's own explanatory comments are exempt
    # by construction and nothing further is needed. A file exemption on top of
    # that could only ever let real CODE through — it would weaken the guard
    # rather than express it.

    function Select-CodeLine {
        # Every non-comment line of every port module, with its origin.
        foreach ($f in $script:Files) {
            $n = 0
            foreach ($line in ((Get-Content -Raw -LiteralPath $f.FullName) -split "`r?`n")) {
                $n++
                if ($line -match '^\s*#') { continue }
                [pscustomobject]@{ File = $f.FullName; Line = $n; Text = $line }
            }
        }
    }
}

Describe 'The hook registry is never opened, for reading or writing (FR-001, SC-002)' {

    It 'scans a non-empty tree — the instrument check' {
        # If ScanRoot pointed at nothing, every test below would pass while
        # checking nothing at all. That failure mode is invisible from the
        # outside, so it is asserted first and explicitly.
        $script:ScanRoot | Should -Exist
        $script:Files.Count | Should -BeGreaterThan 20
    }

    It 'never names the registry outside an explanatory comment' {
        # The load-bearing test. A path that cannot be named cannot be opened —
        # for reading or for writing — so this subsumes every write-verb check
        # this file used to carry.
        $bad = Select-CodeLine |
            Where-Object { $_.Text -match $script:RegistryToken }
        $bad | ForEach-Object { Write-Host "registry named: $($_.File):$($_.Line): $($_.Text)" }
        $bad.Count | Should -Be 0
    }

    It 'has not seen the deleted reader come back under any name' {
        $module = $script:Files | Where-Object { $_.Name -eq 'RegisterHooks.psm1' }
        $module | Should -BeNullOrEmpty

        $bad = Select-CodeLine |
            Where-Object { $_.Text -match 'Get-JiraHookHealth|Get-JiraHookEventList|Get-JiraHookCommandFor|Get-JiraHookCommandList|Test-JiraHookEntryOwnership|Test-JiraHookEntryIsLeftover|Get-JiraHookEntryShapeError|New-JiraHookUnreadable|Get-JiraHookRepairHint|Get-CfgUnsupportedConstruct' }
        $bad | ForEach-Object { Write-Host "deleted reader symbol: $($_.File):$($_.Line): $($_.Text)" }
        $bad.Count | Should -Be 0
    }

    # DELIBERATELY NOT MIRRORED: the Bash twin's "no read verb is aimed at a
    # registry-shaped path" test.
    #
    # It was written here first and observed PASSING against the pre-change port
    # — the one result a red-proof run must never produce. The cause is not a
    # missing case, it is the port's spelling: PowerShell resolves the path into
    # `$extPath` on one line and hands it to `Get-JiraHookHealth` on another,
    # which reads it through `$Path`. No single line ever carries a read verb AND
    # the literal, so a line-level regex cannot fire here no matter how it is
    # written. The Bash port spells the same read inline, which is why its twin
    # fires and is kept.
    #
    # Rewriting it to match the variable names would only re-check what the
    # absence test above already proves, and shipping it as-is would add a test
    # that can never be red. This project has shipped inert guards before; the
    # correct response to finding one is to delete it, not to keep it for
    # symmetry.

    It 'leaves no reader or writer of the operator disable record (FR-005)' {
        # `hooks.disabled` was the only thing the extension wrote in response to
        # what it read in the registry. Retired with it.
        $bad = Select-CodeLine |
            Where-Object { $_.Text -match 'JiraHooksDisabled' }
        $bad | ForEach-Object { Write-Host "retired disable record accessed: $($_.File):$($_.Line): $($_.Text)" }
        $bad.Count | Should -Be 0
    }
}
