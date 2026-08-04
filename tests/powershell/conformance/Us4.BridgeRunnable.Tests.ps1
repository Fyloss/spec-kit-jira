# T039 [US4] — The bridge runs straight after install, PowerShell port. Twin of
# tests/bash/conformance/test_us4_bridge_runnable.bats (FR-013, SC-008).
#
# The reported defect's second half was "spec-kit-jira CLI not installed". That
# message was wrong about the cause but right that nothing ran. This suite proves
# the opposite claim directly on the Windows port: install into a clean scratch
# repository, run the entry point by its repository-relative path with NOTHING
# done in between, and get usage output.
#
# The audit half has a DIFFERENT surface here than on the Bash port, which is why
# it is a twin rather than a copy: Windows has no shell rc files, the user-scope
# install locations are elsewhere, and `$env:PATH` is separated differently. The
# guarantee is the same — install side effects stay inside the repository
# (FR-008) — but the places to check are not.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    . (Join-Path $script:Root 'tests/conformance/InstallHarness.ps1')
    $script:BashEntry = '.specify/extensions/jira/scripts/bash/spec-kit-jira.sh'
    $script:PwshEntry = '.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1'
    $script:Available = Test-HarnessAvailable
    $script:Skip = Get-HarnessSkipReason
    # Set even on the skip path below — AfterEach reads it under Set-StrictMode,
    # which throws on an unset variable rather than treating it as falsy.
    $script:Repo = $null

    function Get-EnvironmentSnapshot {
        # A digest of every location a machine-wide install would have to touch on
        # this host. Windows: PATH, the PowerShell profile paths, and the
        # user-scope install locations. On POSIX hosts running the PowerShell
        # port, the profile paths resolve elsewhere and are covered the same way.
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add("PATH=$($env:PATH)")
        foreach ($p in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost,
                $PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost)) {
            if ($p -and (Test-Path -LiteralPath $p)) {
                $parts.Add("$p=$((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash)")
            }
            else { $parts.Add("$p=absent") }
        }
        foreach ($d in @(
                (Join-Path $HOME '.local/bin'),
                (Join-Path $HOME 'bin'),
                $env:LOCALAPPDATA)) {
            if ($d -and (Test-Path -LiteralPath $d)) {
                $names = (Get-ChildItem -LiteralPath $d -Name -ErrorAction SilentlyContinue | Sort-Object) -join "`n"
                $parts.Add("$d=$($names.GetHashCode())")
            }
            else { $parts.Add("$d=absent") }
        }
        return ($parts -join "`n")
    }
}

Describe 'The bridge is runnable straight after install' {
    BeforeEach {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        $script:Repo = New-HarnessRepo
    }
    AfterEach {
        if ($script:Repo) { Remove-HarnessRepo -Repo $script:Repo }
    }

    It 'installs the PowerShell entry point at the path the documents name (FR-013)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        Install-HarnessExtension -Repo $script:Repo
        Test-Path -LiteralPath (Join-Path $script:Repo $script:PwshEntry) | Should -BeTrue
    }

    It 'runs the PowerShell entry point by repository-relative path with nothing in between (FR-012)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        Install-HarnessExtension -Repo $script:Repo
        Push-Location $script:Repo
        try {
            $out = & pwsh -NoProfile -File $script:PwshEntry --help 2>&1 | Out-String
            $out | Should -Match 'usage: spec-kit-jira'
        }
        finally { Pop-Location }
    }

    It 'installs BOTH ports, so either host can run the bridge (FR-013, SC-008)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        Install-HarnessExtension -Repo $script:Repo
        Test-Path -LiteralPath (Join-Path $script:Repo $script:BashEntry) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Repo $script:PwshEntry) | Should -BeTrue
    }

    It 'changes NOTHING outside the repository (FR-008)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        $before = Get-EnvironmentSnapshot
        Install-HarnessExtension -Repo $script:Repo
        Get-EnvironmentSnapshot | Should -BeExactly $before
    }

    It 'creates no machine-wide spec-kit-jira command (FR-008)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        Install-HarnessExtension -Repo $script:Repo
        Get-Command spec-kit-jira -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'runs unaffected by the Bash entry point sibling losing its executable bit (FR-009, C7, R4)' {
        # POSIX-only condition (research R4): the PowerShell port never reads a
        # file mode at all, on either entry point, so a mode change to its
        # sibling cannot affect it. On a host with no `chmod` (Windows) there is
        # nothing to strip and the assertion holds trivially.
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        Install-HarnessExtension -Repo $script:Repo
        if (Get-Command chmod -ErrorAction SilentlyContinue) {
            & chmod a-x (Join-Path $script:Repo $script:BashEntry)
        }
        Push-Location $script:Repo
        try {
            $out = & pwsh -NoProfile -File $script:PwshEntry --help 2>&1 | Out-String
            $out | Should -Match 'usage: spec-kit-jira'
        }
        finally { Pop-Location }
    }
}
