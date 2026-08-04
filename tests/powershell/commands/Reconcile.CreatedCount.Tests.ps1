# 015 T027 [US3] — mirror of tests/bash/commands/test_reconcile_created_count.bats.
# `counts.created` reports confirmed creations, never planned ones (contract
# §5, data-model.md §6, research R4).

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mandatory-field'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Output.psm1') -Force

    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-reporting'
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue

    function Invoke-CapturedWithCode {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out; $origErr = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($sw)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }

    function New-MockConfig {
        param([string] $Json)
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($path, $Json)
        return $path
    }

    function Set-BothFieldsRecorded {
        $code = Invoke-JiraConfig -Arguments @('config', 'PM', '--issue-type', 'PM=story=Story', `
                '--field-default', 'PM=Deliverable=Business Owner=Platform Team', `
                '--field-default', 'PM=Deliverable=Program Increment=PI-2026-Q3', '--json')
        $code | Should -Be 0
    }
}

Describe 'Invoke-JiraReconcile — counts.created (015)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-reporting/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'a fully successful run: counts.created is the confirmed count (unchanged from before this feature, FR-013)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out | ConvertFrom-Json).counts.created | Should -Be 2
    }

    It 'every planned creation refused: counts.created is zero, alongside the fail-closed status and the refusal warning' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        Stop-JiraMock -Mock $script:M

        $cfg = '{"projects":{"PM":"company"},"createmetaFields":{"10101":"parent-mandatory"},"faults":{"PM":{"status":400}}}'
        $script:M = Start-JiraMock -ConfigPath (New-MockConfig $cfg)
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 2
        ($r.Out | ConvertFrom-Json).counts.created | Should -Be 0
    }

    It 'counts.created is derived from the apply outcome, not recomputed from the planned action set (FR-013)' {
        # Get-Command lets us shadow the module-scoped function the same way
        # the bash mirror shadows apply_writes_with_recognition: a canned
        # single-entry outcome against a plan that actually creates two
        # (parent + story) makes the two counts provably different if the
        # summary's counts.created were wired to the planned count instead.
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        Mock -CommandName Invoke-JiraApplyWriteSetWithRecognition -ModuleName Reconcile -MockWith {
            [ordered]@{ ExitCode = 0; Created = @([ordered]@{ key = 'PM-1'; role = 'parent'; local_id = 'aaaaaaaaaaaaaaaa' }) }
        }

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out | ConvertFrom-Json).counts.created | Should -Be 1
    }

    It '--dry-run still reports the planned count (FR-012)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--dry-run', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out | ConvertFrom-Json).counts.created | Should -Be 2
        (Get-JiraMockCallLog -Mock $script:M) -join "`n" | Should -Not -Match 'POST /rest/api/3/issue'
    }
}
