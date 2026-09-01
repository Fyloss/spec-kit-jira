# T049/T054/T055/T056 [Phase 3, 036] — Pester twin of
# tests/bash/commands/test_reconcile_artifacts.bats.
#
# The publication as a whole reconcile performs it
# (contracts/artifact-publication.md C1, C3.7, C3.9; FR-001, FR-003, FR-006,
# FR-019, FR-023; SC-001, SC-005).
#
# Every assertion reads the mock's call log — what the run actually sent —
# rather than the summary, which is what it says it sent. Those two disagreeing
# is the defect class this file exists for. The call log carries the multipart
# part list since T053, so "one request, parts in the set's sort order" is a
# single string comparison rather than an inference from a count.

BeforeAll {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    foreach ($v in 'SPEC_KIT_JIRA_PLAN_CONTEXT', 'SPEC_KIT_JIRA_LIFECYCLE', 'SPEC_KIT_JIRA_HOOK_CONTEXT') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }

    function Invoke-CapturedWithCode {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out; $origErr = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($sw)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }

    # The LAST JSON object on the captured stream. The reconcile prints exactly
    # one under --json, but a warning routed to the same writer would otherwise
    # make the parse fail for a reason unrelated to what is being asserted.
    function Get-SummaryJson {
        param([string] $Text)
        $line = @($Text -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
        return ($line[0] | ConvertFrom-Json)
    }

    # `, @(...)`, not `@(...)`: `return` unrolls a one-element array to the
    # scalar it holds, and indexing a scalar string yields its first CHARACTER.
    # Every part-list assertion below then compares 'P' against the expected
    # list and fails for a reason that has nothing to do with the port.
    function Get-AttachmentPost {
        param($M)
        return , @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ -match '^POST .*/attachments( |$)' })
    }

    function Measure-Call {
        param($M, [string] $Pattern)
        return @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ -match $Pattern }).Count
    }

    # The feature directory's own files, in the artifact set's byte-wise path
    # order — derived from the tree, so a fixture that grows makes the
    # assertions stricter rather than stale.
    function Get-ExpectedPath {
        param([string] $Dir)
        Push-Location $Dir
        try { $out = & git ls-files --cached --others --exclude-standard }
        finally { Pop-Location }
        return @($out | Sort-Object -CaseSensitive)
    }

    $script:RoutedConfig = @(
        'projects:'
        '  - key: COMP'
        '    style: company_managed'
        '    priority_map:'
        '      P1: Highest'
        '      P2: Medium'
        '      P3: Low'
        'routing:'
        '  - match:'
        '      folder_prefix: "001-"'
        '    project: COMP'
        'routing_default: COMP'
    ) -join "`n"

    $script:RefusedConfig = @(
        'projects:'
        '  - key: COMP'
        '    style: company_managed'
        'routing: []'
    ) -join "`n"
}

Describe 'Invoke-JiraReconcile — publishing the feature artifacts (036 Phase 3)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:FeatureDir = Join-Path $script:Work 'specs/001-billing-invoices'
        $script:Spec = Join-Path $script:FeatureDir 'spec.md'
        $script:ConfigYml = Join-Path $script:Work '.specify/jira/config.yml'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing-invoices'

        # The artifact set is `git ls-files` over the feature directory
        # (research R5), so the fixture has to be a repository.
        & git -C $script:Work init --quiet
        & git -C $script:Work config user.email 'fixture@example.invalid'
        & git -C $script:Work config user.name 'fixture'

        [System.IO.File]::WriteAllText($script:ConfigYml, $script:RoutedConfig + "`n")
        $script:M = $null
    }

    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
    }

    It 'T048 SC-001 a first run publishes EVERY artifact of the directory' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $summary = Get-SummaryJson -Text $r.Out

        $expected = Get-ExpectedPath -Dir $script:FeatureDir
        $actual = @($summary.artifacts | ForEach-Object { $_.path } | Sort-Object -CaseSensitive)
        ($actual -join ',') | Should -Be ($expected -join ',')
        @($summary.artifacts | Where-Object { $_.action -ne 'published' }).Count | Should -Be 0
    }

    It 'T039 FR-023 exactly ONE upload request per run, parts in the set sort order' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json') | Out-Null

        $posts = Get-AttachmentPost -M $script:M
        $posts.Count | Should -Be 1

        $expected = (Get-ExpectedPath -Dir $script:FeatureDir | ForEach-Object { $_ -replace '/', '__' }) -join ','
        ($posts[0] -replace '^.* parts=', '') | Should -Be $expected
    }

    It 'T034 C1.1 GET /attachment/meta is called exactly once per run' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json') | Out-Null
        (Measure-Call -M $script:M -Pattern '^GET /rest/api/3/attachment/meta$') | Should -Be 1
    }

    It 'T034 C1.1 the limit is not discovered at all when there is nothing to publish' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        [System.IO.File]::WriteAllText($script:ConfigYml, $script:RefusedConfig + "`n")

        Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json') | Out-Null
        (Measure-Call -M $script:M -Pattern '^GET /rest/api/3/attachment/meta$') | Should -Be 0
    }

    It 'T040 FR-003 the upload targets the specification tier only' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json') | Out-Null

        $posts = Get-AttachmentPost -M $script:M
        $posts.Count | Should -Be 1
        ($posts[0] -replace '^POST /rest/api/3/issue/([^/]+)/attachments.*$', '$1') | Should -Be 'COMP-1'
        (Measure-Call -M $script:M -Pattern '^POST /rest/api/3/issue/COMP-2/attachments') | Should -Be 0
    }

    It 'T041 FR-006 a specification ticket created in this run is published onto in this run' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $summary = Get-SummaryJson -Text $r.Out
        $summary.counts.created | Should -BeGreaterThan 0
        (Get-AttachmentPost -M $script:M).Count | Should -Be 1
    }

    It 'T034 C3.9 attachments disabled site-wide withholds everything, with one warning' {
        # `"enabled": false` is the C3.9 site state. The Bash port read it back
        # as TRUE until this case existed — jq's `//` treats false as absent —
        # while this port has always tested for the property's presence. The
        # twin is what makes that asymmetry visible.
        $cfg = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"attachment_meta":{"enabled":false,"uploadLimit":10485760}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $summary = Get-SummaryJson -Text $r.Out
        (Get-AttachmentPost -M $script:M).Count | Should -Be 0
        (Measure-Call -M $script:M -Pattern '^POST .*/comment') | Should -Be 0
        (Measure-Call -M $script:M -Pattern 'properties/spec-kit-jira-artifacts') | Should -Be 0
        @($summary.warnings | Where-Object { $_ -match 'attachments disabled' }).Count | Should -Be 1
    }

    It 'T034 C3.7 an unreadable limit withholds everything, with one warning and no upload' {
        $cfg = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"faults":{"rest/api/3/attachment/meta":{"status":500}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $summary = Get-SummaryJson -Text $r.Out
        (Get-AttachmentPost -M $script:M).Count | Should -Be 0
        (Measure-Call -M $script:M -Pattern 'properties/spec-kit-jira-artifacts') | Should -Be 0
        @($summary.warnings | Where-Object { $_ -match 'attachment limit could not be read' }).Count | Should -Be 1
    }

    It 'T054 SC-005 FR-019 a new checklist file alone is published on the next mirror' {
        # The scenario that justifies `after_checklist` existing at all:
        # spec.md, plan.md and tasks.md untouched, and the ONLY change is a
        # checklist a Spec Kit command just wrote.
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        # ONE run reaches the steady state: the publication classifies the set
        # as it stands AFTER the apply, so the identity marker the apply writes
        # into spec.md is already in the published hashes.
        Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json') | Out-Null
        (Get-AttachmentPost -M $script:M).Count | Should -Be 1

        $checklists = Join-Path $script:FeatureDir 'checklists'
        New-Item -ItemType Directory -Path $checklists -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $checklists 'ux.md'),
            "# Checklist: UX`n`n- [x] The flow is understandable`n")

        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_checklist'
        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $summary = Get-SummaryJson -Text $r.Out

        $written = @($summary.artifacts | Where-Object { $_.action -in 'published', 'revised' } | ForEach-Object { $_.path })
        ($written -join ',') | Should -Be 'checklists/ux.md'
        $posts = Get-AttachmentPost -M $script:M
        ($posts[-1] -replace '^.* parts=', '') | Should -Be 'checklists__ux.md'
    }

    It 'T055 publication onto a human-origin (adopted) specification ticket succeeds' {
        # The human-origin protection concerns DELETION and OVERWRITE, and
        # publication is neither: it adds an attachment and a comment, taking
        # nothing away (Principle I, spec Edge Cases).
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json') | Out-Null
        Invoke-WebRequest -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-1/properties/spec-kit-jira-origin" `
            -Body '{"origin":"human","adopted":true}' -ContentType 'application/json' -UseBasicParsing | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Research`n`nA second revision, nothing sensitive.`n")

        $before = (Get-AttachmentPost -M $script:M).Count
        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $summary = Get-SummaryJson -Text $r.Out
        (Get-AttachmentPost -M $script:M).Count | Should -Be ($before + 1)
        @($summary.artifacts | Where-Object { $_.action -in 'published', 'revised' }).Count | Should -BeGreaterThan 0
    }

    It 'T056 a refused routing publishes nothing, half-publishes nothing, writes no manifest' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        [System.IO.File]::WriteAllText($script:ConfigYml, $script:RefusedConfig + "`n")

        Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json') | Out-Null

        (Get-AttachmentPost -M $script:M).Count | Should -Be 0
        (Measure-Call -M $script:M -Pattern '^POST .*/comment') | Should -Be 0
        # The manifest is the thing that must NOT be written: one recorded for
        # a publication that never happened makes the next run believe those
        # artifacts are already on a ticket that does not exist.
        (Measure-Call -M $script:M -Pattern '^PUT .*properties/spec-kit-jira-artifacts') | Should -Be 0
    }

    It 'T056 the next successful run publishes the directory as it then stands' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        [System.IO.File]::WriteAllText($script:ConfigYml, $script:RefusedConfig + "`n")
        Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json') | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Phase 0 — Research`n`nWritten after the refusal.`n")
        [System.IO.File]::WriteAllText($script:ConfigYml, $script:RoutedConfig + "`n")

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $summary = Get-SummaryJson -Text $r.Out
        (Get-AttachmentPost -M $script:M).Count | Should -Be 1
        # research.md is in it as a FIRST publication — nothing recorded it.
        @($summary.artifacts | Where-Object { $_.path -eq 'research.md' })[0].action | Should -Be 'published'
    }
}
