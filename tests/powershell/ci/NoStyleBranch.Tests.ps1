# T047 [US4] — Payload assembly must never branch on a project's style
# (FR-028, Principle VII). Twin of tests/bash/ci/test_no_style_branch.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

Describe 'plan_apply payload assembly contains no style-keyed branch (FR-028)' {
    It 'PlanApply.psm1 names no company_managed/team_managed literal' {
        $file = Join-Path $script:Root 'scripts/powershell/sink/jira/PlanApply.psm1'
        $bad = Select-String -LiteralPath $file -Pattern 'company_managed|team_managed'
        $bad | Should -BeNullOrEmpty
    }

    It 'plan_apply.sh names no company_managed/team_managed literal' {
        $file = Join-Path $script:Root 'scripts/bash/sink/jira/plan_apply.sh'
        $bad = Select-String -LiteralPath $file -Pattern 'company_managed|team_managed'
        $bad | Should -BeNullOrEmpty
    }
}
