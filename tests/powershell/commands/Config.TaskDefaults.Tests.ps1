# T054 [US6] — mirror of tests/bash/commands/test_config_task_defaults.bats.
# The field-defaults ceremony's ask-scope follows the declared roles: a
# `task` role joins the specification and story types on the same
# closed-question terms; with no `task` role the ceremony asks nothing about
# any sub-task type (FR-035).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Write-TaskDefaultsConfig {
        param([string]$ExtraLines = '')
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('projects:')
        $lines.Add('  - key: CONSUMER')
        if ($ExtraLines) { foreach ($l in ($ExtraLines -split "`n")) { $lines.Add($l) } }
        $lines.Add('routing_default: CONSUMER')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
    }

    function Invoke-ConfigCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($sw)
        try { $code = Invoke-JiraConfig -Arguments $CmdArgs }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }
}

Describe 'Config task-defaults ask-scope (012, US6)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        # The consumer fixture's Sous-tâche type (id 10716) is overridden here
        # to carry a required, defaultable field — nothing else about the
        # project changes.
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"CONSUMER":"company"},"issueTypeStyle":{"CONSUMER":"consumer"},"createmetaFields":{"10716":"consumer-task-mandatory"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'T054 — a declared task role asks about the sub-task type''s required field, by its Jira label (FR-035)' {
        Write-TaskDefaultsConfig "    hierarchy:`n      specification: Epic`n      story: Story`n      task: `"Sous-tâche`""
        $r = Invoke-ConfigCaptured -CmdArgs @('config', 'CONSUMER', '--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'Definition of Done'
        $r.Out | Should -Match ([regex]::Escape("--field-default 'CONSUMER=Sous-tâche=Definition of Done=<value>'"))
    }

    It 'T054 — with no task role declared, the ceremony asks nothing about any sub-task type (FR-035)' {
        Write-TaskDefaultsConfig "    hierarchy:`n      specification: Epic`n      story: Story"
        $r = Invoke-ConfigCaptured -CmdArgs @('config', 'CONSUMER', '--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'Definition of Done'
        $r.Out | Should -Not -Match 'Sous-tâche'
    }
}
