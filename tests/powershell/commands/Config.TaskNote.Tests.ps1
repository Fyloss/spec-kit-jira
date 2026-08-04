# T043a/T044 [US1] — Now that the task tier ships (012), a recorded field
# default for the task role's type is CONSUMED by the bridge, not merely
# recorded: the ceremony's §2.8 "recorded, not yet consumed" report (FR-027)
# must stop naming it (FR-012), and the §7.4 "not mirrored yet" status line
# must stop firing at all. Mirror of tests/bash/commands/test_config_task_note.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Config.psm1') -Force
    $script:Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-field-defaults'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $code = Invoke-JiraConfig -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return [pscustomobject]@{ Code = $code; Out = $sw.ToString() }
    }
}

Describe 'Invoke-JiraConfig — the task role joins the bridge-written set (012, FR-012)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $script:Fixture '.specify') (Join-Path $script:Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:Mock 'configs/field-defaults.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: FD`n    style: company_managed`n    hierarchy:`n      specification: Deliverable`n      story: Story`n      task: `"Sub-task`"`nrouting_default: FD`n")
    }
    AfterEach {
        Stop-JiraMock -Mock $script:M
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'a task role declared: a recorded field default for its type is never reported not-yet-consumed' {
        $r = Invoke-Captured @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=Platform Team', '--field-default', 'FD=Deliverable=Program Increment=PI-2026-Q3', '--field-default', 'FD=Sub-task=T-Shirt Estimate=5', '--json')
        $r.Code | Should -Be 0
        $r.Out | Should -Not -Match 'recorded, not yet consumed'
    }

    It "a declared task role no longer emits the section 7.4 'not mirrored yet' note" {
        $r = Invoke-Captured @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=Platform Team', '--field-default', 'FD=Deliverable=Program Increment=PI-2026-Q3', '--json')
        $r.Code | Should -Be 0
        $r.Out | Should -Not -Match 'is not mirrored yet'
    }
}
