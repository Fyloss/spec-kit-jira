# T014 — CLI arg-parsing + exit-code table, PowerShell side.
# Mirror of tests/bash/lib/test_cli.bats. Cross-port byte-parity is proven in bats.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Cli.psm1') -Force
}

Describe 'Get-JiraExitCode' {
    It 'maps the table to 0/1/2/3/4/5/9' {
        Get-JiraExitCode ok          | Should -Be 0
        Get-JiraExitCode usage       | Should -Be 1
        Get-JiraExitCode fail_closed | Should -Be 2
        Get-JiraExitCode auth        | Should -Be 3
        Get-JiraExitCode config      | Should -Be 4
        Get-JiraExitCode prereq      | Should -Be 5
        Get-JiraExitCode block       | Should -Be 9
    }
}

Describe 'Invoke-JiraCliParse' {
    It 'parses a bare command with defaults' {
        $out = Invoke-JiraCliParse @('config')
        $out | Should -Match 'command=config'
        $out | Should -Match 'dry_run=false'
        $out | Should -Match 'on_drift=abort'
        $out | Should -Match 'exit=0'
    }

    It 'parses --dry-run and --json' {
        $out = Invoke-JiraCliParse @('reconcile', '--dry-run', '--json')
        $out | Should -Match 'dry_run=true'
        $out | Should -Match 'json=true'
    }

    It 'treats an invalid --on-drift value as a usage error' {
        $out = Invoke-JiraCliParse @('reconcile', '--on-drift=bogus')
        $out | Should -Match 'exit=1'
        $out | Should -Match 'error='
    }

    It 'treats an unknown flag as a usage error' {
        (Invoke-JiraCliParse @('reconcile', '--nope')) | Should -Match 'exit=1'
    }

    It 'carries the mention issue-key argument' {
        $out = Invoke-JiraCliParse @('mention', 'PROJ-123')
        $out | Should -Match 'command=mention'
        $out | Should -Match 'args=PROJ-123'
    }
}
