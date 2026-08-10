# T007 [Phase 1] / T021-T024 — the duplicate-creation regression, PowerShell
# side. Mirror of tests/bash/commands/test_reconcile_idempotent.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing-invoices'
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    # Relies on config.yml-based routing (folder prefix "001-" -> COMP); clear
    # any override an earlier suite in the same Pester process left behind.
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

Describe 'Invoke-JiraReconcile — the duplicate-creation regression' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'a second run creates NOTHING: one story, one ticket, not two (the reported defect)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $first = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $first.counts.created | Should -Be 4

        Clear-Content -LiteralPath $script:M.CallLog
        $second = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $second.counts.created | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 0
    }

    It 'the specification carries one marker per story after the first run, matching the ticket' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $content = Get-Content -Raw -LiteralPath $script:Spec
        @([regex]::Matches($content, 'speckit-jira story=')).Count | Should -Be 3
        @([regex]::Matches($content, 'speckit-jira story=[0-9a-f]{16} ticket=COMP-[1-9][0-9]* -->')).Count | Should -Be 3
    }

    It 'the full call log shows exactly 4 creation POSTs across two runs, not 8' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 4
    }
}

Describe 'Invoke-JiraReconcile — reordering and retitling never swap tickets (T024)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'reordering and retitling stories between runs never swaps tickets' {
        $first = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $first.counts.created | Should -Be 4

        # Reorder (move story 3 above story 1) and retitle story 2, keeping
        # each marker line with its story.
        $blocks = (Get-Content -Raw -LiteralPath $script:Spec) -split '(?=### User Story)'
        $header = $blocks[0]
        $reordered = $header + $blocks[3] + $blocks[2] + $blocks[1]
        $reordered = $reordered -replace 'Export a date range', 'Export a date range (renamed)'
        Set-Content -NoNewline -Path $script:Spec -Value $reordered

        Clear-Content -LiteralPath $script:M.CallLog
        $second = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $second.counts.created | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 0

        # Each ticket still holds the content of the story whose marker
        # names it — not the story that now sits in its old POSITION.
        $ticket = Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-3"
        $ticket.fields.summary | Should -Be 'Export a date range (renamed)'
    }
}

# --- 019, T044: contract §5.5, FR-018, SC-005 on all three tiers -----------
Describe '019, T044 — origin bridge, no-boundary description: settles to zero writes' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-pre-release-migration') $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        Remove-Item Env:\SPEC_KIT_JIRA_ID_SOURCE -ErrorAction SilentlyContinue
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/preserve-pre-release.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'the first run replaces the region, the second reports 0/0 and issues no PUT' {
        $first = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $pre1 = $first.actions | Where-Object { $_.url -like '*PRE-1' }
        $pre1.body.fields.description.content[0].content[0].text | Should -Be 'Synced from spec-kit — do not edit below this line'

        Clear-Content -LiteralPath $script:M.CallLog
        $second = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $second.counts.created | Should -Be 0
        $second.counts.updated | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -like 'PUT *' }).Count | Should -Be 0
    }
}

# --- 022, T122: checklist-mode renumber produces zero writes (FR-017) ------
Describe '022, T122 — checklist-mode renumber issues zero writes' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-task-tier') $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $script:Tasks = Join-Path $script:Work 'specs/001-feature/tasks.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
        Add-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -Value "task_mirror:`n  TASKP: checklist`n"
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"TASKP":"t"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'renumbering T0xx with text, order and checked state unchanged issues zero writes on the second reconcile' {
        $first = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $first.counts.checklists.created | Should -Be 1

        $content = Get-Content -Raw -LiteralPath $script:Tasks
        $content = $content -replace '(?m)^- \[ \] T001 ', '- [ ] T101 '
        $content = $content -replace '(?m)^- \[ \] T002 ', '- [ ] T102 '
        Set-Content -NoNewline -LiteralPath $script:Tasks -Value $content

        Clear-Content -LiteralPath $script:M.CallLog
        $second = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $second.counts.checklists.unchanged | Should -Be 1
        $second.counts.checklists.created | Should -Be 0
        $second.counts.checklists.updated | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' -and $_ -notmatch 'issue/bulkfetch' }).Count | Should -Be 0
    }
}
