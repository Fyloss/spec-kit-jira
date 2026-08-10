# T088/T089/T090/T091/T092/T093/T093a/T093b/T093c [Phase 6, US4, 022] — mirror
# of tests/bash/commands/test_reconcile_mode_switch.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-task-tier'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }

    function Add-TaskMirrorChecklist {
        Add-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -Value "task_mirror:`n  TASKP: checklist"
    }

    function Remove-TaskMirrorChecklist {
        $path = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        $lines = Get-Content -LiteralPath $path
        $newLines = [System.Collections.Generic.List[string]]::new()
        $skip = 0
        foreach ($l in $lines) {
            if ($l -match '^task_mirror:') { $skip = 2; continue }
            if ($skip -gt 0) { $skip--; continue }
            $newLines.Add($l)
        }
        Set-Content -LiteralPath $path -Value $newLines
    }
}

Describe 'Invoke-JiraReconcile — mode-switch detection and reporting' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"TASKP":"t"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T088 — switching to checklist mode writes to no sub-task: zero write actions of any kind (FR-033)' {
        $null = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        $callsBefore = @(Get-JiraMockCallLog -Mock $script:M).Count

        Add-TaskMirrorChecklist
        $out = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        $r = $out | ConvertFrom-Json -Depth 100
        $r.exit_code | Should -Be 0
        $calls = @(Get-JiraMockCallLog -Mock $script:M)
        $tail = $calls[$callsBefore..($calls.Count - 1)]
        $subtaskCalls = @($tail | Where-Object { $_ -match '^(POST|PUT) /rest/api/3/issue/TASKP-3' })
        $subtaskCalls.Count | Should -Be 0
    }

    It 'T090 — the outbound switch report names the story, the abandoned count, and an exact issue-in query (FR-034)' {
        $null = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        Add-TaskMirrorChecklist
        $out = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        $notes = ($out | ConvertFrom-Json -Depth 100).notes -join "`n"
        $notes | Should -Match ([regex]::Escape('switched to checklist mode'))
        $notes | Should -Match ([regex]::Escape('First story'))
        $notes | Should -Match ([regex]::Escape('1 sub-task'))
        $notes | Should -Match ([regex]::Escape('issue in (TASKP-3)'))
    }

    It 'T092/T093 — switching back removes the Tasks section and re-binds rather than duplicates (FR-035)' {
        $null = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        Add-TaskMirrorChecklist
        $null = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        $descBefore = Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/TASKP-2"
        $hasTasksBefore = @($descBefore.fields.description.content | ForEach-Object { $_.content } | ForEach-Object { $_.text }) -contains 'Tasks'
        $hasTasksBefore | Should -BeTrue

        Remove-TaskMirrorChecklist
        $out = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        $r = $out | ConvertFrom-Json -Depth 100
        $r.exit_code | Should -Be 0
        $descAfter = Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/TASKP-2"
        $hasTasksAfter = @($descAfter.fields.description.content | ForEach-Object { $_.content } | ForEach-Object { $_.text }) -contains 'Tasks'
        $hasTasksAfter | Should -BeFalse
        $postIssueCalls = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' })
        $postIssueCalls.Count | Should -Be 3
    }

    It 'T093a/T093b — the checklist-to-subtask switch is also reported once, naming the re-bound count, no query (FR-034)' {
        $null = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        Add-TaskMirrorChecklist
        $null = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        Remove-TaskMirrorChecklist
        $out = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        $notes = ($out | ConvertFrom-Json -Depth 100).notes -join "`n"
        $notes | Should -Match ([regex]::Escape('switched back to subtask mode'))
        $notes | Should -Match ([regex]::Escape('1 sub-task'))
        $notes | Should -Match ([regex]::Escape('re-bound'))
        $notes | Should -Not -Match ([regex]::Escape('issue in ('))
    }

    It 'T093c — the outbound switch report never claims full migration of an unaffected story' {
        $null = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        Add-TaskMirrorChecklist
        $out = Invoke-Captured -ArgList @('reconcile', $Spec, '--json')
        $notes = ($out | ConvertFrom-Json -Depth 100).notes -join "`n"
        $notes | Should -Not -Match 'fully migrated'
    }
}
