# T014 [Phase 2, 011] — mirror of tests/bash/lib/test_config_field_defaults.bats.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Config.psm1') -Force

    function New-TempConfigDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    $script:TeamWithFieldDefaults = @'
projects:
  - key: CONSUMER
    style: company_managed
routing_default: CONSUMER
field_defaults:
  CONSUMER:
    ask: true
    Epic:
      Business Owner: "Platform Team"
      Program Increment: "PI-2026-Q3"
'@
}

Describe 'Import-JiraConfig — field_defaults' {
    It 'the field_defaults key parses without error' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:TeamWithFieldDefaults -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        (($r.Json | ConvertFrom-Json).field_defaults.CONSUMER.Epic.'Business Owner') | Should -Be 'Platform Team'
        Remove-Item -Recurse -Force $d
    }

    It 'Get-JiraFieldDefaultsFor reads one project''s map, ask included' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:TeamWithFieldDefaults -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $fd = Get-JiraFieldDefaultsFor -ProjectKey 'CONSUMER' -ConfigJson $r.Json | ConvertFrom-Json -Depth 100
        $fd.ask | Should -Be $true
        $fd.Epic.'Business Owner' | Should -Be 'Platform Team'
        Remove-Item -Recurse -Force $d
    }

    It 'Get-JiraFieldDefaultsFor defaults ask to true when absent' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`nfield_defaults:`n  CONSUMER:`n    Epic:`n      Business Owner: `"Platform Team`"`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $fd = Get-JiraFieldDefaultsFor -ProjectKey 'CONSUMER' -ConfigJson $r.Json | ConvertFrom-Json -Depth 100
        $fd.ask | Should -Be $true
        Remove-Item -Recurse -Force $d
    }

    It 'Get-JiraFieldDefaultsFor returns an empty map for a project with no field_defaults entry' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $fd = Get-JiraFieldDefaultsFor -ProjectKey 'CONSUMER' -ConfigJson $r.Json | ConvertFrom-Json -Depth 100
        $fd.ask | Should -Be $true
        @($fd.PSObject.Properties).Count | Should -Be 1
        Remove-Item -Recurse -Force $d
    }

    It 'an undeclared project key under field_defaults is refused, zero writes (exit 4)' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`nfield_defaults:`n  UNDECLARED:`n    Epic:`n      Team: `"Payments`"`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'field_defaults\.UNDECLARED'
        ($r.Errors -join "`n") | Should -Match 'not declared'
        Remove-Item -Recurse -Force $d
    }

    It 'an empty default value is refused, zero writes (exit 4, FR-008)' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`nfield_defaults:`n  CONSUMER:`n    Epic:`n      Team: `"`"`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('field_defaults.CONSUMER.Epic.Team'))
        Remove-Item -Recurse -Force $d
    }

    It 'a non-scalar default value is refused, zero writes (exit 4)' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`nfield_defaults:`n  CONSUMER:`n    Epic:`n      Team:`n        - a`n        - b`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('field_defaults.CONSUMER.Epic.Team'))
        Remove-Item -Recurse -Force $d
    }

    It 'T042 — Get-JiraFieldDefaultsYaml renders the whole map, keys sorted at every level' {
        $map = '{"FD":{"ask":true,"Epic":{"Program Increment":"PI-2026-Q3","Business Owner":"Platform Team"}}}'
        $out = Get-JiraFieldDefaultsYaml -MapJson $map
        $expected = @'
"field_defaults":
  "FD":
    "Epic":
      "Business Owner": "Platform Team"
      "Program Increment": "PI-2026-Q3"
    "ask": true
'@
        $out | Should -Be $expected.TrimEnd("`r", "`n")
    }

    It 'T042 — Get-JiraFieldDefaultsYaml renders an empty map' {
        Get-JiraFieldDefaultsYaml -MapJson '{}' | Should -Be '"field_defaults": {}'
    }

    It 'T042 — Get-JiraFieldDefaultsYaml defaults to an empty map with no argument' {
        Get-JiraFieldDefaultsYaml | Should -Be '"field_defaults": {}'
    }

    It 'a credential-shaped field_defaults value is STILL caught by the existing scan (research R7)' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`nfield_defaults:`n  CONSUMER:`n    Epic:`n      Owner: `"person@example.com`"`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'credential'
        ($r.Errors -join "`n") | Should -Not -Match 'person@example.com'
        Remove-Item -Recurse -Force $d
    }
}
