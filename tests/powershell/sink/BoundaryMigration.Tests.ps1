# T053 [Phase 6, US4] — the one-time upgrade of a pre-release estate onto the
# boundary (FR-020/FR-020a/FR-020b/FR-021), PowerShell side. Mirror of
# tests/bash/sink/test_boundary_migration.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-pre-release-migration'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Identity.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Client.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_ID_SOURCE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile — pre-release boundary migration' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/preserve-pre-release.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'an untouched pre-release story migrates with nothing above the boundary and no duplication (FR-020a)' {
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $pre1 = $out.actions | Where-Object { $_.url -like '*PRE-1' }
        $pre1 | Should -Not -BeNullOrEmpty
        $pre1.body.fields.description.content[0].content[0].text | Should -Be 'Synced from spec-kit — do not edit below this line'
        $texts = @($pre1.body.fields.description.content | ForEach-Object { $_.content[0].text })
        @($texts | Where-Object { $_ -eq 'As a user, I want my note kept.' }).Count | Should -Be 1
        @($out.warnings | Where-Object { $_ -match 'PRE-1' }).Count | Should -Be 0
    }

    It 'a human-prefixed pre-release story keeps its prefix exactly (FR-020a)' {
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $pre2 = $out.actions | Where-Object { $_.url -like '*PRE-2' }
        $pre2 | Should -Not -BeNullOrEmpty
        $pre2.body.fields.description.content[0].content[0].text | Should -Be 'A human paragraph added after the mirror last wrote.'
        $pre2.body.fields.description.content[1].content[0].text | Should -Be 'Synced from spec-kit — do not edit below this line'
        $texts = @($pre2.body.fields.description.content | ForEach-Object { $_.content[0].text })
        @($texts | Where-Object { $_ -eq 'As a user, I want my note kept.' }).Count | Should -Be 1
        @($out.warnings | Where-Object { $_ -match 'PRE-2' }).Count | Should -Be 0
    }

    It 'an ambiguous pre-release story loses nothing and produces one warning naming the ticket key (FR-020b)' {
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $pre3 = $out.actions | Where-Object { $_.url -like '*PRE-3' }
        $pre3 | Should -Not -BeNullOrEmpty
        $pre3.body.fields.description.content[0].content[0].text | Should -Be 'Some unrelated content nobody expected.'
        $pre3.body.fields.description.content[1].content[0].text | Should -Be 'Synced from spec-kit — do not edit below this line'
        @($out.warnings | Where-Object { $_ -match 'PRE-3' }).Count | Should -Be 1
    }

    It 'the run after each migration reports zero writes (FR-021)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        Clear-Content -LiteralPath $script:M.CallLog
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $out.counts.updated | Should -Be 0
        $out.counts.created | Should -Be 0
        # reconcile emits JSON `null`, not `[]`, for an empty warnings list —
        # ConvertFrom-Json turns that into $null, and @($null) has Count 1.
        @($out.warnings | Where-Object { $_ }).Count | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' }).Count | Should -Be 0
    }
}
