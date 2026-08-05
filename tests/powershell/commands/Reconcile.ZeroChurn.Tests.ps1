# T033-T036 [Phase 4, US2] / T072 — an unchanged re-run over a mirrored
# corpus issues NO write of any kind, PowerShell side. Mirror of
# tests/bash/commands/test_reconcile_zero_churn.bats. Cross-port parity is
# proven in bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Identity.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Client.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    # This suite relies on config.yml-based routing (folder prefix "001-" ->
    # COMP), so any override left behind by an earlier-run suite (e.g.
    # Reconcile.Tests.ps1's SPEC_KIT_JIRA_PROJECT_KEY='TEST', which Pester
    # runs in the same process and never cleans up) must be cleared here.
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_SPEC_SLUG -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_REPO -ErrorAction SilentlyContinue

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile — zero churn on an unchanged re-run' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'an unchanged re-run issues ZERO POST and ZERO PUT, skipped equals the story count' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json') # back-fills the provenance label once
        Clear-Content -LiteralPath $script:M.CallLog

        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.created | Should -Be 0
        $r.counts.updated | Should -Be 0
        $r.counts.skipped | Should -Be 3
        $r.counts.recognised | Should -Be 3
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' }).Count | Should -Be 0
    }

    It "a change to one story out of several produces exactly one PUT, naming that story's ticket" {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json') # back-fills the provenance label once

        $content = Get-Content -Raw -LiteralPath $script:Spec
        $content = $content -replace [regex]::Escape('As a customer, I want to export every invoice in a date range.'), 'As a customer, I want to export every invoice in a chosen date range.'
        Set-Content -NoNewline -Path $script:Spec -Value $content

        Clear-Content -LiteralPath $script:M.CallLog
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.updated | Should -Be 1
        $r.counts.skipped | Should -Be 2
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'PUT /rest/api/3/issue/COMP-3' }).Count | Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' }).Count | Should -Be 1
    }

    It 'spec.md is byte-identical after an unchanged re-run' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json') # back-fills the provenance label once
        $before = Get-Content -Raw -LiteralPath $script:Spec
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        (Get-Content -Raw -LiteralPath $script:Spec) | Should -Be $before
    }

    It '--dry-run writes neither Jira nor spec.md' {
        $before = Get-Content -Raw -LiteralPath $script:Spec
        $r = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $r.counts.created | Should -Be 4
        (Get-Content -Raw -LiteralPath $script:Spec) | Should -Be $before
        # The one read this run makes: the duplicate probe (017, US4)
        # predicting the parent's creation. Read-only — zero writes either way.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'search/jql' }).Count | Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' }).Count | Should -Be 0
    }

    It "a human-origin ticket's churn is computed on the managed section alone: its prose above the panel is never rewritten (T072)" {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        $storyId = [regex]::Match((Get-Content -Raw -LiteralPath $script:Spec), 'story=([0-9a-f]{16}) ticket=COMP-2').Groups[1].Value
        $specRef = '{"repo":"local/repo","spec_slug":"001-billing-invoices","folder":"x"}'

        # Declare COMP-2 human-origin, with no prose yet: this run wraps it in
        # the managed panel for the first time — a one-time, legitimate churn.
        $null = Set-JiraIdentity -IssueKey 'COMP-2' -SpecRefJson $specRef -Origin 'human' -Story $storyId
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        # A human adds a note above the panel, exactly as a PO would in Jira.
        $current = Invoke-JiraRequest -Method GET -Url "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2?fields=description"
        $currentDesc = ($current.Body | ConvertFrom-Json -Depth 100).fields.description
        $humanDesc = [ordered]@{
            type    = 'doc'; version = 1
            content = @([ordered]@{ type = 'paragraph'; content = @([ordered]@{ type = 'text'; text = 'Human note above the panel.' }) }) + @($currentDesc.content)
        }
        $body = ConvertTo-Json ([ordered]@{ fields = [ordered]@{ description = $humanDesc } }) -Depth 100 -Compress
        $null = Invoke-JiraRequest -Method PUT -Url "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" -Body $body

        Clear-Content -LiteralPath $script:M.CallLog
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.exit_code | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'PUT /rest/api/3/issue/COMP-2' }).Count | Should -Be 0

        $after = Invoke-JiraRequest -Method GET -Url "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2?fields=description"
        $afterDesc = ($after.Body | ConvertFrom-Json -Depth 100).fields.description
        $afterDesc.content[0].content[0].text | Should -Be 'Human note above the panel.'
    }

    It 'T080 [Phase 9] — a second reconcile over the declared-hierarchy fixture issues ZERO writes of every kind' {
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-declared-hierarchy') $work
        $spec = Join-Path $work 'specs/001-consumer-onboarding/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-consumer-onboarding'
        $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222'
        $m = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/consumer-hierarchy.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $m.BaseUrl
        try {
            $null = Invoke-JiraReconcile -Arguments @('reconcile', $spec, '--json')
            $null = Invoke-JiraReconcile -Arguments @('reconcile', $spec, '--json') # back-fills the provenance label once
            Clear-Content -LiteralPath $m.CallLog

            $sw = [System.IO.StringWriter]::new(); $orig = [Console]::Out; [Console]::SetOut($sw)
            try { $null = Invoke-JiraReconcile -Arguments @('reconcile', $spec, '--json') } finally { [Console]::SetOut($orig) }
            $r = $sw.ToString() | ConvertFrom-Json
            $r.counts.created | Should -Be 0
            $r.counts.updated | Should -Be 0
            $r.counts.skipped | Should -Be 2
            @(Get-JiraMockCallLog -Mock $m | Where-Object { $_ -match '^(POST|PUT) ' }).Count | Should -Be 0
        }
        finally {
            Stop-JiraMock -Mock $m
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }
    }
}
