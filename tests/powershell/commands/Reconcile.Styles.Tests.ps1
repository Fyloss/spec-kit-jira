# T042 [US4] — Dual-style support. Pester twin of
# tests/bash/commands/test_reconcile_styles.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-two-styles'
    $env:JIRA_CONFIG_DIR = Join-Path $script:Fixture '.specify/jira'
    $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_PROJECT_KEY = $null
    $env:SPEC_KIT_JIRA_PLAN_CONTEXT = $null

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }

    function Invoke-Billing {
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing-invoices'
        return (Invoke-Captured @('reconcile', '--dry-run', '--json', (Join-Path $script:Fixture 'specs/billing-001-invoices/spec.md')) | ConvertFrom-Json)
    }
    function Invoke-Infra {
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-infra-pipeline'
        return (Invoke-Captured @('reconcile', '--dry-run', '--json', (Join-Path $script:Fixture 'specs/infra-001-pipeline/spec.md')) | ConvertFrom-Json)
    }
}

Describe 'Dual-style support (US4)' {
    It 'both styles declare the project, unconditionally (FR-026)' {
        $b = Invoke-Billing
        $script:code | Should -Be 0
        $b.actions[1].body.fields.project.key | Should -Be 'COMP'

        $i = Invoke-Infra
        $script:code | Should -Be 0
        $i.actions[1].body.fields.project.key | Should -Be 'TEAM'
    }

    It "each payload declares an issue type belonging to that project, never the other's (FR-027, SC-013)" {
        (Invoke-Billing).actions[1].body.fields.issuetype.id | Should -Be '10004'
        (Invoke-Infra).actions[1].body.fields.issuetype.id | Should -Be '20002'
    }

    It 'the team-managed payload declares no priority, and the run still succeeds (FR-029, SC-012)' {
        $i = Invoke-Infra
        $script:code | Should -Be 0
        ($i.actions[1].body.fields.PSObject.Properties.Name -contains 'priority') | Should -BeFalse
    }

    It 'the company-managed payload declares a priority (contrast case)' {
        $b = Invoke-Billing
        ($b.actions[1].body.fields.PSObject.Properties.Name -contains 'priority') | Should -BeTrue
    }
}
