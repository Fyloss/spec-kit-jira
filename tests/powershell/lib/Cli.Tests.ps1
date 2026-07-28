# T014 — CLI arg-parsing + exit-code table, PowerShell side.
# Mirror of tests/bash/lib/test_cli.bats. Cross-port byte-parity is proven in bats.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
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

    # --- adopt command surface (003 T008) ------------------------------------

    It 'accepts the adopt command (003 T008)' {
        $out = Invoke-JiraCliParse @('adopt')
        $out | Should -Match 'command=adopt'
        $out | Should -Match 'exit=0'
    }

    It 'accepts the boolean --yes flag, defaulting to false (003 T008)' {
        (Invoke-JiraCliParse @('adopt')) | Should -Match 'yes=false'
        $out = Invoke-JiraCliParse @('adopt', '--yes')
        $out | Should -Match 'yes=true'
        $out | Should -Match 'exit=0'
    }

    It 'rejects --on-drift for adopt with a usage error (003 T008)' {
        $out = Invoke-JiraCliParse @('adopt', '--on-drift=proceed')
        $out | Should -Match 'exit=1'
        $out | Should -Match '--on-drift'
    }

    It 'rejects --on-drift declared before the adopt command (003 T008)' {
        (Invoke-JiraCliParse @('--on-drift=abort', 'adopt')) | Should -Match 'exit=1'
    }

    It 'still accepts --on-drift for reconcile (003 T008 regression)' {
        $out = Invoke-JiraCliParse @('reconcile', '--on-drift=proceed')
        $out | Should -Match 'exit=0'
        $out | Should -Match 'on_drift=proceed'
    }

    # --- --bind (003 T120, US4) ----------------------------------------------

    It 'accepts a repeatable --bind and carries every value (003 T120)' {
        $out = Invoke-JiraCliParse @('adopt', '--bind', '003-a=ADO-1', '--bind', '004-b:us2=ADO-9')
        $out | Should -Match 'exit=0'
        $out | Should -Match 'binds=003-a=ADO-1 004-b:us2=ADO-9'
    }

    It 'validates --bind STRUCTURALLY only (003 T120)' -TestCases @(
        @{ Value = '=ADO-1' }
        @{ Value = '003-a=' }
        @{ Value = 'no-equals-sign' }
    ) {
        param($Value)
        (Invoke-JiraCliParse @('adopt', '--bind', $Value)) | Should -Match 'exit=1'
    }

    It 'treats a --bind without a value as a usage error (003 T120)' {
        $out = Invoke-JiraCliParse @('adopt', '--bind')
        $out | Should -Match 'exit=1'
        $out | Should -Match 'requires a value'
    }

    It 'applies NO issue-key shape check in the parser (research §9)' {
        $out = Invoke-JiraCliParse @('adopt', '--bind', '003-a=not-a-key')
        $out | Should -Match 'exit=0'
        $out | Should -Match 'binds=003-a=not-a-key'
    }

    # --- --spec (003 T154, US6) ----------------------------------------------

    It 'accepts a repeatable --spec and carries every value (003 T154)' {
        $out = Invoke-JiraCliParse @('adopt', '--spec', '003-a', '--spec', '004-b')
        $out | Should -Match 'exit=0'
        $out | Should -Match 'specs=003-a 004-b'
    }

    It 'treats a --spec without a value as a usage error (003 T154)' {
        $out = Invoke-JiraCliParse @('adopt', '--spec')
        $out | Should -Match 'exit=1'
        $out | Should -Match 'requires a value'
    }

    It 'treats an empty --spec value as a usage error (003 T154)' {
        $out = Invoke-JiraCliParse @('adopt', '--spec', '')
        $out | Should -Match 'exit=1'
        $out | Should -Match 'non-empty'
    }

    It 'combines --bind and --spec in the order given (003 T120, T154)' {
        $out = Invoke-JiraCliParse @('adopt', '--spec', '003-a', '--bind', '003-a=ADO-1', '--spec', '004-b', '--yes')
        $out | Should -Match 'exit=0'
        $out | Should -Match 'specs=003-a 004-b'
        $out | Should -Match 'binds=003-a=ADO-1'
        $out | Should -Match 'yes=true'
    }
}
