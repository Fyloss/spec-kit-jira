# T007 / T064 [003] — The hook registry READER, PowerShell port.
# Twin of tests/bash/hooks/test_register_hooks.bats: the same input states must
# produce the same classification on both ports (Constitution VI).

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $script:Root 'scripts/powershell/hooks/RegisterHooks.psm1') -Force
    Import-Module (Join-Path $script:Root 'scripts/powershell/lib/Config.psm1') -Force
    # Import the modules we call DIRECTLY last so their exports are not re-scoped
    # by RegisterHooks' internal -Force imports (the nested-import re-scope trap).
    Import-Module (Join-Path $script:Root 'scripts/powershell/lib/Output.psm1') -Force

    function New-Work {
        $w = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $w '.specify') -Force | Out-Null
        return $w
    }

    function Set-CanonicalRegistry {
        # Exactly the shape the host install produces: one eight-field entry per
        # declared event, owned by `jira`.
        param([Parameter(Mandatory)] [string] $Path)
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('hooks:')
        foreach ($e in (Get-JiraHookEventList)) {
            $cmd = Get-JiraHookCommandFor -LifecycleEvent $e
            [void]$sb.AppendLine("  ${e}:")
            [void]$sb.AppendLine('    - extension: jira')
            [void]$sb.AppendLine("      command: $cmd")
            [void]$sb.AppendLine('      enabled: true')
            [void]$sb.AppendLine('      optional: false')
            [void]$sb.AppendLine('      priority: 10')
            [void]$sb.AppendLine("      prompt: Execute $cmd" + '?')
            [void]$sb.AppendLine('      description: A human-readable sentence.')
            [void]$sb.AppendLine('      condition: null')
        }
        [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    }

    function Write-RegistryFromJson {
        param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Json)
        $yaml = ConvertTo-JiraConfigYaml -Json $Json
        [System.IO.File]::WriteAllText($Path, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}

Describe 'The closed set of seven declared events' {
    It 'declares exactly seven, and they are one closed set (research R9)' {
        $events = Get-JiraHookEventList
        $events.Count | Should -Be 7
        ($events | Sort-Object) -join ' ' |
            Should -BeExactly 'after_analyze after_clarify after_implement after_plan after_specify after_tasks before_specify'
    }

    It 'maps before_specify to the feature command and every after_* to reconcile' {
        Get-JiraHookCommandFor -LifecycleEvent 'before_specify' | Should -BeExactly 'speckit.jira.feature'
        foreach ($e in @('after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_implement', 'after_analyze')) {
            Get-JiraHookCommandFor -LifecycleEvent $e | Should -BeExactly 'speckit.jira.reconcile'
        }
    }
}

Describe 'Recognition: ours vs leftover vs foreign' {
    It 'recognises an entry as ours when extension is jira' {
        Test-JiraHookEntryOwnership -EntryJson '{"extension":"jira","command":"speckit.jira.reconcile"}' | Should -BeTrue
        Test-JiraHookEntryOwnership -EntryJson '{"extension":"git","command":"speckit.git.commit"}' | Should -BeFalse
    }

    It 'recognises an entry as leftover when extension is absent and command is one of ours (FR-028)' {
        Test-JiraHookEntryIsLeftover -EntryJson '{"command":"speckit.jira.reconcile","enabled":true,"optional":true}' | Should -BeTrue
        Test-JiraHookEntryIsLeftover -EntryJson '{"command":"speckit.jira.feature","enabled":true}' | Should -BeTrue
        Test-JiraHookEntryIsLeftover -EntryJson '{"extension":"jira","command":"speckit.jira.reconcile"}' | Should -BeFalse
        Test-JiraHookEntryIsLeftover -EntryJson '{"command":"other.ext.thing"}' | Should -BeFalse
    }
}

Describe 'The canonical eight-field shape, asserted on read' {
    BeforeAll {
        $script:Canonical = '{"extension":"jira","command":"speckit.jira.reconcile","enabled":true,"optional":false,"priority":10,"prompt":"Execute speckit.jira.reconcile?","description":"Mirror.","condition":null}'
    }

    It 'accepts the canonical entry' {
        (Get-JiraHookEntryShapeError -EntryJson $script:Canonical) | Should -BeNullOrEmpty
    }

    It 'reports every missing field, field by field' {
        foreach ($f in @('extension', 'command', 'enabled', 'optional', 'priority', 'prompt', 'description', 'condition')) {
            $obj = $script:Canonical | ConvertFrom-Json -Depth 100
            $map = [ordered]@{}
            foreach ($p in $obj.PSObject.Properties) { if ($p.Name -ne $f) { $map[$p.Name] = $p.Value } }
            $err = Get-JiraHookEntryShapeError -EntryJson (ConvertTo-JiraJsonValue $map)
            $err | Should -Not -BeNullOrEmpty
            $err | Should -Match ([regex]::Escape($f))
        }
    }

    It 'requires the EXPANDED prompt default, never a {command} placeholder (research R2)' {
        $bad = $script:Canonical -replace 'Execute speckit\.jira\.reconcile\?', 'Execute {command}?'
        Get-JiraHookEntryShapeError -EntryJson $bad | Should -Match 'prompt'
        (Get-JiraHookEntryShapeError -EntryJson $script:Canonical) | Should -BeNullOrEmpty
    }

    It 'rejects a non-empty condition — it suppresses agent dispatch (research R8)' {
        $bad = $script:Canonical -replace '"condition":null', '"condition":"configured"'
        Get-JiraHookEntryShapeError -EntryJson $bad | Should -Match 'condition'
    }
}

Describe 'Classification over a whole registry' {
    BeforeEach {
        $script:Work = New-Work
        $script:Ext = Join-Path $script:Work '.specify/extensions.yml'
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'classifies a canonical registry as seven present' {
        Set-CanonicalRegistry -Path $script:Ext
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.present.Count | Should -Be 7
        $h.missing.Count | Should -Be 0
        $h.disabled.Count | Should -Be 0
        $h.duplicated.Count | Should -Be 0
        $h.held_disabled.Count | Should -Be 0
        $h.unreadable | Should -BeFalse
        $h.PSObject.Properties['repair_hint'] | Should -BeNullOrEmpty
    }

    It 'reports a deleted entry as missing and names the official install command (FR-025)' {
        Set-CanonicalRegistry -Path $script:Ext
        $json = ConvertFrom-JiraConfigYaml -Path $script:Ext | ConvertFrom-Json -Depth 100
        $hooks = [ordered]@{}
        foreach ($p in $json.hooks.PSObject.Properties) { if ($p.Name -ne 'after_tasks') { $hooks[$p.Name] = $p.Value } }
        Write-RegistryFromJson -Path $script:Ext -Json (ConvertTo-JiraJsonValue ([ordered]@{ hooks = $hooks }))
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.missing | Should -Contain 'after_tasks'
        $h.present.Count | Should -Be 6
        $h.repair_hint | Should -Match 'specify extension add'
        $h.repair_hint | Should -Match 'after_tasks'
    }

    It 'reports an operator-disabled entry as disabled — neither present nor missing' {
        Set-CanonicalRegistry -Path $script:Ext
        $json = ConvertFrom-JiraConfigYaml -Path $script:Ext | ConvertFrom-Json -Depth 100
        $json.hooks.after_implement[0].enabled = $false
        Write-RegistryFromJson -Path $script:Ext -Json (ConvertTo-JiraJsonValue $json)
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.disabled | Should -Contain 'after_implement'
        $h.present.Count | Should -Be 6
        $h.missing.Count | Should -Be 0
    }

    It 'never classifies a foreign extension entry as ours (FR-006)' {
        $text = "hooks:`n  after_plan:`n    - extension: git`n      command: speckit.git.commit`n      enabled: true`n"
        [System.IO.File]::WriteAllText($script:Ext, $text, (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.missing | Should -Contain 'after_plan'
        $h.duplicated.Count | Should -Be 0
    }
}

Describe 'Leftover pre-manifest entries (FR-028)' {
    BeforeEach {
        $script:Work = New-Work
        $script:Ext = Join-Path $script:Work '.specify/extensions.yml'
        Set-CanonicalRegistry -Path $script:Ext
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'classifies a leftover — our command, no extension field — as duplicated' {
        $json = ConvertFrom-JiraConfigYaml -Path $script:Ext | ConvertFrom-Json -Depth 100
        $json.hooks.after_plan = @($json.hooks.after_plan) + @([pscustomobject]@{ command = 'speckit.jira.reconcile'; enabled = $true })
        Write-RegistryFromJson -Path $script:Ext -Json (ConvertTo-JiraJsonValue $json)
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.duplicated | Should -Contain 'after_plan'
        # An annotation, not a partition: the canonical entry is still present.
        $h.present | Should -Contain 'after_plan'
    }

    It 'names every affected event and a copy-pasteable manual edit' {
        $json = ConvertFrom-JiraConfigYaml -Path $script:Ext | ConvertFrom-Json -Depth 100
        $json.hooks.after_plan = @($json.hooks.after_plan) + @([pscustomobject]@{ command = 'speckit.jira.reconcile'; enabled = $true })
        $json.hooks.before_specify = @($json.hooks.before_specify) + @([pscustomobject]@{ command = 'speckit.jira.feature'; enabled = $true })
        Write-RegistryFromJson -Path $script:Ext -Json (ConvertTo-JiraJsonValue $json)
        $hint = (Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100).repair_hint
        $hint | Should -Match 'after_plan'
        $hint | Should -Match 'before_specify'
        $hint | Should -Match ([regex]::Escape('.specify/extensions.yml'))
        $hint | Should -Match ([regex]::Escape('extension: jira'))
    }

    It 'writes NOTHING while classifying (FR-022)' {
        $before = (Get-FileHash -LiteralPath $script:Ext -Algorithm SHA256).Hash
        $null = Get-JiraHookHealth -Path $script:Ext
        (Get-FileHash -LiteralPath $script:Ext -Algorithm SHA256).Hash | Should -BeExactly $before
    }
}

Describe 'The disable record in the classification' {
    BeforeEach {
        $script:Work = New-Work
        $script:Ext = Join-Path $script:Work '.specify/extensions.yml'
        Set-CanonicalRegistry -Path $script:Ext
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'annotates a recorded event held_disabled and names the release flag' {
        $h = Get-JiraHookHealth -Path $script:Ext -DisabledJson '["after_implement"]' | ConvertFrom-Json -Depth 100
        $h.held_disabled | Should -Contain 'after_implement'
        # The registry still says enabled: true (the install rewrote it), so the
        # event is ALSO present — held_disabled annotates, it does not partition.
        $h.present | Should -Contain 'after_implement'
        $h.repair_hint | Should -Match ([regex]::Escape('--enable-hook'))
    }
}

Describe 'Unreadable (FR-024)' {
    BeforeEach {
        $script:Work = New-Work
        $script:Ext = Join-Path $script:Work '.specify/extensions.yml'
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'reports a broken file as unreadable and NOT as missing hooks (FR-024)' {
        [System.IO.File]::WriteAllText($script:Ext, "hooks:`n  after_plan:`n   - broken`n     : : :`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.unreadable | Should -BeTrue
        $h.missing.Count | Should -Be 0
        $h.present.Count | Should -Be 0
        $h.disabled.Count | Should -Be 0
    }

    It 'names a YAML anchor as the construct that defeated the reader' {
        [System.IO.File]::WriteAllText($script:Ext, "defaults: &defaults`n  enabled: true`nhooks:`n  after_plan:`n    - extension: jira`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.unreadable | Should -BeTrue
        $h.repair_hint | Should -Match 'anchor'
    }

    It 'names a flow collection as the construct that defeated the reader' {
        [System.IO.File]::WriteAllText($script:Ext, "hooks:`n  after_plan: [{extension: jira, command: speckit.jira.reconcile}]`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.repair_hint | Should -Match 'flow'
    }

    It 'accepts an EMPTY flow collection — our own writer emits it' {
        [System.IO.File]::WriteAllText($script:Ext, "hooks:`n  after_plan: []`n", (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-JiraHookHealth -Path $script:Ext | ConvertFrom-Json -Depth 100
        $h.unreadable | Should -BeFalse
    }

    It 'reports an absent registry as every event missing — not unreadable' {
        $h = Get-JiraHookHealth -Path (Join-Path $script:Work 'nope.yml') | ConvertFrom-Json -Depth 100
        $h.missing.Count | Should -Be 7
        $h.present.Count | Should -Be 0
        $h.unreadable | Should -BeFalse
    }
}

Describe 'The writer is gone (FR-022, SC-011)' {
    It 'no longer exports Set-JiraHookRegistration' {
        (Get-Command -Module RegisterHooks -Name 'Set-JiraHookRegistration' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    It 'contains no construct that opens the registry for writing' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'scripts/powershell/hooks/RegisterHooks.psm1')
        $src | Should -Not -Match 'Set-Content|Out-File|Add-Content|Move-Item|Remove-Item|Clear-Content|WriteAllText'
    }
}
