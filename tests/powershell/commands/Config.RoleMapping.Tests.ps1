# T006/T007/T029/T030/T032/T038 [Phase 4, US1] — mirror of
# tests/bash/commands/test_config_role_mapping.bats. The ceremony's role
# mapping (010, contracts/role-mapping.md): declared -> operator -> derived,
# over all three roles in ONE pass. The consumer fixture (two issue types at
# hierarchy level 1, thirteen at level 0) previously refused with
# `parent-level-ambiguous` before the story tier was ever examined — the
# "ordering trap" this feature repairs (research R1).

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

    function Write-RoleMappingConfig {
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

    function Read-LocalBinding {
        (ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | ConvertFrom-Json
    }
}

Describe 'Config role mapping (010)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/consumer-hierarchy.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'T006/T007 — an undeclared, unanswered mapping reports BOTH ambiguous tiers in one run' {
        Write-RoleMappingConfig
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'the specification level'
        $r.Out | Should -Match 'Epic'
        $r.Out | Should -Match 'Service Category'
        $r.Out | Should -Match 'the story level'
        $r.Out | Should -Match 'Story'
        $r.Out | Should -Match 'Defect'
        Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml') | Should -Be $false
    }

    It 'T029 — a declared hierarchy resolves both tiers with source: declared' {
        Write-RoleMappingConfig "    hierarchy:`n      specification: Epic`n      story: Story"
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $local = Read-LocalBinding
        $local.resolved_ids.CONSUMER.roles.specification.logical_name | Should -Be 'Epic'
        $local.resolved_ids.CONSUMER.roles.specification.source | Should -Be 'declared'
        $local.resolved_ids.CONSUMER.roles.story.logical_name | Should -Be 'Story'
        $local.resolved_ids.CONSUMER.roles.story.source | Should -Be 'declared'
        $local.resolved_ids.CONSUMER.child_type.logical_name | Should -Be 'Story'
        $local.resolved_ids.CONSUMER.parent_type.logical_name | Should -Be 'Epic'
    }

    It 'T030 — an operator answer (--issue-type) resolves both tiers with source: operator' {
        Write-RoleMappingConfig
        $r = Invoke-ConfigCaptured @('config', '--issue-type', 'CONSUMER=specification=Epic', '--issue-type', 'CONSUMER=story=Story', '--json')
        $r.ExitCode | Should -Be 0
        $local = Read-LocalBinding
        $local.resolved_ids.CONSUMER.roles.specification.logical_name | Should -Be 'Epic'
        $local.resolved_ids.CONSUMER.roles.specification.source | Should -Be 'operator'
        $local.resolved_ids.CONSUMER.roles.story.logical_name | Should -Be 'Story'
        $local.resolved_ids.CONSUMER.roles.story.source | Should -Be 'operator'
    }

    It 'T032 — declaring an unknown issue type name refuses, naming the offered candidates' {
        Write-RoleMappingConfig "    hierarchy:`n      specification: NoSuchType`n      story: Story"
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'NoSuchType'
        $r.Out | Should -Match 'which this project does not offer at that tier'
        $r.Out | Should -Match 'Epic'
        Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml') | Should -Be $false
    }

    It 'T032 — declaring a sub-task type for specification refuses as a subtask misuse, not an unknown type' {
        Write-RoleMappingConfig "    hierarchy:`n      specification: `"Sous-tâche`"`n      story: Story"
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'which is a sub-task type in this project'
        Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml') | Should -Be $false
    }

    It 'T038 — an unresolved story tier surfaces as structured JSON even when specification is declared' {
        Write-RoleMappingConfig "    hierarchy:`n      specification: Epic"
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match '"unresolved_roles"'
        $r.Out | Should -Match '"role":"story"'
    }

    It 'T064/T065 — a declared task role validates, persists, and no longer reports §7.4 (012, FR-012)' {
        Write-RoleMappingConfig "    hierarchy:`n      specification: Epic`n      story: Story`n      task: `"Sous-tâche`""
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        # §7.4's "recorded, not mirrored yet" note stopped firing once the
        # task tier shipped (012, FR-012) — the task role is now mirrored.
        $r.Out | Should -Not -Match 'is not mirrored yet'
        $local = Read-LocalBinding
        $local.resolved_ids.CONSUMER.roles.task.logical_name | Should -Be 'Sous-tâche'
        $local.resolved_ids.CONSUMER.roles.task.source | Should -Be 'declared'
        $local.resolved_ids.CONSUMER.roles.task.subtask | Should -Be $true
    }

    It 'T064 — an undeclared task role produces no roles.task, no note, and no refusal' {
        Write-RoleMappingConfig "    hierarchy:`n      specification: Epic`n      story: Story"
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'task is recorded as'
        $local = Read-LocalBinding
        ($local.resolved_ids.CONSUMER.roles.PSObject.Properties.Name -contains 'task') | Should -Be $false
    }

    It 'T089 — the unresolved-role refusal never reads stdin; it cannot hang the hook or --json paths' {
        Write-RoleMappingConfig
        # A closed console input: any attempted read throws immediately rather
        # than blocking. If the ceremony ever tried to prompt, this run would
        # throw instead of completing with its ordinary exit code (FR-008).
        $origIn = [Console]::In
        [Console]::SetIn([System.IO.StreamReader]::new([System.IO.Stream]::Null))
        try {
            $r = Invoke-ConfigCaptured @('config', '--json')
        } finally {
            [Console]::SetIn($origIn)
        }
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match '"unresolved_roles"'
    }
}
