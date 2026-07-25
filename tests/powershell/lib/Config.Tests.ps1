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
}
