# T039 [US3] — Personal team selection loader (FR-011/FR-012/FR-018). Pester
# twin of tests/bash/lib/test_personal_config.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    $script:Teams = '{"teams":[{"id":"ijt","project":"IJT","folder_prefix":"ijt-","branch_pattern":"ijt-<ID>/<FEATURE_NAME>"},{"id":"wex","project":"WEX","folder_prefix":"wex-","branch_pattern":"wex-<ID>/<FEATURE_NAME>"}]}'
}

Describe 'Personal team selection loader' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue }

    It 'is inactive when the file is absent' {
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).active | Should -BeFalse
    }

    It 'loads a valid selection' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: ijt`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 0
        $obj = $r.Json | ConvertFrom-Json
        $obj.active | Should -BeTrue
        $obj.team | Should -Be 'ijt'
        $obj.override | Should -Be $null
    }

    It 'refuses an unknown team with a located error listing valid ids (exit 4)' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: zzz`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'personal\.yml'
        ($r.Errors -join "`n") | Should -Match 'unknown team'
        ($r.Errors -join "`n") | Should -Match 'ijt'
        ($r.Errors -join "`n") | Should -Match 'wex'
    }

    It 'refuses a selection when no catalogue exists (exit 4)' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: ijt`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson '{}'
        $r.ExitCode | Should -Be 4
    }

    It 'loads a valid override' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: ijt`noverride:`n  folder_prefix: `"special-`"`n  branch_pattern: `"special-<ID>/<FEATURE_NAME>`"`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).override.folder_prefix | Should -Be 'special-'
    }

    It 'refuses an override failing the catalogue-entry validation (exit 4)' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: ijt`noverride:`n  branch_pattern: `"Bad Pattern`"`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'override\.branch_pattern is invalid'
    }

    It 'refuses an unknown personal key (exit 4)' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: ijt`ntoken: something`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'unknown personal key: token'
    }

    It 'refuses a credential-shaped value without echoing it (FR-018)' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: someone@example.com`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Not -Match 'someone@example\.com'
        ($r.Errors -join "`n") | Should -Match 'email address'
    
}
    # =========================================================================
    # T017 [030] — the five `team` states (data-model.md §3) and the `email`
    # accept/refuse table (contracts/connection-settings.md §3)
    # =========================================================================

    It 'T017 — team present-and-empty still refuses (exit 4), not treated as absent' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: `"`"`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'team is invalid'
    }

    It 'T017 — email accepts a well-formed address' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "email: op@example.com`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).active | Should -BeFalse
    }

    It 'T017 — email refuses a malformed address' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "email: not-an-address`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'email is invalid'
    }

    It 'T017 — email refuses when present and empty' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "email: `"`"`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'email is invalid'
    }

    It 'T017 — email absent is accepted (the environment may supply it)' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: ijt`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 0
    }

    It 'T017 — a valid email alongside a valid team both survive validation' {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: ijt`nemail: op@example.com`n")
        $r = Import-JiraPersonalConfig -ConfigDir $Dir -MergedJson $Teams
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).active | Should -BeTrue
    }
}

