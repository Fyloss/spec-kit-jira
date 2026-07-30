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
    Remove-Item Env:\SPEC_KIT_JIRA_EPIC_STRATEGY -ErrorAction SilentlyContinue

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
        $first.counts.created | Should -Be 3

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

    It 'the full call log shows exactly 3 creation POSTs across two runs, not 6' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 3
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
        $first.counts.created | Should -Be 3

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
        $ticket = Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2"
        $ticket.fields.summary | Should -Be 'Export a date range (renamed)'
    }
}
