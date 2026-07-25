# T024 — Entry-point dispatcher (PowerShell port).
# Mirror of tests/bash/commands/test_dispatch.bats: prerequisites gate every
# path, then the CLI is parsed and the command routed to its Invoke-Jira<Name>
# entry. Command modules are stubbed via SPEC_KIT_JIRA_COMMANDS_DIR.

BeforeAll {
    $script:Entry = Join-Path $PSScriptRoot '../../../scripts/powershell/spec-kit-jira.ps1'
    $script:StubDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $script:StubDir | Out-Null
    # Command contract: write user output via [Console] streams (straight to the
    # process fds, bypassing the pipeline) and return ONLY the numeric exit code —
    # this mirrors the Bash port (echo -> fd1, return -> status).
    Set-Content -LiteralPath (Join-Path $script:StubDir 'Config.psm1') -Value @'
function Invoke-JiraConfig { param([string[]] $Arguments) [Console]::Out.WriteLine("config-ran args=$($Arguments -join ' ')"); return 0 }
Export-ModuleMember -Function Invoke-JiraConfig
'@
    Set-Content -LiteralPath (Join-Path $script:StubDir 'Reconcile.psm1') -Value @'
function Invoke-JiraReconcile { param([string[]] $Arguments) [Console]::Out.WriteLine("reconcile-ran"); return 0 }
Export-ModuleMember -Function Invoke-JiraReconcile
'@
    function Invoke-Entry {
        param([string[]] $EntryArgs, [hashtable] $Env = @{})
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($script:Entry)
        foreach ($a in $EntryArgs) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['SPEC_KIT_JIRA_COMMANDS_DIR'] = $script:StubDir
        foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
    }
}

AfterAll {
    if (Test-Path $script:StubDir) { Remove-Item -Recurse -Force $script:StubDir }
}

Describe 'Dispatcher' {
    It 'prerequisite failure exits 5 before any command runs (NFR-4)' {
        $r = Invoke-Entry -EntryArgs @('config') -Env @{ _PREREQ_FORCE_MISSING = 'git' }
        $r.ExitCode | Should -Be 5
        $r.StdOut | Should -Not -Match 'config-ran'
    }

    It '--help exits 0 and prints usage to stdout' {
        $r = Invoke-Entry -EntryArgs @('--help')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match 'usage: spec-kit-jira'
    }

    It 'no command is a usage error (exit 1)' {
        $r = Invoke-Entry -EntryArgs @()
        $r.ExitCode | Should -Be 1
    }

    It 'an unknown flag is a usage error (exit 1)' {
        $r = Invoke-Entry -EntryArgs @('--bogus')
        $r.ExitCode | Should -Be 1
    }

    It 'an unrecognised command is a usage error (exit 1)' {
        $r = Invoke-Entry -EntryArgs @('frobnicate')
        $r.ExitCode | Should -Be 1
        $r.StdOut | Should -Not -Match '-ran'
    }

    It 'routes config to its Invoke-JiraConfig entry, passing options through' {
        $r = Invoke-Entry -EntryArgs @('config', '--dry-run')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match 'config-ran'
    }

    It 'routes reconcile to its Invoke-JiraReconcile entry' {
        $r = Invoke-Entry -EntryArgs @('reconcile')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match 'reconcile-ran'
    }

    It 'a routed but unbuilt command is a usage error (exit 1)' {
        $r = Invoke-Entry -EntryArgs @('mention')
        $r.ExitCode | Should -Be 1
    }
}
