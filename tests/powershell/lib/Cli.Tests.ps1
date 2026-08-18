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
}

Describe 'Invoke-JiraCliParse — field-default flags (011, T018)' {
    It 'parses --field-default KEY=Type=Label=Value' {
        $out = Invoke-JiraCliParse @('config', '--field-default', 'CONSUMER=Epic=Business=Platform')
        $out | Should -Match 'field_defaults=CONSUMER=Epic=Business=Platform'
        $out | Should -Match 'exit=0'
    }

    It 'is repeatable, argv order preserved, joined with \x1f (not a space, so a spaced value cannot swallow the next entry)' {
        $out = Invoke-JiraCliParse @('config', '--field-default', 'CONSUMER=Epic=Owner=A', '--field-default', 'CONSUMER=Story=Team=B')
        $us = [char]0x1F
        $out | Should -Match ([regex]::Escape("field_defaults=CONSUMER=Epic=Owner=A${us}CONSUMER=Story=Team=B"))
    }

    It 'two values that each contain a space are still separable (the \x1f join, not a space, is the boundary)' {
        $out = Invoke-JiraCliParse @('config', '--field-default', 'CONSUMER=Epic=Business Owner=Platform Team', '--field-default', 'CONSUMER=Story=Team=Payments')
        $us = [char]0x1F
        $out | Should -Match ([regex]::Escape("field_defaults=CONSUMER=Epic=Business Owner=Platform Team${us}CONSUMER=Story=Team=Payments"))
    }

    It 'accepts a value containing further ''='' signs (split on the first three separators only)' {
        $out = Invoke-JiraCliParse @('config', '--field-default', 'CONSUMER=Epic=Owner=a=b=c')
        $out | Should -Match ([regex]::Escape('field_defaults=CONSUMER=Epic=Owner=a=b=c'))
    }

    It 'accepts a value containing spaces' {
        $out = Invoke-JiraCliParse @('config', '--field-default', 'CONSUMER=Epic=Business Owner=Platform Team')
        $out | Should -Match ([regex]::Escape('field_defaults=CONSUMER=Epic=Business Owner=Platform Team'))
    }

    It 'rejects a malformed value (missing a segment), same message shape as --issue-type' {
        $out = Invoke-JiraCliParse @('config', '--field-default', 'CONSUMER=Epic')
        $out | Should -Match 'exit=1'
        $out | Should -Match 'invalid --field-default value'
    }

    It 'requires a value' {
        (Invoke-JiraCliParse @('config', '--field-default')) | Should -Match 'exit=1'
    }

    It 'parses --field-value KEY=Type=Label=Value, repeatable, same shape as --field-default' {
        $out = Invoke-JiraCliParse @('reconcile', '--field-value', 'CONSUMER=Epic=Owner=A', '--field-value', 'CONSUMER=Story=Team=B')
        $us = [char]0x1F
        $out | Should -Match ([regex]::Escape("field_values=CONSUMER=Epic=Owner=A${us}CONSUMER=Story=Team=B"))
        $out | Should -Match 'exit=0'
    }

    It 'rejects a malformed --field-value value' {
        $out = Invoke-JiraCliParse @('reconcile', '--field-value', 'CONSUMER=Epic')
        $out | Should -Match 'exit=1'
        $out | Should -Match 'invalid --field-value value'
    }

    It 'parses --accept-defaults as a boolean flag' {
        $out = Invoke-JiraCliParse @('reconcile', '--accept-defaults')
        $out | Should -Match 'accept_defaults=true'
        $out | Should -Match 'exit=0'
    }

    It 'defaults --accept-defaults to false' {
        $out = Invoke-JiraCliParse @('reconcile')
        $out | Should -Match 'accept_defaults=false'
    }
}

Describe 'Invoke-JiraCliParse — task-mirror flags (Phase 5, US3, 022)' {
    It 'parses --task-mirror KEY=(subtask or checklist), repeatable, last wins per key' {
        $out = Invoke-JiraCliParse @('config', '--task-mirror', 'COMP=checklist', '--task-mirror', 'COMP=subtask', '--task-mirror', 'PLAT=checklist')
        $out | Should -Match ([regex]::Escape('task_mirrors=COMP=checklist COMP=subtask PLAT=checklist'))
        $out | Should -Match 'exit=0'
    }

    It 'requires a value' {
        $out = Invoke-JiraCliParse @('config', '--task-mirror')
        $out | Should -Match 'exit=1'
        $out | Should -Match ([regex]::Escape('--task-mirror requires a value (--task-mirror KEY=<subtask|checklist>)'))
    }

    It 'rejects a malformed value (bad enum)' {
        $out = Invoke-JiraCliParse @('config', '--task-mirror', 'COMP=bogus')
        $out | Should -Match 'exit=1'
        $out | Should -Match ([regex]::Escape('invalid --task-mirror value: COMP=bogus (expected <PROJECT_KEY>=<subtask|checklist>)'))
    }
}

# =============================================================================
# T028 [030] — every command dispatch entry calls the resolution chokepoint
# (contracts/connection-settings.md C1.5). Enumerated from the dispatch
# table's own commands directory, not hand-listed.
# =============================================================================

Describe 'T028 — every command module calls the resolution chokepoint' {
    It 'every file in scripts/powershell/commands/ calls Resolve-JiraConnection' {
        $dir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($f in Get-ChildItem -Path $dir -Filter '*.psm1') {
            $content = Get-Content -Raw -LiteralPath $f.FullName
            if ($content -notmatch 'Resolve-JiraConnection') { $missing.Add($f.Name) }
        }
        ($missing -join ', ') | Should -BeNullOrEmpty
    }

    It 'the dispatch table has exactly the five entry points this assertion covers' {
        $dir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
        (Get-ChildItem -Path $dir -Filter '*.psm1').Count | Should -Be 5
    }
}
