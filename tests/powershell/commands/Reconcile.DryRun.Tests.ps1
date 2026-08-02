# T022a/T047a [Phase 9, T081] — mirror of tests/bash/commands/test_reconcile_dry_run.bats.
# FR-026 and Constitution XI's dry-run enforcement test for the role mapping
# (010, contracts/role-mapping.md). The mandatory-field-gate dry-run parity
# (§5, checks 5/6) is already covered in Reconcile.Hierarchy.Tests.ps1; this
# file covers the resolved-type prediction and the §6.7 ordering refusal —
# the only §6 refusal reconcile's own §8 re-validation can raise.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue

    function Invoke-CapturedWithCode {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out; $origErr = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($sw)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }
}

Describe 'Invoke-JiraReconcile --dry-run — the declared-hierarchy fixture (010)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $Root 'tests/conformance/fixtures/repo-with-declared-hierarchy') $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-consumer-onboarding/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-consumer-onboarding'
        $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/consumer-hierarchy.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $script:M
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'T022a — names the resolved type of the parent and of every child' {
        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--dry-run', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.dry_run | Should -Be $true
        $obj.actions[0].role | Should -Be 'parent'
        $obj.actions[0].body.fields.issuetype.id | Should -Be '10701'
        $stories = @($obj.actions | Where-Object { $_.role -eq 'story' })
        $stories.Count | Should -Be 2
        $stories[0].body.fields.issuetype.id | Should -Be '10704'
        $stories[1].body.fields.issuetype.id | Should -Be '10704'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -notlike 'GET *' }).Count | Should -Be 0
    }

    It "T022a — the dry-run action set is identical to the real run's over the same starting state" {
        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--dry-run', '--json')
        $dryObj = $r.Out | ConvertFrom-Json
        $dryTypes = ($dryObj.actions | ForEach-Object { $_.body.fields.issuetype.id }) | Sort-Object

        $work2 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $Root 'tests/conformance/fixtures/repo-with-declared-hierarchy') $work2
        $env:JIRA_CONFIG_DIR = Join-Path $work2 '.specify/jira'
        $real = Invoke-CapturedWithCode @('reconcile', (Join-Path $work2 'specs/001-consumer-onboarding/spec.md'), '--json')
        $real.ExitCode | Should -Be 0
        $realObj = $real.Out | ConvertFrom-Json
        $realObj.counts.created | Should -Be @($dryObj.actions).Count
        ($dryTypes -join ',') | Should -Be '10701,10704,10704'
    }

    It 'T047a — a §6.7 ordering refusal is predicted by --dry-run exactly as the real run — same exit code, same bytes, zero writes' {
        $null = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')

        $localf = Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml'
        $obj = (ConvertFrom-JiraConfigYaml -Path $localf) | ConvertFrom-Json -Depth 100
        $obj.resolved_ids.CONSUMER.roles = [ordered]@{
            specification = [ordered]@{ logical_name = 'Story'; id = '10704'; hierarchy_level = '0'; subtask = $false; source = 'declared' }
            story         = [ordered]@{ logical_name = 'Epic'; id = '10701'; hierarchy_level = '1'; subtask = $false; source = 'declared' }
        }
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($localf, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))

        Clear-Content -LiteralPath $script:M.CallLog
        $dry = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--dry-run', '--json')
        $dry.ExitCode | Should -Be 4
        $dry.Out | Should -Match 'reconcile: project CONSUMER: specification names'
        $dry.Out | Should -Match 'is not above story'

        $real = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $real.ExitCode | Should -Be $dry.ExitCode
        $real.Out | Should -Be $dry.Out

        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -notlike 'GET *' }).Count | Should -Be 0
    }
}
