# T037 [US3] — `teams:` catalogue validation (FR-010/FR-018). Pester twin of
# tests/bash/lib/test_teams_catalogue.bats: same rules, same error strings.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force

    function New-CfgDir {
        param([string]$TeamsBlock = '')
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $lines = @('projects:', '  - key: IJT', '    epic_strategy: per_repo', '    task_strategy: subtask', 'routing_default: IJT')
        if ($TeamsBlock) { $lines += $TeamsBlock -split "`n" }
        [System.IO.File]::WriteAllText((Join-Path $d 'config.yml'), (($lines -join "`n") + "`n"))
        return $d
    }
}

Describe 'Teams catalogue validation' {
    It 'loads a valid two-team catalogue' {
        $d = New-CfgDir "teams:`n  - id: ijt`n    project: IJT`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"ijt-<ID>/<FEATURE_NAME>`"`n  - id: wex`n    project: WEX`n    folder_prefix: `"wex-`"`n    branch_pattern: `"wex-<ID>/<FEATURE_NAME>`""
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        @(($r.Json | ConvertFrom-Json).teams).Count | Should -Be 2
        Remove-Item -Recurse -Force $d
    }

    It 'changes nothing when the section is absent' {
        $d = New-CfgDir
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        (($r.Json | ConvertFrom-Json).PSObject.Properties.Name -contains 'teams') | Should -BeFalse
        Remove-Item -Recurse -Force $d
    }

    It 'refuses an invalid team id (exit 4)' {
        $d = New-CfgDir "teams:`n  - id: IJT`n    project: IJT`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"ijt-<ID>/<FEATURE_NAME>`""
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'teams\[0\]\.id is invalid'
        Remove-Item -Recurse -Force $d
    }

    It 'refuses a duplicate team id (exit 4)' {
        $d = New-CfgDir "teams:`n  - id: ijt`n    project: IJT`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"ijt-<ID>/<FEATURE_NAME>`"`n  - id: ijt`n    project: WEX`n    folder_prefix: `"wex-`"`n    branch_pattern: `"wex-<ID>/<FEATURE_NAME>`""
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'teams\[1\]\.id duplicates an earlier team id'
        Remove-Item -Recurse -Force $d
    }

    It 'refuses an invalid and a duplicate folder_prefix (exit 4)' {
        $d = New-CfgDir "teams:`n  - id: ijt`n    project: IJT`n    folder_prefix: `"Ijt`"`n    branch_pattern: `"ijt-<ID>/<FEATURE_NAME>`""
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'teams\[0\]\.folder_prefix is invalid'
        Remove-Item -Recurse -Force $d

        $d = New-CfgDir "teams:`n  - id: ijt`n    project: IJT`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"ijt-<ID>/<FEATURE_NAME>`"`n  - id: wex`n    project: WEX`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"wex-<ID>/<FEATURE_NAME>`""
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'teams\[1\]\.folder_prefix duplicates an earlier folder_prefix'
        Remove-Item -Recurse -Force $d
    }

    It 'refuses an invalid team project key (exit 4)' {
        $d = New-CfgDir "teams:`n  - id: ijt`n    project: ijt`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"ijt-<ID>/<FEATURE_NAME>`""
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'teams\[0\]\.project is not a valid project key'
        Remove-Item -Recurse -Force $d
    }

    It 'requires <ID> and <FEATURE_NAME> exactly once each in branch_pattern' {
        foreach ($bad in @('ijt-<ID>/<ID>/<FEATURE_NAME>', 'ijt-<ID>/feature', 'ijt-<TICKET>/<ID>/<FEATURE_NAME>', 'IJT <ID>/<FEATURE_NAME>')) {
            $d = New-CfgDir "teams:`n  - id: ijt`n    project: IJT`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"$bad`""
            $r = Import-JiraConfig -ConfigDir $d
            $r.ExitCode | Should -Be 4
            ($r.Errors -join "`n") | Should -Match 'teams\[0\]\.branch_pattern is invalid'
            Remove-Item -Recurse -Force $d
        }
    }

    It 'refuses a credential-shaped value without echoing it (FR-018)' {
        $d = New-CfgDir "teams:`n  - id: ijt`n    project: IJT`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"ijt-<ID>/<FEATURE_NAME>`"`n    contact: someone@example.com"
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Not -Match 'someone@example\.com'
        ($r.Errors -join "`n") | Should -Match 'email address'
        Remove-Item -Recurse -Force $d
    }
}
