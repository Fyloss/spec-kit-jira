# T011 [US1] — Routing resolution. Pester twin of
# tests/bash/commands/test_reconcile_routing.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira'
    $script:Cfg = (Import-JiraConfig -ConfigDir $script:Fixture).Json

    function New-SpecWithFolder {
        param([string] $Folder)
        $dir = Join-Path $TestDrive $Folder
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $spec = Join-Path $dir 'spec.md'
        @(
            '# Feature Specification: Invoices', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a signed-in user', '- **When** they open the board', '- **Then** the widgets load'
        ) -join "`n" | Set-Content -LiteralPath $spec -NoNewline
        return $spec
    }

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Routing resolution (US1)' {
    It 'a folder-prefix rule routes the spec to its project (FR-002)' {
        $r = Resolve-JiraReconcileRouting -Folder 'billing-042-invoices' -ConfigJson $script:Cfg
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'COMP'
    }

    It 'no rule matches: falls back to routing_default (FR-003)' {
        $r = Resolve-JiraReconcileRouting -Folder 'checkout-007-cart' -ConfigJson $script:Cfg
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'COMP'
    }

    It 'no rule and no routing_default: refused (FR-005)' {
        $cfg = $script:Cfg | ConvertFrom-Json
        $cfg.PSObject.Properties.Remove('routing_default')
        $r = Resolve-JiraReconcileRouting -Folder 'checkout-007-cart' -ConfigJson ($cfg | ConvertTo-Json -Compress -Depth 10)
        $r.ExitCode | Should -Not -Be 0
        $r.ProjectKey | Should -BeNullOrEmpty
    }

    It 'explicit SPEC_KIT_JIRA_PROJECT_KEY override wins over config (FR-013)' {
        $spec = New-SpecWithFolder 'billing-042-invoices'
        $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'OTHER'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '004-billing-invoices'
        $env:JIRA_CONFIG_DIR = $script:Fixture
        # This test is about ROUTING precedence, not the creation-context binding
        # for project "OTHER" (which the fixture never bound) — bypass that lookup
        # with a minimal override supplying the issue type the assembly guard requires.
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"99999"}'
        try {
            $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $spec) | ConvertFrom-Json
            $out.actions[0].body.fields.project.key | Should -Be 'OTHER'
        }
        finally {
            Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\SPEC_KIT_JIRA_SPEC_SLUG -ErrorAction SilentlyContinue
            Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
            Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        }
    }

    It 'a placeholder-key override is refused, zero writes (FR-005)' {
        $spec = New-SpecWithFolder 'billing-042-invoices'
        $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'PROJ'
        $env:JIRA_CONFIG_DIR = $script:Fixture
        try {
            $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $spec) 2>&1
            $script:code | Should -Not -Be 0
        }
        finally {
            Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
        }
    }

    It "epic strategy is taken from the resolved project's config declaration (FR-006)" {
        Get-JiraReconcileEpicStrategy -ProjectKey 'COMP' -ConfigJson $script:Cfg | Should -Be 'per_feature'
    }

    It 'epic strategy falls back to per_repo when the project has none declared' {
        Get-JiraReconcileEpicStrategy -ProjectKey 'NOPE' -ConfigJson $script:Cfg | Should -Be 'per_repo'
    }
}
