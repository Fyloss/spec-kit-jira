# T070/T071/T072/T073/T074/T076/T077 [Phase 5, US3, 022] — mirror of
# tests/bash/commands/test_config_task_mirror.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Config.psm1') -Force
    # Config.psm1 -Force-imports lib/Output.psm1 internally, which rebinds
    # ConvertTo-JiraJsonValue into Config.psm1's own scope — reimport here so
    # this test file keeps direct access to it too (see memory:
    # powershell-import-force-clobbers-caller-scope).
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force
    $script:Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-config'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
}

Describe 'Set-JiraTaskMirrorBlock — the managed-region splice (T070)' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Path = Join-Path $script:Dir 'config.yml'
    }
    AfterEach { Remove-Item -Recurse -Force $script:Dir }

    It 'a non-empty map creates the region in an absent file' {
        $r = Set-JiraTaskMirrorBlock -Path $script:Path -MapJson '{"COMP":"checklist"}' -DryRun $false
        $r.ExitCode | Should -Be 0
        $r.Status | Should -Be 'created'
        $content = [System.IO.File]::ReadAllText($script:Path)
        $content | Should -Match 'spec-kit-jira:task_mirror:begin'
        $content | Should -Match ([regex]::Escape('"COMP": "checklist"'))
    }

    It 'an empty map with no pre-existing region is left completely untouched (inert, FR-002/FR-011)' {
        [System.IO.File]::WriteAllText($script:Path, "projects:`n  - key: COMP`nrouting_default: COMP`n")
        $before = [System.IO.File]::ReadAllText($script:Path)
        $r = Set-JiraTaskMirrorBlock -Path $script:Path -MapJson '{}' -DryRun $false
        $r.Status | Should -Be 'inert'
        ([System.IO.File]::ReadAllText($script:Path)) | Should -Be $before
    }

    It 'a second run with the same map reports unchanged and leaves the file byte-identical (FR-009)' {
        Set-JiraTaskMirrorBlock -Path $script:Path -MapJson '{"COMP":"checklist"}' -DryRun $false | Out-Null
        $before = [System.IO.File]::ReadAllText($script:Path)
        $r = Set-JiraTaskMirrorBlock -Path $script:Path -MapJson '{"COMP":"checklist"}' -DryRun $false
        $r.Status | Should -Be 'unchanged'
        ([System.IO.File]::ReadAllText($script:Path)) | Should -Be $before
    }

    It 'a changed map rewrites only the region, preserving bytes outside it' {
        [System.IO.File]::WriteAllText($script:Path, "# a comment the operator wrote`nprojects:`n  - key: COMP`nrouting_default: COMP`n")
        Set-JiraTaskMirrorBlock -Path $script:Path -MapJson '{"COMP":"subtask"}' -DryRun $false | Out-Null
        $r = Set-JiraTaskMirrorBlock -Path $script:Path -MapJson '{"COMP":"checklist"}' -DryRun $false
        $r.Status | Should -Be 'written'
        $content = [System.IO.File]::ReadAllText($script:Path)
        $content | Should -Match ([regex]::Escape('# a comment the operator wrote'))
        $content | Should -Match ([regex]::Escape('"checklist"'))
        $content | Should -Not -Match ([regex]::Escape('"subtask"'))
    }

    It 'malformed markers refuse with exit 4 and zero writes' {
        [System.IO.File]::WriteAllText($script:Path, "# --- spec-kit-jira:task_mirror:begin ---`nstray`n")
        $before = [System.IO.File]::ReadAllText($script:Path)
        $r = Set-JiraTaskMirrorBlock -Path $script:Path -MapJson '{"COMP":"checklist"}' -DryRun $false
        $r.Status | Should -Be 'refused'
        ([System.IO.File]::ReadAllText($script:Path)) | Should -Be $before
    }
}

Describe 'Invoke-JiraConfig — the task-mirror ceremony end to end (T072/T074/T076)' {
    BeforeAll {
        function Invoke-CapturedConfig {
            param([string[]] $ArgList)
            $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
            $origOut = [Console]::Out; $origErr = [Console]::Error
            [Console]::SetOut($sw); [Console]::SetError($se)
            try { $code = Invoke-JiraConfig -Arguments $ArgList }
            finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
            return [pscustomobject]@{ Code = $code; Out = $sw.ToString(); Err = $se.ToString() }
        }
    }
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
    }
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'T072 — the closed question is reported when nothing is recorded (FR-008), and the effect line says so (FR-011/FR-013)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r = Invoke-CapturedConfig -ArgList @('config', '--child-type', 'COMP=Story', '--json')
        $r.Code | Should -Be 0
        $r.Err | Should -Match ([regex]::Escape("config: project COMP: how should tasks be mirrored — choose one of: subtask, checklist (answer with --task-mirror 'COMP=checklist')."))
        $r.Err | Should -Match ([regex]::Escape("Task mirror: COMP — not recorded; today's behaviour applies"))
        ($r.Out.Trim() | ConvertFrom-Json).effects.task_mirror.status | Should -Be 'inert'
    }

    It 'T072 — answering the question records it, and a re-run neither re-asks nor rewrites the file (FR-009)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r1 = Invoke-CapturedConfig -ArgList @('config', '--child-type', 'COMP=Story', '--task-mirror', 'COMP=checklist', '--json')
        $r1.Code | Should -Be 0
        $r1.Err | Should -Match ([regex]::Escape('Task mirror: COMP — checklist (recorded)'))
        $after1 = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')

        $r2 = Invoke-CapturedConfig -ArgList @('config', '--child-type', 'COMP=Story', '--json')
        $r2.Code | Should -Be 0
        $r2.Err | Should -Not -Match 'how should tasks be mirrored'
        $r2.Err | Should -Match ([regex]::Escape('Task mirror: COMP — checklist (unchanged)'))
        (Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')) | Should -Be $after1
    }

    It 'T074 — a hand-written entry for a project this run did not touch is re-emitted unchanged (FR-010)' {
        $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        $lines = Get-Content -LiteralPath $cfgPath
        $newLines = [System.Collections.Generic.List[string]]::new()
        $done = $false
        foreach ($line in $lines) {
            $newLines.Add($line)
            if (-not $done -and $line -match '^projects:') { $newLines.Add('  - key: TEAM'); $done = $true }
        }
        Set-Content -LiteralPath $cfgPath -Value $newLines
        Add-Content -LiteralPath $cfgPath -Value "task_mirror:`n  TEAM: checklist"

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        # Only COMP is named this run — TEAM is a declared project the
        # ceremony did not process, so its hand-recorded entry must survive.
        $r = Invoke-CapturedConfig -ArgList @('config', 'COMP', '--child-type', 'COMP=Story', '--task-mirror', 'COMP=subtask', '--json')
        $r.Code | Should -Be 0
        $content = Get-Content -Raw -LiteralPath $cfgPath
        $content | Should -Match ([regex]::Escape('"TEAM": "checklist"'))
        $content | Should -Match ([regex]::Escape('"COMP": "subtask"'))
    }

    It "T076 — 'subtask' recorded with no resolvable sub-task type is reported at config time with its remedy" {
        Add-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -Value "task_mirror:`n  COMP: subtask"
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"issueTypeStyle":{"COMP":"notask"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r = Invoke-CapturedConfig -ArgList @('config', '--child-type', 'COMP=Story', '--json')
        $r.Code | Should -Be 0
        $r.Err | Should -Match ([regex]::Escape("config: project COMP: task_mirror is 'subtask' but no sub-task issue type is resolved for this project — declare hierarchy.task, or switch with --task-mirror 'COMP=checklist'"))
        $r.Err | Should -Match ([regex]::Escape('Task mirror: COMP — subtask (unchanged)'))
    }
}
