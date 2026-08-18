# T036/T040 [US2] — Config-time refusal of an impossible mapping (FR-007).
# Mirror of tests/bash/commands/test_config_refusal.bats. A team-managed level
# above the discovered Epic tier is refused with exit 4; company-managed is
# unrestricted; strategies persist by logical name. Lives in commands/Config.psm1.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    $script:TeamBinding = '{"style":"team_managed","issue_types":[{"logical_name":"Epic","id":"10200","subtask":false,"hierarchy_level":1},{"logical_name":"Story","id":"10201","subtask":false,"hierarchy_level":0},{"logical_name":"Sub-task","id":"10202","subtask":true,"hierarchy_level":-1}]}'
    $script:CompanyBinding = '{"style":"company_managed","issue_types":[{"logical_name":"Initiative","id":"10100","subtask":false,"hierarchy_level":2},{"logical_name":"Deliverable","id":"10101","subtask":false,"hierarchy_level":1},{"logical_name":"Story","id":"10102","subtask":false,"hierarchy_level":0}]}'
}

Describe 'Config-time mapping refusal' {
    It 'refuses a team-managed level above Epic with exit 4' {
        $code = Test-JiraMappingValidity -Style 'team_managed' -HierarchyJson '["Initiative","Epic","Story"]' -BindingJson $TeamBinding
        $code | Should -Be 4
    }

    It 'accepts a valid team-managed Epic/Story hierarchy' {
        $code = Test-JiraMappingValidity -Style 'team_managed' -HierarchyJson '["Epic","Story"]' -BindingJson $TeamBinding
        $code | Should -Be 0
    }

    It 'does not restrict a company-managed multi-level hierarchy' {
        $code = Test-JiraMappingValidity -Style 'company_managed' -HierarchyJson '["Initiative","Deliverable","Story"]' -BindingJson $CompanyBinding
        $code | Should -Be 0
    }

    It 'persists key and style by logical name' {
        $r = New-JiraProjectMapping -Key 'COMP' -Style 'company_managed'
        $r.ExitCode | Should -Be 0
        $obj = $r.Json | ConvertFrom-Json
        $obj.key | Should -Be 'COMP'
        $obj.style | Should -Be 'company_managed'
    }
}

# =============================================================================
# T053 [030, US2] — the §6 ordering rule: a malformed FILE setting refuses
# even when the environment holds a valid one (contracts/connection-
# settings.md §6). Mirror of test_config_refusal.bats' T052 tests.
# =============================================================================

Describe 'T053 — a malformed file setting is never masked by a valid environment value' {
    AfterEach {
        $env:SPEC_KIT_JIRA_BASE_URL = $null
        $env:JIRA_EMAIL = $null
    }

    It 'T053 — a malformed base_url in config.yml refuses even with a valid SPEC_KIT_JIRA_BASE_URL exported' {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`nrouting_default: PROJ`nbase_url: `"https://team.atlassian.net/`"`n" -NoNewline
        $env:SPEC_KIT_JIRA_BASE_URL = 'https://valid.example.invalid'
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'base_url is invalid'
        Remove-Item -Recurse -Force $d
    }

    It 'T053 — a malformed email in personal.yml refuses even with a valid JIRA_EMAIL exported' {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`nrouting_default: PROJ`n" -NoNewline
        Set-Content -Path (Join-Path $d 'personal.yml') -Value "email: not-an-address`n" -NoNewline
        $env:JIRA_EMAIL = 'valid@example.com'
        $r = Import-JiraPersonalConfig -ConfigDir $d -MergedJson '{}'
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'email is invalid'
        Remove-Item -Recurse -Force $d
    }
}
