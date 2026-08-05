# T042/T043 [US1] — Wiring the task tier into Invoke-JiraReconcile: tasks.md
# is read only when a `task` role resolved (FR-001, FR-011); attributed
# tasks become sub-tasks of their story; the run is byte-identical when no
# `task` role is declared. Mirror of tests/bash/commands/test_reconcile_tasks.bats.
# Cross-port parity is proven in bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-task-tier'
    $LegacyFixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-reconcile-legacy'
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
}

Describe 'Invoke-JiraReconcile — the task tier' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $script:Tasks = Join-Path $script:Work 'specs/001-feature/tasks.md'
        # The spelling the bridge REPORTS, as opposed to the one it opens: the
        # task notes quote the path with '/', the way the Bash twin does and
        # the way the operator spelled it (Reconcile.psm1, T099). Join-Path
        # above answers with the platform separator, so on Windows the two
        # differ — assert against this one wherever a note text is compared.
        # A no-op on POSIX, where both are already '/'.
        $script:TasksRef = $script:Tasks -replace '\\', '/'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"TASKP":"t"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'a fresh run creates the parent, the story, and the attributed sub-task, and skips the unattributed one' {
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.created | Should -Be 2
        $r.counts.tasks.created | Should -Be 1
        $r.counts.tasks.unchanged | Should -Be 0
        $calls = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' })
        $calls.Count | Should -Be 3
        (Get-Content -Raw -LiteralPath $script:Tasks) | Should -Match 'task=.*ticket=TASKP-3'
        $taskLines = (Get-Content -Raw -LiteralPath $script:Tasks) -split "`n" | Where-Object { $_ -match 'speckit-jira task=' }
        ($taskLines -join "`n") | Should -Not -Match 'T001'
    }

    It 'the sub-task is created under the story, not the parent' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        (Get-JiraMockIssueField -Mock $script:M -Key 'TASKP-3' -Path 'fields.parent.key') | Should -Be 'TASKP-2'
    }

    It 'a re-run issues zero writes for the task tier (zero churn)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        Clear-Content -LiteralPath $script:M.CallLog
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks.created | Should -Be 0
        $r.counts.tasks.updated | Should -Be 0
        $r.counts.tasks.unchanged | Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' }).Count | Should -Be 0
    }

    It 'tasks.md is byte-preserved apart from the inserted marker lines' {
        $before = Get-Content -Raw -LiteralPath $script:Tasks
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $after = Get-Content -Raw -LiteralPath $script:Tasks
        $after | Should -Match ([regex]::Escape('- [ ] T001 Do the setup work'))
        $after | Should -Match ([regex]::Escape("- [ ] T002 [US1] Implement the first story's feature"))
        $after.Length | Should -BeGreaterThan $before.Length
    }

    It '--dry-run writes neither Jira nor tasks.md, and shows the planned sub-task' {
        $before = Get-Content -Raw -LiteralPath $script:Tasks
        $r = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $r.counts.tasks.created | Should -Be 1
        @($r.actions | Where-Object { $_.role -eq 'task' }).Count | Should -Be 1
        $after = Get-Content -Raw -LiteralPath $script:Tasks
        $after | Should -Be $before
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -Be 0
    }

    It 'no tasks.md is a silent no-op — no counts.tasks key at all' {
        Remove-Item -LiteralPath $script:Tasks
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        ($r.counts.PSObject.Properties.Name -contains 'tasks') | Should -Be $false
    }

    It 'no task role declared: byte-identical output even with tasks.md present (FR-011)' {
        $work2 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $LegacyFixture $work2
        New-Item -ItemType Directory -Force -Path (Join-Path $work2 'specs/001-feature') | Out-Null
        Copy-Item $script:Spec (Join-Path $work2 'specs/001-feature/spec.md')
        Copy-Item $script:Tasks (Join-Path $work2 'specs/001-feature/tasks.md')
        $env:JIRA_CONFIG_DIR = Join-Path $work2 '.specify/jira'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
        Stop-JiraMock -Mock $script:M
        $cfgPath2 = Write-JiraMockConfig -Json '{"projects":{"TEST":"t"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath2
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $r = Invoke-Captured @('reconcile', (Join-Path $work2 'specs/001-feature/spec.md'), '--json') | ConvertFrom-Json
        ($r.counts.PSObject.Properties.Name -contains 'tasks') | Should -Be $false
        (Get-Content -Raw -LiteralPath (Join-Path $work2 'specs/001-feature/tasks.md')) | Should -Not -Match 'speckit-jira task='
        Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
    }

    It 'T069 [US3] — a task removed from tasks.md reports its orphaned sub-task once, by key, and changes nothing in Jira (FR-021)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        # T002 (and its marker) is the only line attributing a task to the
        # story; removing it leaves TASKP-3 with no attributed task on the
        # doc side.
        $lines = (Get-Content -Raw -LiteralPath $script:Tasks) -split "`n" | Where-Object { $_ -notmatch '^- \[ \] T002 ' }
        ($lines -join "`n") | Set-Content -NoNewline -LiteralPath $script:Tasks
        Clear-Content -LiteralPath $script:M.CallLog
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $notes = @($r.notes | Where-Object { $_ -match 'TASKP-3' })
        $notes.Count | Should -Be 1
        $notes[0] | Should -Be "TASKP-3 is recorded in Jira as a sub-task of TASKP-2, but $script:TasksRef no longer attributes any task to it; nothing was changed in Jira."
        # No write of any kind touched the sub-task — status, fields, and
        # parent were all left exactly as Jira already recorded them.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'TASKP-3' }).Count | Should -Be 0
    }

    It 'T070 [US3] — a task re-attributed to a different story reports the divergence once, by key, and re-parents nothing in Jira (FR-022)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        # Story 2 draws the next id from the pool — the fixture's default
        # four are all consumed by the parent/story/task fresh run above.
        $savedIdSource = $env:SPEC_KIT_JIRA_ID_SOURCE
        $env:SPEC_KIT_JIRA_ID_SOURCE = "$savedIdSource 5555555555555555"
        try {
            @(
                (Get-Content -Raw -LiteralPath $script:Spec).TrimEnd("`n"),
                '',
                '### User Story 2 - Second story (Priority: P2)',
                '',
                'As a user, I want the second story.',
                '',
                '- **Given** another thing',
                '- **When** it happens',
                '- **Then** it works too'
            ) -join "`n" | Set-Content -NoNewline -LiteralPath $script:Spec
            # A second run creates and recognises Story 2 (TASKP-4) BEFORE the
            # re-attribution happens — the divergence can only ever name a
            # story Jira already recorded, never one still pending creation
            # this same run.
            $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        } finally {
            $env:SPEC_KIT_JIRA_ID_SOURCE = $savedIdSource
        }
        # T002's durable marker is untouched; only its own attribution tag
        # now points at User Story 2 instead of the story Jira actually
        # recorded it under. The tag, not the phase heading, is what
        # ConvertTo-JiraTasksParseDocument resolves attribution from when
        # both are present.
        ((Get-Content -Raw -LiteralPath $script:Tasks) -replace '\[US1\]', '[US2]') | Set-Content -NoNewline -LiteralPath $script:Tasks
        Clear-Content -LiteralPath $script:M.CallLog
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $reattributionNote = @($r.notes | Where-Object { $_ -match '^TASKP-3 is attributed to' })
        $reattributionNote.Count | Should -Be 1
        $reattributionNote[0] | Should -Be "TASKP-3 is attributed to TASKP-4 in $script:TasksRef, but is recorded in Jira under TASKP-2; nothing was re-parented."
        # The description resync (the rendered "Attribution:" line) is a
        # legitimate, unrelated write — what matters is that no action ever
        # carries a "parent" field for this sub-task.
        $taskp3Actions = @($r.actions | Where-Object { $_.url -match 'TASKP-3$' })
        $hasParentField = $false
        foreach ($a in $taskp3Actions) {
            if ($a.body -and $a.body.fields -and ($a.body.fields.PSObject.Properties.Name -contains 'parent')) { $hasParentField = $true }
        }
        $hasParentField | Should -Be $false
        (Get-JiraMockIssueField -Mock $script:M -Key 'TASKP-3' -Path 'fields.parent.key') | Should -Be 'TASKP-2'
    }
}
