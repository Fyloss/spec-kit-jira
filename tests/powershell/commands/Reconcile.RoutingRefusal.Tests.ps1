# T044/T046 [Phase 5, US3] — mirror of
# tests/bash/commands/test_reconcile_routing_refusal.bats. The four-finding
# routing refusal (contracts/routing-resolution.md C6.1-C6.5, spec FR-007).
#
# The conformance corpus proves these messages byte-identical across ports.
# What it cannot do is assert the ABSENCE of a phrase, or enumerate the three
# rank-3 states from one fixture — a scenario is one run against one repository.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force

    $script:Cfg = '{"projects":[{"key":"ALPHA"}],"routing":[{"match":{"folder_prefix":"003-billing-"},"project":"ALPHA"}]}'
    $script:CfgEmpty = '{"projects":[{"key":"ALPHA"}]}'
    $script:CfgTeams = '{"projects":[{"key":"ALPHA"}],"routing":[],"teams":[{"id":"beta","project":"BETA","folder_prefix":"beta-"}]}'
}

Describe 'The four-finding routing refusal' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:Work) {
            Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'C6.2 reports all four ranks' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007-legacy-cleanup' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Match 'Rule route:'
        $m | Should -Match 'Team route:'
        $m | Should -Match 'Your team:'
        $m | Should -Match 'Default:'
    }

    It 'C6.2 names the specification it could not place' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007-legacy-cleanup' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Match '"007-legacy-cleanup"'
    }

    It 'C6.1 states that nothing was written' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Match 'zero writes'
    }

    It "C6.2 rank 1 distinguishes 'none declared' from 'none matched'" {
        $a = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $a | Should -Match 'none of the 1 routing rules matched'
        $b = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:CfgEmpty -ConfigDir $script:Work -AlreadyBound $false
        $b | Should -Match 'no routing rules are declared'
    }

    It "C6.2 rank 2 distinguishes 'no catalogue' from 'no prefix matched'" {
        $a = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $a | Should -Match 'no teams: catalogue is declared'
        $b = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:CfgTeams -ConfigDir $script:Work -AlreadyBound $false
        $b | Should -Match 'none of the 1 team folder prefixes matched'
    }

    It 'C6.3 state 1: no personal.yml at all' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Match 'personal\.yml does not exist'
    }

    It 'C6.3 state 2: personal.yml exists but selects no team' {
        Set-Content -LiteralPath (Join-Path $script:Work 'personal.yml') -Value '# no team here'
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Match 'declares no team: key'
        $m | Should -Not -Match 'does not exist'
    }

    It 'C6.3 state 3: already bound, so rank 3 never ran' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/008-bound' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $true
        $m | Should -Match 'already bound'
        $m | Should -Not -Match 'no team is selected'
    }

    It 'C6.3 the three states produce three different messages' {
        $s1 = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        Set-Content -LiteralPath (Join-Path $script:Work 'personal.yml') -Value '# no team here'
        $s2 = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $s3 = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $true
        $s1 | Should -Not -Be $s2
        $s2 | Should -Not -Be $s3
        $s1 | Should -Not -Be $s3
    }

    It 'C6.5 does not prescribe routing_default as the only fix' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Not -Match 'add routing_default to config\.yml'
    }

    It 'C6.5 offers all three remedies' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Match 'add a rule or a teams: entry'
        $m | Should -Match 'select your team in'
        $m | Should -Match 'or declare routing_default in'
    }

    It 'C6.2 rank 4 says the key is absent when it is' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Match 'routing_default is not declared'
    }

    It 'the message is a single line' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        ($m -split "`n").Count | Should -Be 1
    }
}
