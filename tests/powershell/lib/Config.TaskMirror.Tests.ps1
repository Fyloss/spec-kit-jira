# T007/T011 [Phase 2, 022] — mirror of tests/bash/lib/test_config_task_mirror.bats.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Config.psm1') -Force

    function New-TempConfigDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }
}

Describe 'Import-JiraConfig — task_mirror' {
    It 'task_mirror must be a mapping' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`ntask_mirror: checklist`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'task_mirror must be a mapping'
        Remove-Item -Recurse -Force $d
    }

    It 'task_mirror names an undeclared project key, refused' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`ntask_mirror:`n  UNDECLARED: checklist`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'task_mirror\.UNDECLARED'
        ($r.Errors -join "`n") | Should -Match 'not declared in projects\[\]'
        Remove-Item -Recurse -Force $d
    }

    It 'task_mirror value outside subtask|checklist is refused, zero writes' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`ntask_mirror:`n  CONSUMER: checklists`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'task_mirror\.CONSUMER'
        ($r.Errors -join "`n") | Should -Match 'checklists'
        ($r.Errors -join "`n") | Should -Match 'subtask'
        ($r.Errors -join "`n") | Should -Match 'checklist'
        Remove-Item -Recurse -Force $d
    }

    It 'task_strategy stays refused as retired even with task_mirror declared (FR-006)' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`n    task_strategy: linked_story`nrouting_default: CONSUMER`ntask_mirror:`n  CONSUMER: checklist`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'task_strategy'
        Remove-Item -Recurse -Force $d
    }

    It 'a valid task_mirror mapping validates cleanly' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`n  - key: PLATFORM`n    style: company_managed`nrouting_default: CONSUMER`ntask_mirror:`n  CONSUMER: checklist`n  PLATFORM: subtask`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'Get-JiraTaskMirrorFor returns checklist when recorded' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`ntask_mirror:`n  CONSUMER: checklist`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        (Get-JiraTaskMirrorFor -ProjectKey 'CONSUMER' -ConfigJson $r.Json) | Should -Be 'checklist'
        Remove-Item -Recurse -Force $d
    }

    It 'Get-JiraTaskMirrorFor returns subtask when recorded' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`ntask_mirror:`n  CONSUMER: subtask`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        (Get-JiraTaskMirrorFor -ProjectKey 'CONSUMER' -ConfigJson $r.Json) | Should -Be 'subtask'
        Remove-Item -Recurse -Force $d
    }

    It 'Get-JiraTaskMirrorFor returns empty for a project with no entry, task_mirror key present' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`n  - key: PLATFORM`n    style: company_managed`nrouting_default: CONSUMER`ntask_mirror:`n  PLATFORM: subtask`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        (Get-JiraTaskMirrorFor -ProjectKey 'CONSUMER' -ConfigJson $r.Json) | Should -Be ''
        Remove-Item -Recurse -Force $d
    }

    It 'Get-JiraTaskMirrorFor returns empty when task_mirror key is entirely absent' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        (Get-JiraTaskMirrorFor -ProjectKey 'CONSUMER' -ConfigJson $r.Json) | Should -Be ''
        Remove-Item -Recurse -Force $d
    }
}
