# T043a [US1] — §7.4's "task recorded, not mirrored yet" note is gone from
# Hierarchy.psm1 now that the task tier ships (012, FR-012). Mirror of
# tests/bash/sink/test_hierarchy_task_note.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $SinkDir = Join-Path $Root 'scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Hierarchy.psm1') -Force
}

Describe 'Get-JiraRoleTaskRecordedNote — retired' {
    It 'no longer exists — the §7.4 note is retired, not merely unused' {
        Get-Command -Name 'Get-JiraRoleTaskRecordedNote' -Module 'Hierarchy' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
