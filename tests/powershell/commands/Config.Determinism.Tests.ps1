# T042 [US1] — Determinism + machine-readable ceremony (FR-001, FR-002, SC-004).
# Mirror of tests/bash/commands/test_config_determinism.bats. The config run
# reads only, emits a machine-readable summary with --json, and writes a
# byte-identical config.local.yml on an unchanged project (proven here on this
# port; cross-port byte-parity is asserted in the Bash suite via a pwsh diff).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $script:Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-config'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
}

Describe 'Config ceremony determinism' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $M
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'emits a valid machine-readable run summary with --json (FR-002)' {
        # Commands write user output via [Console]::Out (bypassing the pipeline);
        # capture it with a StringWriter redirect.
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--json')) }
        finally { [Console]::SetOut($orig) }
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        $obj.schema_version | Should -Be '1.0'
        $obj.command | Should -Be 'config'
        $obj.exit_code | Should -Be 0
    }

    It 'writes a byte-identical config.local.yml on two runs (FR-003)' {
        [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--json'))
        $first = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')
        [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--json'))
        $second = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')
        $second | Should -BeExactly $first
    }

    It 'preserves the discovered ids by logical name and the operator local layer' {
        [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--json'))
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')
        $obj = $json | ConvertFrom-Json
        ($obj.resolved_ids.COMP.issue_types | Where-Object { $_.logical_name -eq "Story" }).id | Should -Be '10102'
        $obj.resolved_ids.COMP.priorities.Critical | Should -Be '1'
        $obj.resolved_ids.COMP.statuses.Backlog | Should -Be '1'
        $obj.site_alias | Should -Be 'prod'
    }
}

Describe 'Role-mapping determinism (010, contract §5.2)' {
    BeforeEach {
        $script:RWork = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $RWork '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $RWork '.specify/jira'
        $script:RM = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/consumer-hierarchy.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $RM.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $RM
        Remove-Item -Recurse -Force $RWork -ErrorAction SilentlyContinue
    }

    It 'T020 — a second run over a declared, unchanged mapping writes byte-identical YAML and asks no question' {
        $lines = "projects:`n  - key: CONSUMER`n    hierarchy:`n      specification: Epic`n      story: Story`nrouting_default: CONSUMER`n"
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), $lines)

        [void](Invoke-JiraConfig -Arguments @('config', '--json'))
        $first = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')

        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--json')) }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        $sw.ToString() | Should -Not -Match 'unresolved_roles'

        $second = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')
        $second | Should -BeExactly $first
    }

    It 'T039/T082 — a committed declaration supersedes a recorded operator answer, once, then converges' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: CONSUMER`nrouting_default: CONSUMER`n")

        [void](Invoke-JiraConfig -Arguments @('config', '--issue-type', 'CONSUMER=specification=Epic', '--issue-type', 'CONSUMER=story=Story', '--json'))
        $local1 = (ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | ConvertFrom-Json
        $local1.resolved_ids.CONSUMER.roles.specification.source | Should -Be 'operator'

        $lines = "projects:`n  - key: CONSUMER`n    hierarchy:`n      specification: Service Category`n      story: Story`nrouting_default: CONSUMER`n"
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), $lines)

        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--json')) }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        $sw.ToString() | Should -Match 'specification is declared as "Service Category" in config.yml; the local answer "Epic" was superseded.'

        $second = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')
        $local2obj = (ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | ConvertFrom-Json
        $local2obj.resolved_ids.CONSUMER.roles.specification.logical_name | Should -Be 'Service Category'
        $local2obj.resolved_ids.CONSUMER.roles.specification.source | Should -Be 'declared'

        $sw3 = [System.IO.StringWriter]::new()
        [Console]::SetOut($sw3)
        [Console]::SetError($sw3)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--json')) }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        $sw3.ToString() | Should -Not -Match 'was superseded'
        $third = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')
        $third | Should -BeExactly $second
    }
}
