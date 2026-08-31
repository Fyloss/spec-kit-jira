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

Describe 'The rank-by-rank routing refusal' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:Work) {
            Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'C6.2 reports all five ranks' {
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

    It '035 C2.6 the `-AlreadyBound` switch is now inert — it cannot be true here' {
        # Kept in the signature so no caller changes, but a bound specification
        # never reaches this refusal: it resolves at rank 3. Passing it must
        # therefore produce the SAME message as omitting it.
        $asBound = Get-JiraReconcileRoutingRefusal -Folder '/x/008-bound' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $true
        $asUnbound = Get-JiraReconcileRoutingRefusal -Folder '/x/008-bound' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $asBound | Should -BeExactly $asUnbound
    }

    It '035 C2.6 the message reports all FIVE ranks, the record among them' {
        $m = Get-JiraReconcileRoutingRefusal -Folder '/x/007-legacy' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $m | Should -Match 'Rule route:'
        $m | Should -Match 'Team route:'
        $m | Should -Match 'Its own record: no ticket marker'
        $m | Should -Match 'Your team:'
        $m | Should -Match 'Default:'
    }

    It 'C6.3 the two reachable rank-4 states still produce different messages' {
        # 035 retires the third: "already bound" cannot occur here any more.
        # The two that remain have different remedies — create the file, or
        # uncomment a line — so conflating them would still send one operator
        # to edit a file that is already correct.
        $s1 = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        Set-Content -Path (Join-Path $script:Work 'personal.yml') -Value '# no team here'
        $s2 = Get-JiraReconcileRoutingRefusal -Folder '/x/007' -ConfigJson $script:Cfg -ConfigDir $script:Work -AlreadyBound $false
        $s2 | Should -Not -Be $s1
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
