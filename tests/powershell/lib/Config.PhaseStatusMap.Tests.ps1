# T075 [Phase 6, US4] — the `phase_status_map` schema (023, contracts/
# role-lifecycle-config.md §2/§3). Pester mirror of
# tests/bash/lib/test_config_phase_status_map.bats.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Config.psm1'
    Import-Module $ModulePath -Force

    function New-TempConfigDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }
}

Describe 'phase_status_map schema' {
    It 'is valid when empty, under either shape' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map: {}`nrouting_default: PROJ`n" -NoNewline
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'is valid when role-blind (all lifecycle events)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      after_specify: `"To Do`"`n      after_plan: `"In Progress`"`nrouting_default: PROJ`n" -NoNewline
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'is valid when per-role (all hierarchy roles)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      specification:`n        after_plan: `"Building`"`n      story:`n        after_plan: `"In Progress`"`nrouting_default: PROJ`n" -NoNewline
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'M1: a non-mapping phase_status_map refuses, naming both accepted shapes' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map: `"To Do`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape("projects[0].phase_status_map must be a mapping of lifecycle-event name to status name, or of hierarchy role to that role's own mapping"))
        Remove-Item -Recurse -Force $d
    }

    It 'M2: a legacy-shape value that is empty refuses, naming the key' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      after_specify: `"`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('projects[0].phase_status_map.after_specify must be a non-empty status name'))
        Remove-Item -Recurse -Force $d
    }

    It 'M3: a per-role value that is not itself a mapping refuses, naming the role' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      story: `"In Progress`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('projects[0].phase_status_map.story must be a mapping of lifecycle-event name to status name'))
        Remove-Item -Recurse -Force $d
    }

    It 'M4: an unknown lifecycle event inside a per-role mapping refuses, naming role and event' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      story:`n        after_typo: `"In Progress`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('projects[0].phase_status_map.story declares unknown lifecycle event `after_typo`'))
        Remove-Item -Recurse -Force $d
    }

    It 'M5: an empty status value inside a per-role mapping refuses, naming role and event' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      story:`n        after_plan: `"`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('projects[0].phase_status_map.story.after_plan must be a non-empty status name'))
        Remove-Item -Recurse -Force $d
    }

    It 'M6: mixing a lifecycle-event key and a hierarchy-role key refuses' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      after_plan: `"In Progress`"`n      story:`n        after_plan: `"In Progress`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('projects[0].phase_status_map mixes lifecycle events and hierarchy roles; declare either one mapping for the story role, or one mapping per role (specification, story, task)'))
        Remove-Item -Recurse -Force $d
    }

    It 'M7: a key that is neither a lifecycle event nor a hierarchy role refuses, naming both closed sets' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      epic:`n        after_plan: `"In Progress`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('projects[0].phase_status_map declares unknown key `epic`; the lifecycle events are after_specify, after_clarify, after_plan, after_tasks, after_implement, after_analyze and the roles are specification, story, task'))
        Remove-Item -Recurse -Force $d
    }

    It 'before_specify is never an accepted phase_status_map key (M7 wording)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      before_specify: `"Backlog`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape('projects[0].phase_status_map declares unknown key `before_specify`'))
        Remove-Item -Recurse -Force $d
    }
}
