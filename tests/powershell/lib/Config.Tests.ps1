# T028 [US4] — Config storage layer, PowerShell side. Mirror of
# tests/bash/lib/test_config.bats. Cross-port byte-parity of the YAML->JSON
# output and the version reader is proven in the bats suite.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Config.psm1') -Force
    $script:ExtYml = Join-Path $PSScriptRoot '../../../extension.yml'

    function New-TempConfigDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    $script:ValidTeam = @'
# Team config (committable, credential-free).
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
    issue_types:
      Epic: "10001"
      Story: "10002"
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "billing-"
    project: PROJ
routing_default: PROJ
privacy:
  allowlist:
    - support.example.atlassian.net
'@
}

Describe 'Get-JiraExtensionVersion' {
    It 'reads the version field from extension.yml (single source)' {
        $expected = (Select-String -Path $script:ExtYml -Pattern '^\s+version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
        Get-JiraExtensionVersion | Should -Be $expected
    }
}

Describe 'Assert-JiraSingleVersionSource' {
    It 'rejects a stray version marker (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'VERSION') -Value '0.9.9'
        $env:JIRA_CONFIG_DIR = $d
        try { Assert-JiraSingleVersionSource | Should -Be 4 }
        finally { Remove-Item env:JIRA_CONFIG_DIR; Remove-Item -Recurse -Force $d }
    }
    It 'passes when no stray marker exists' {
        $d = New-TempConfigDir
        $env:JIRA_CONFIG_DIR = $d
        try { Assert-JiraSingleVersionSource | Should -Be 0 }
        finally { Remove-Item env:JIRA_CONFIG_DIR; Remove-Item -Recurse -Force $d }
    }
}

Describe 'ConvertFrom-JiraConfigYaml' {
    It 'parses mappings, sequences, and quoted scalars into canonical JSON' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'config.yml'
        Set-Content -Path $f -Value $script:ValidTeam -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path $f
        $o = $json | ConvertFrom-Json
        $o.routing_default | Should -Be 'PROJ'
        $o.projects[0].style | Should -Be 'company_managed'
        $o.projects[0].issue_types.Epic | Should -Be '10001'
        $o.privacy.allowlist[0] | Should -Be 'support.example.atlassian.net'
        Remove-Item -Recurse -Force $d
    }

    It 'coerces true/false to JSON booleans' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'c.yml'
        Set-Content -Path $f -Value "generation:`n  design_section: false`n" -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path $f
        $json | Should -Be '{"generation":{"design_section":false}}'
        Remove-Item -Recurse -Force $d
    }

    It "keeps a map key with an apostrophe (a Won't Do status) in the round-trip" {
        # Regression (002 US1): keys sorted after an apostrophe key (style,
        # style_source) were dropped by the reader. Twin of the bats test.
        $d = New-TempConfigDir
        $f = Join-Path $d 'local.yml'
        $yaml = ConvertTo-JiraConfigYaml -Json '{"resolved_ids":{"TEAM":{"statuses":{"Done":"13","Won''t Do":"14"},"style":"team_managed","style_source":"api"}}}'
        [System.IO.File]::WriteAllText($f, $yaml + "`n")
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.resolved_ids.TEAM.statuses."Won't Do" | Should -Be '14'
        $obj.resolved_ids.TEAM.style | Should -Be 'team_managed'
        $obj.resolved_ids.TEAM.style_source | Should -Be 'api'
        Remove-Item -Recurse -Force $d
    }
}

Describe 'Import-JiraConfig' {
    It 'accepts a valid team config (exit 0)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).routing_default | Should -Be 'PROJ'
        Remove-Item -Recurse -Force $d
    }

    It 'merges config.local overrides over the team config' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "site_alias: prod`noverrides:`n  routing_default: OTHER`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).routing_default | Should -Be 'OTHER'
        Remove-Item -Recurse -Force $d
    }

    It 'fails when config.yml is absent (exit 4)' {
        $d = New-TempConfigDir
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 4
        Remove-Item -Recurse -Force $d
    }

    It 'rejects an ATATT token shape and never echoes the secret (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value ($script:ValidTeam + "`nsite_url: ATATT3xFfGF0secrettoken`n") -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'credential|Atlassian'
        ($r.Errors -join "`n") | Should -Not -Match 'ATATT3xFfGF0secrettoken'
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a real *.atlassian.net host in the local layer (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "overrides:`n  site: acme.atlassian.net`n" -NoNewline
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 4
        Remove-Item -Recurse -Force $d
    }

    It 'does NOT scan privacy.allowlist for atlassian hosts (FR-053)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a missing routing_default (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    epic_strategy: per_repo`n    task_strategy: subtask`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'routing_default'
        Remove-Item -Recurse -Force $d
    }

    It 'requires link_type when task_strategy is linked_story (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    epic_strategy: per_repo`n    task_strategy: linked_story`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'link_type'
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a case-variant project style like the Bash port — "Company_Managed" is invalid (NFR-1)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: Company_Managed`n    epic_strategy: per_repo`n    task_strategy: subtask`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'style'
        Remove-Item -Recurse -Force $d
    }

    It 'keeps sibling projects when a local override touches only one of them' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: PROJ`n    style: company_managed`n    epic_strategy: per_repo`n    task_strategy: subtask`n  - key: OPS`n    style: team_managed`n    epic_strategy: per_repo`n    task_strategy: subtask`nrouting_default: PROJ`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "overrides:`n  projects:`n    - key: PROJ`n      epic_strategy: per_feature`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        $merged = $r.Json | ConvertFrom-Json
        @($merged.projects).Count | Should -Be 2
        @($merged.projects)[0].key | Should -Be 'PROJ'
        @($merged.projects)[0].epic_strategy | Should -Be 'per_feature'
        @($merged.projects)[0].style | Should -Be 'company_managed'
        @($merged.projects)[1].key | Should -Be 'OPS'
        Remove-Item -Recurse -Force $d
    }

    It 'rejects an unknown top-level key (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value ($script:ValidTeam + "`nmystery: value`n") -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'unknown'
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a phase_status_map that is not a mapping to status names (exit 4, T074)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    epic_strategy: per_repo`n    task_strategy: subtask`n    phase_status_map: `"not-a-mapping`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'phase_status_map'
        Remove-Item -Recurse -Force $d
    }

    It 'accepts a valid phase_status_map and halted_statuses (T074)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    epic_strategy: per_repo`n    task_strategy: subtask`n    phase_status_map:`n      after_specify: `"To Do`"`n      after_plan: `"In Progress`"`n    halted_statuses:`n      - `"Blocked`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a halted_statuses that is neither a list nor a string (exit 4, T074)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    epic_strategy: per_repo`n    task_strategy: subtask`n    halted_statuses:`n      count: 3`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'halted_statuses'
        Remove-Item -Recurse -Force $d
    }
}

Describe 'The operator disable record (T009, FR-007, FR-029)' {
    # Twin of the T008 cases in tests/bash/lib/test_config.bats. The registry
    # cannot carry the operator's decision across a reinstall (research R5), so
    # it is recorded in the gitignored local binding instead.
    BeforeEach {
        $script:Dir = New-TempConfigDir
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue
    }

    It 'reads an absent record as the empty set' {
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '[]'
    }

    It 'reads a local binding with no hooks key as the empty set' {
        Set-Content -Path (Join-Path $script:Dir 'config.local.yml') -Value "site_alias: `"prod`"`n" -NoNewline
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '[]'
    }

    It 'round-trips a written record' {
        (Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir) | Should -BeExactly 'recorded'
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_implement"]'
    }

    It 'reports an already-recorded event unchanged and never duplicates it' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir
        (Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir) | Should -BeExactly 'unchanged'
        @((Get-JiraHooksDisabled -ConfigDir $script:Dir) | ConvertFrom-Json).Count | Should -Be 1
    }

    It 'orders the record so two runs write byte-identical bytes (FR-003)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_tasks' -ConfigDir $script:Dir
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_clarify' -ConfigDir $script:Dir
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_clarify","after_tasks"]'
    }

    It 'reports an unknown event name and IGNORES it rather than failing the run' {
        Set-Content -Path (Join-Path $script:Dir 'config.local.yml') `
            -Value "hooks:`n  disabled:`n    - after_implement`n    - after_typo`n" -NoNewline
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_implement"]'
    }

    It 'reports an unknown event name on record and does not fail the run' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'not_an_event' -ConfigDir $script:Dir
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '[]'
    }

    It 'predicts the record write under -DryRun without performing it (Constitution XI)' {
        (Add-JiraHooksDisabled -LifecycleEvent 'after_plan' -ConfigDir $script:Dir -DryRun $true) | Should -BeExactly 'recorded'
        Test-Path -LiteralPath (Join-Path $script:Dir 'config.local.yml') | Should -BeFalse
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '[]'
    }

    It 'clears an event from the record on release (FR-007, FR-029)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_plan' -ConfigDir $script:Dir
        (Remove-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir) | Should -BeExactly 'released'
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_plan"]'
    }

    It 'reports releasing an unrecorded event as a no-op' {
        (Remove-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir) | Should -BeExactly 'unrecorded'
    }

    It 'predicts the release under -DryRun without performing it (Constitution XI)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir
        (Remove-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir -DryRun $true) | Should -BeExactly 'released'
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_implement"]'
    }

    It "preserves the operator's site_alias and overrides" {
        Set-Content -Path (Join-Path $script:Dir 'config.local.yml') `
            -Value "overrides:`n  routing_default: OPS`nsite_alias: `"prod`"`n" -NoNewline
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $script:Dir 'config.local.yml') | ConvertFrom-Json
        $json.site_alias | Should -BeExactly 'prod'
        $json.overrides.routing_default | Should -BeExactly 'OPS'
        $json.hooks.disabled[0] | Should -BeExactly 'after_implement'
    }

    It 'accepts the hooks key in local-binding schema validation (T013)' {
        Set-Content -Path (Join-Path $script:Dir 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $script:Dir 'config.local.yml') `
            -Value "hooks:`n  disabled:`n    - after_implement`n" -NoNewline
        (Import-JiraConfig -ConfigDir $script:Dir).ExitCode | Should -Be 0
    }
}

Describe 'Empty collections round-trip (003 T010 regression)' {
    # Twin of the bats case: the writer emits `key: []` / `key: {}` and the
    # reader must return a collection, not the string "[]" / "{}". The hook
    # registry reader depends on it — `after_plan: []` is what our own
    # serialiser writes for an event with no entries.
    It 'reads a written empty collection back as a collection' {
        $d = New-TempConfigDir
        $yaml = ConvertTo-JiraConfigYaml -Json '{"a":[],"b":{},"c":"x"}'
        Set-Content -Path (Join-Path $d 'rt.yml') -Value $yaml -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'rt.yml')
        $json | Should -BeExactly '{"a":[],"b":{},"c":"x"}'
        Remove-Item -Recurse -Force $d
    }

    It 'keeps a QUOTED [] a string — only the bare flow form is a collection' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'q.yml') -Value "a: `"[]`"`nb: `"{}`"`n" -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'q.yml')
        $json | Should -BeExactly '{"a":"[]","b":"{}"}'
        Remove-Item -Recurse -Force $d
    }
}

Describe 'Block sequences at the parent key indentation (003 T011 regression)' {
    # Twin of the bats cases. PyYAML — which is what `specify extension add`
    # serialises the hook registry with — emits block sequences at the SAME
    # indentation as their parent key. This reader required a greater indent, so
    # the hook registry of every real installation parsed as `{"installed":null}`
    # and hook health reported a healthy repository unreadable.
    It "reads a sequence at its parent key's indentation" {
        $d = New-TempConfigDir
        $yaml = @(
            'installed:'
            '- jira'
            'settings:'
            '  auto_execute_hooks: true'
            'hooks:'
            '  before_specify:'
            '  - extension: jira'
            '    command: speckit.jira.feature'
            '    enabled: true'
        ) -join "`n"
        Set-Content -Path (Join-Path $d 'pyyaml.yml') -Value ($yaml + "`n") -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'pyyaml.yml') | ConvertFrom-Json
        $json.installed[0] | Should -BeExactly 'jira'
        $json.settings.auto_execute_hooks | Should -BeTrue
        @($json.hooks.before_specify).Count | Should -Be 1
        @($json.hooks.before_specify)[0].command | Should -BeExactly 'speckit.jira.feature'
        @($json.hooks.before_specify)[0].enabled | Should -BeTrue
        Remove-Item -Recurse -Force $d
    }

    It 'produces the SAME parse for both sequence indentations' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'flat.yml') -Value "hooks:`n  after_plan:`n  - command: a`n  - command: b`n" -NoNewline
        Set-Content -Path (Join-Path $d 'deep.yml') -Value "hooks:`n  after_plan:`n    - command: a`n    - command: b`n" -NoNewline
        (ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'flat.yml')) |
            Should -BeExactly (ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'deep.yml'))
        Remove-Item -Recurse -Force $d
    }
}

Describe 'An empty local binding is tolerated (003 T013)' {
    # Releasing the last held event leaves the local binding with nothing in it,
    # so the writer emits an empty document. Reading that back must be a no-op,
    # not a refusal — otherwise clearing the last disabled hook would break every
    # subsequent run of the ceremony. The Bash port tolerates it; this is the
    # twin that keeps the two in agreement (Constitution VI).
    It 'loads a config whose local binding is empty' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).routing_default | Should -BeExactly 'PROJ'
        Remove-Item -Recurse -Force $d
    }

    It 'leaves a loadable local binding after releasing the last held event' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $d
        $null = Remove-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $d
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 0
        (Get-JiraHooksDisabled -ConfigDir $d) | Should -BeExactly '[]'
        Remove-Item -Recurse -Force $d
    }
}
