# T023 [US2] — Creation context resolution. Pester twin of
# tests/bash/commands/test_reconcile_plan_context.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira'
    $script:Cfg = (Import-JiraConfig -ConfigDir $script:Fixture).Json
}

Describe 'Creation context resolution (US2)' {
    It 'story_type_id comes from resolved_ids.<KEY>.issue_types.Story (FR-007)' {
        $r = Get-JiraReconcilePlanContextFromBinding -BaseUrl 'https://mock' -ProjectKey 'COMP' -ConfigDir $script:Fixture -ConfigJson $script:Cfg
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).story_type_id | Should -Be '10004'
    }

    It 'priority resolves in two steps: priority_map then resolved_ids.priorities (FR-008)' {
        $r = Get-JiraReconcilePlanContextFromBinding -BaseUrl 'https://mock' -ProjectKey 'COMP' -ConfigDir $script:Fixture -ConfigJson $script:Cfg
        $obj = $r.Json | ConvertFrom-Json
        $obj.priority_ids.P1 | Should -Be '1'
        $obj.priority_ids.P2 | Should -Be '3'
        $obj.priority_ids.P3 | Should -Be '4'
    }

    It 'an unresolvable priority level is omitted rather than blocking the run (FR-011)' {
        $cfg = $script:Cfg | ConvertFrom-Json
        $cfg.projects[0].priority_map = [pscustomobject]@{ P1 = 'Highest' }
        $r = Get-JiraReconcilePlanContextFromBinding -BaseUrl 'https://mock' -ProjectKey 'COMP' -ConfigDir $script:Fixture -ConfigJson ($cfg | ConvertTo-Json -Compress -Depth 10)
        $obj = $r.Json | ConvertFrom-Json
        ($obj.priority_ids.PSObject.Properties.Name -contains 'P2') | Should -BeFalse
        $obj.priority_ids.P1 | Should -Be '1'
    }

    It 'the machine-owned binding wins over the committed team config for issue types (FR-009)' {
        $r = Get-JiraReconcilePlanContextFromBinding -BaseUrl 'https://mock' -ProjectKey 'COMP' -ConfigDir $script:Fixture -ConfigJson $script:Cfg
        ($r.Json | ConvertFrom-Json).story_type_id | Should -Be '10004'
    }

    It 'estimation field id is carried when the binding declares one' {
        $r = Get-JiraReconcilePlanContextFromBinding -BaseUrl 'https://mock' -ProjectKey 'COMP' -ConfigDir $script:Fixture -ConfigJson $script:Cfg
        ($r.Json | ConvertFrom-Json).estimation_field_id | Should -Be 'customfield_20011'
    }

    It 'the project has no persisted binding: refused, distinct cause (FR-010)' {
        $r = Get-JiraReconcilePlanContextFromBinding -BaseUrl 'https://mock' -ProjectKey 'NOPE' -ConfigDir $script:Fixture -ConfigJson $script:Cfg
        $r.ExitCode | Should -Be 3
        $r.Json | Should -BeNullOrEmpty
    }

    It 'an explicit SPEC_KIT_JIRA_PLAN_CONTEXT overrides the derived object wholesale (FR-013)' {
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"99999"}'
        try {
            $r = Get-JiraReconcilePlanContextFromBinding -BaseUrl 'https://mock' -ProjectKey 'COMP' -ConfigDir $script:Fixture -ConfigJson $script:Cfg
            $r.ExitCode | Should -Be 0
            $obj = $r.Json | ConvertFrom-Json
            $obj.story_type_id | Should -Be '99999'
            ($obj.PSObject.Properties.Name -contains 'priority_ids') | Should -BeFalse
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue }
    }

    It 'the local layer is missing entirely: reported as never-bound, not the project-not-bound fault' {
        $emptyDir = Join-Path $TestDrive 'never-bound/.specify/jira'
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        Copy-Item -Path (Join-Path $script:Fixture 'config.yml') -Destination (Join-Path $emptyDir 'config.yml')
        $r = Get-JiraReconcilePlanContextFromBinding -BaseUrl 'https://mock' -ProjectKey 'COMP' -ConfigDir $emptyDir -ConfigJson $script:Cfg
        $r.ExitCode | Should -Be 2
        $r.Json | Should -BeNullOrEmpty
    }

    It 'Invoke-JiraReconcile reads config.yml for priority_map even when only project key and epic strategy are overridden (T057, FR-008 partial)' {
        $legacy = Join-Path $Root 'tests/conformance/fixtures/repo-with-reconcile-legacy/.specify/jira'
        $spec = Join-Path $TestDrive 'priority.md'
        @(
            '# Feature Specification: Priority Wiring', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a signed-in user', '- **When** they open the board', '- **Then** the widgets load'
        ) -join "`n" | Set-Content -LiteralPath $spec -NoNewline

        $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
        $env:SPEC_KIT_JIRA_EPIC_STRATEGY = 'per_repo'
        $env:JIRA_CONFIG_DIR = $legacy
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = $null
        try {
            $sw = [System.IO.StringWriter]::new()
            $orig = [Console]::Out
            [Console]::SetOut($sw)
            try { [void](Invoke-JiraReconcile -Arguments @('reconcile', '--dry-run', '--json', $spec)) }
            finally { [Console]::SetOut($orig) }
            $out = $sw.ToString() | ConvertFrom-Json
            # The legacy fixture's config.yml maps P1 -> Highest, and its
            # config.local.yml resolves Highest -> "1" — resolvable only if
            # config.yml is actually read when SPEC_KIT_JIRA_PLAN_CONTEXT is
            # not overridden, even though the project key and epic strategy
            # are.
            $out.actions[0].body.fields.priority.id | Should -Be '1'
        }
        finally {
            $env:JIRA_CONFIG_DIR = $null
        }
    }
}
