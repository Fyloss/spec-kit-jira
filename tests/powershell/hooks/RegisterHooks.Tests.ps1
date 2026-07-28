# T080 [US9] — Idempotent after_* lifecycle-hook registration, PowerShell side.
# Mirror of tests/bash/hooks/test_register_hooks.bats. Cross-port byte agreement is
# proven in bats; here we assert the registration semantics (FR-045, FR-047, FR-048).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $HookDir = Join-Path $Root 'scripts/powershell/hooks'
    Import-Module (Join-Path $HookDir 'RegisterHooks.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    # Import the modules we call DIRECTLY last so their exports are not re-scoped by
    # RegisterHooks' internal -Force imports (the nested-import re-scope trap).
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force
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
        @($h.present).Count | Should -Be 7
        @($h.missing).Count | Should -Be 0
        @($h.disabled).Count | Should -Be 0
        $h.PSObject.Properties.Name | Should -Not -Contain 'repair_hint'

        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        $obj.hooks.PSObject.Properties.Remove('after_analyze')
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($Ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $Ext | ConvertFrom-Json
        $h.missing[0] | Should -Be 'after_analyze'
        @($h.present).Count | Should -Be 6
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
        @($h.present).Count | Should -Be 6
        @($h.missing).Count | Should -Be 0
    }

    It 'reports every hook missing for an absent file' {
        $h = Get-JiraHookHealth -Path (Join-Path $Work 'nope.yml') | ConvertFrom-Json
        @($h.missing).Count | Should -Be 7
        @($h.present).Count | Should -Be 0
    }

    It 'reports a deleted before_specify feature hook as missing (T094)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        $obj.hooks.PSObject.Properties.Remove('before_specify')
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($Ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $Ext | ConvertFrom-Json
        @($h.missing) | Should -Contain 'before_specify'
        @($h.present).Count | Should -Be 6
        $h.repair_hint | Should -Match 'repair-hooks'
    }

    It 'lists a disabled feature hook under disabled (T094, FR-048)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        $obj.hooks.before_specify[0].enabled = $false
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($Ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $Ext | ConvertFrom-Json
        @($h.disabled) | Should -Contain 'before_specify'
        @($h.missing).Count | Should -Be 0
    }

    It 'registers before_specify -> speckit.jira.feature enabled+optional, set-not-append (T047)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        [void](Set-JiraHookRegistration -Path $Ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        @($obj.hooks.before_specify).Count | Should -Be 1
        $obj.hooks.before_specify[0].command | Should -Be 'speckit.jira.feature'
        $obj.hooks.before_specify[0].enabled | Should -BeTrue
        $obj.hooks.before_specify[0].optional | Should -BeTrue
        foreach ($e in @('after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_implement', 'after_analyze')) {
            @($obj.hooks.$e | Where-Object { $_.command -eq 'speckit.jira.reconcile' }).Count | Should -Be 1
        }
    }

    It 'never re-adds or re-enables an operator-disabled feature hook (T047, FR-048)' {
        [void](Set-JiraHookRegistration -Path $Ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        $obj.hooks.before_specify[0].enabled = $false
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($Ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        [void](Set-JiraHookRegistration -Path $Ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        @($obj.hooks.before_specify).Count | Should -Be 1
        $obj.hooks.before_specify[0].enabled | Should -BeFalse
    }

    # --- adoption is never fired by a hook (003 T014, FR-029) ----------------

    It 'writes no adoption entry under any event (003 T014, FR-029)' {
        # Adoption requires an operator confirmation and is a one-time deliberate
        # transition; hooks are automatic and non-blocking, so the two never mix.
        [void](Set-JiraHookRegistration -Path $Ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $Ext | ConvertFrom-Json
        @($obj.hooks.PSObject.Properties.Name).Count | Should -Be 7
        foreach ($e in $obj.hooks.PSObject.Properties.Name) {
            @($obj.hooks.$e | Where-Object { $_.command -match 'adopt' }).Count | Should -Be 0
        }
    }

    It 'leaves register_hooks free of any adoption vocabulary (003 T014, FR-029)' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $HookDir 'RegisterHooks.psm1')
        $src | Should -Not -Match 'adopt'
    }

    It 'reports no adoption hook as missing (003 T014, FR-029)' {
        $h = Get-JiraHookHealth -Path (Join-Path $Work 'absent.yml') | ConvertFrom-Json
        @($h.missing | Where-Object { $_ -match 'adopt' }).Count | Should -Be 0
    }
}
