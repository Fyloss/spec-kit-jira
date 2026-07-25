# T080 [US9] — Idempotent after_* lifecycle-hook registration, PowerShell side.
# Mirror of tests/bash/hooks/test_register_hooks.bats. Cross-port byte agreement is
# proven in bats; here we assert the registration semantics (FR-045, FR-047, FR-048).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $HookDir = Join-Path $Root '.specify/extensions/jira/scripts/powershell/hooks'
    Import-Module (Join-Path $HookDir 'RegisterHooks.psm1') -Force
    Import-Module (Join-Path $Root '.specify/extensions/jira/scripts/powershell/lib/Config.psm1') -Force
    # Import the modules we call DIRECTLY last so their exports are not re-scoped by
    # RegisterHooks' internal -Force imports (the nested-import re-scope trap).
    Import-Module (Join-Path $Root '.specify/extensions/jira/scripts/powershell/lib/Output.psm1') -Force
}

Describe 'after_* hook registration' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        $script:Ext = Join-Path $Work '.specify/extensions.yml'
    }
    AfterEach {
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'creates an absent extensions.yml with all six lifecycle hooks (FR-045)' {
        $r = Set-JiraHookRegistration -Path $Ext
        $r.ExitCode | Should -Be 0
        $r.Status | Should -Be 'created'
        Test-Path -LiteralPath $Ext | Should -BeTrue
        $json = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        foreach ($e in @('after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_implement', 'after_analyze')) {
            @($json.hooks.$e | Where-Object { $_.command -eq 'speckit.jira.reconcile' }).Count | Should -Be 1
        }
    }

    It 'adds no duplicates and reports unchanged on a re-run (FR-047)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        $r = Set-JiraHookRegistration -Path $Ext
        $r.Status | Should -Be 'unchanged'
        $json = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        @($json.hooks.after_plan).Count | Should -Be 1
    }

    It 'repairs a missing hook without touching the others (FR-047)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        $trimmed = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        $trimmed.hooks.PSObject.Properties.Remove('after_tasks')
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $trimmed)
        [System.IO.File]::WriteAllText($Ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $r = Set-JiraHookRegistration -Path $Ext
        $r.Status | Should -Be 'repaired'
        $json = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        @($json.hooks.after_tasks | Where-Object { $_.command -eq 'speckit.jira.reconcile' }).Count | Should -Be 1
    }

    It 'keeps an operator-disabled hook disabled across repair (FR-048)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        $obj.hooks.after_implement[0].enabled = $false
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($Ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        [void](Set-JiraHookRegistration -Path $Ext)
        $json = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        @($json.hooks.after_implement).Count | Should -Be 1
        $json.hooks.after_implement[0].enabled | Should -BeFalse
    }

    It 'reports present/missing in the contract shape (FR-047, run-summary.schema.json)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        $h = Get-JiraHookHealth -Path $Ext | ConvertFrom-Json
        @($h.present).Count | Should -Be 6
        @($h.missing).Count | Should -Be 0
        @($h.disabled).Count | Should -Be 0
        $h.PSObject.Properties.Name | Should -Not -Contain 'repair_hint'

        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        $obj.hooks.PSObject.Properties.Remove('after_analyze')
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($Ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $Ext | ConvertFrom-Json
        $h.missing[0] | Should -Be 'after_analyze'
        @($h.present).Count | Should -Be 5
        $h.repair_hint | Should -Match 'repair-hooks'
    }

    It 'lists an operator-disabled hook under disabled — neither present nor missing (FR-048)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        $obj.hooks.after_implement[0].enabled = $false
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($Ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $Ext | ConvertFrom-Json
        $h.disabled[0] | Should -Be 'after_implement'
        @($h.present).Count | Should -Be 5
        @($h.missing).Count | Should -Be 0
    }

    It 'reports every hook missing for an absent file' {
        $h = Get-JiraHookHealth -Path (Join-Path $Work 'nope.yml') | ConvertFrom-Json
        @($h.missing).Count | Should -Be 6
        @($h.present).Count | Should -Be 0
    }
}
