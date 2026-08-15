# T020/T023 [027] — Pester twin of test_cli_designators.bats.
# `--parent`, `--story`, `--confirm` CLI flags (contracts/seed-cli-contract.md §2).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Cli.psm1') -Force
}

Describe 'Designator CLI flags' {
    It '--parent and --story accumulate into US-joined streams' {
        $out = Invoke-JiraCliParse -Arguments @('seed', '--parent', 'PROJ-1', '--story', 'PROJ-11', '--story', 'PROJ-12')
        $us = [char]0x1F
        $out | Should -Match 'parent_seen=true'
        $out | Should -Match 'parent=PROJ-1'
        $out | Should -Match ([regex]::Escape("stories=PROJ-11${us}PROJ-12"))
        $out | Should -Match 'exit=0'
    }

    It 'a free-text parent containing spaces survives intact' {
        $out = Invoke-JiraCliParse -Arguments @('seed', '--parent', 'Payment webhooks rollout', '--story', 'PROJ-11')
        $out | Should -Match 'parent=Payment webhooks rollout'
    }

    It '--story order is preserved exactly as typed' {
        $out = Invoke-JiraCliParse -Arguments @('seed', '--story', 'PROJ-3', '--story', 'PROJ-1', '--story', 'PROJ-2')
        $us = [char]0x1F
        $out | Should -Match ([regex]::Escape("stories=PROJ-3${us}PROJ-1${us}PROJ-2"))
    }

    It '--confirm is a bare flag' {
        $out = Invoke-JiraCliParse -Arguments @('seed', '--confirm')
        $out | Should -Match 'confirm=true'
    }

    It 'confirm defaults to false' {
        $out = Invoke-JiraCliParse -Arguments @('seed')
        $out | Should -Match 'confirm=false'
    }

    It '--parent requires a value' {
        $out = Invoke-JiraCliParse -Arguments @('seed', '--parent')
        $out | Should -Match 'exit=1'
    }

    It 'a blank --parent value is recorded as parent_seen=true with an empty value' {
        $out = Invoke-JiraCliParse -Arguments @('seed', '--parent', '', '--story', 'PROJ-11')
        $out | Should -Match 'parent_seen=true'
        $out | Should -Match "`nparent=`n"
    }

    It 'an absent --parent flag is recorded as parent_seen=false' {
        $out = Invoke-JiraCliParse -Arguments @('seed', '--story', 'PROJ-11')
        $out | Should -Match 'parent_seen=false'
    }
}
