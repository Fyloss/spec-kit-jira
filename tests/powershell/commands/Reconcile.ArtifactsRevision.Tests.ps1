# T077/T078/T079/T080 [Phase 5, 036] — Pester twin of
# tests/bash/commands/test_reconcile_artifacts_revision.bats.
#
# A revised artifact is republished and the earlier one survives (FR-013,
# FR-014, FR-015; US3 AS1-AS4; C6, comment-body B3).
#
# The assertions read the TICKET, through the mock's own attachment list, rather
# than the run summary. "The earlier copy survives" is a statement about the
# ticket, and a summary cannot make it true.

BeforeAll {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-mirrored-spec'
    $script:Contract = Join-Path $Root 'specs/036-attach-feature-artifacts/contracts/comment-body.md'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    foreach ($v in 'SPEC_KIT_JIRA_PLAN_CONTEXT', 'SPEC_KIT_JIRA_LIFECYCLE', 'SPEC_KIT_JIRA_HOOK_CONTEXT') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }

    function Invoke-Mirror {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out; $origErr = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($sw)
        try { Invoke-JiraReconcile -Arguments @('reconcile', $script:Spec, '--json') | Out-Null }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        $line = @($sw.ToString() -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count -eq 0) { return $null }
        return ($line[0] | ConvertFrom-Json)
    }

    # Run once to the steady state. ONE run, not two: the set the publication
    # classifies is rebuilt AFTER the apply, so the ticket markers the apply
    # stamps into spec.md are already in the published hashes. Before that
    # rebuild the first run published pre-marker bytes under a hash matching
    # neither, and the second "revised" spec.md to correct it.
    function Reset-ToSteadyState {
        Invoke-Mirror | Out-Null
    }

    # The attachment list the TICKET actually carries — the ground truth this
    # whole phase is about.
    # NO leading `, ` on the return. `return , @(…)` wraps the array in another
    # one, and piping THAT to Where-Object unrolls a single level — the filter
    # then sees ONE object (the inner array) rather than each attachment, and
    # `.filename -eq 'research.md'` on an array is truthy, so the whole list
    # passes as one item and every count reads 1. It made "after a revision the
    # ticket carries one copy" look true while the ticket carried two.
    function Get-TicketAttachment {
        $u = "$($script:M.BaseUrl)/rest/api/3/issue/COMP-1`?fields=attachment"
        $r = (Invoke-WebRequest -Uri $u -UseBasicParsing).Content | ConvertFrom-Json
        return @($r.fields.attachment | ForEach-Object {
                [pscustomobject]@{ id = [string] $_.id; filename = [string] $_.filename }
            })
    }

    function Get-CommentBody {
        return @(Get-JiraMockCallLog -Mock $script:M |
            Where-Object { $_ -match '^POST .*/comment' } |
            ForEach-Object { ($_ -replace '^.* body=', '') | ConvertFrom-Json })
    }

    function Measure-Call {
        param([string] $Pattern)
        return @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match $Pattern }).Count
    }
}

Describe 'Invoke-JiraReconcile — revisions keep the earlier copy (036 Phase 5)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:FeatureDir = Join-Path $script:Work 'specs/001-billing-invoices'
        $script:Spec = Join-Path $script:FeatureDir 'spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing-invoices'

        & git -C $script:Work init --quiet
        & git -C $script:Work config user.email 'fixture@example.invalid'
        & git -C $script:Work config user.name 'fixture'

        # research.md exists BEFORE the first run, so the first publication
        # carries it and every later change to it is a REVISION. Creating it
        # after settling would make every case below assert `published`.
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Phase 0 — Research`n`nThe first version of this file.`n")

        $cfg = @(
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
        [System.IO.File]::WriteAllText((Join-Path $script:Work '.specify/jira/config.yml'), $cfg + "`n")

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }

    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'T077 FR-013 a changed artifact is published again and announced as a revision' {
        Reset-ToSteadyState
        [System.IO.File]::WriteAllText($script:M.CallLog, '')

        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Phase 0 — Research`n`nThe second version of this file.`n")
        $summary = Invoke-Mirror
        @($summary.artifacts | Where-Object { $_.path -eq 'research.md' })[0].action | Should -Be 'revised'

        # B3: read from the call log, which carries the body verbatim since
        # T053 — the bytes the ticket received, not what the port says it
        # composed.
        $bodies = @(Get-CommentBody)
        $bodies[0].body.content[1].content[0].content[0].content[1].text | Should -Be ' — revised'
        $bodies[0].body.content[1].content[0].content[0].content[0].text | Should -Be 'research.md'
    }

    It 'T077 B2 the paragraph switches to the revision literal when anything is a revision' {
        Reset-ToSteadyState
        [System.IO.File]::WriteAllText($script:M.CallLog, '')
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'), "# Research`n`nChanged.`n")
        Invoke-Mirror | Out-Null

        $b = @(Get-CommentBody)[0].body
        # Compared against the contract's own line rather than a transcription:
        # the display layer through which a human reads a file can drop words.
        $expected = ((Get-Content -LiteralPath $script:Contract)[41] -replace '^  ', '')
        "$($b.content[0].content[0].text)``<event>``$($b.content[0].content[2].text)" | Should -Be $expected
    }

    It 'T078 FR-014 after a revision the ticket carries BOTH copies, under one name' {
        Reset-ToSteadyState
        $before = @(Get-TicketAttachment | Where-Object { $_.filename -eq 'research.md' })
        $before.Count | Should -Be 1

        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'), "# Research`n`nRevised.`n")
        Invoke-Mirror | Out-Null

        $after = @(Get-TicketAttachment | Where-Object { $_.filename -eq 'research.md' })
        # TWO attachments now share the name, with different ids: the revision
        # is a second attachment, never a replacement (research R7).
        $after.Count | Should -Be 2
        @($after.id | Sort-Object -Unique).Count | Should -Be 2
        # The original id is still there — this is the assertion, not the count.
        @($after | Where-Object { $_.id -eq $before[0].id }).Count | Should -Be 1
    }

    It 'T078 C6 no DELETE is issued against any attachment, on any run' {
        Reset-ToSteadyState
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'), "# Research`n`nOnce.`n")
        Invoke-Mirror | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'), "# Research`n`nTwice.`n")
        Invoke-Mirror | Out-Null

        (Measure-Call '^DELETE ') | Should -Be 0
    }

    It 'T079 US3 AS3 several versions leave a comment stream that orders them' {
        Reset-ToSteadyState
        [System.IO.File]::WriteAllText($script:M.CallLog, '')

        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'), "# Research`n`nVersion two.`n")
        Invoke-Mirror | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'), "# Research`n`nVersion three.`n")
        Invoke-Mirror | Out-Null

        # Two comments, in run order, each naming research.md as revised. A
        # reader identifies the most recent version as the one the last comment
        # announces, without opening a single file.
        $bodies = @(Get-CommentBody)
        $bodies.Count | Should -Be 2
        foreach ($b in $bodies) {
            $b.body.content[1].content[0].content[0].content[0].text | Should -Be 'research.md'
            $b.body.content[1].content[0].content[0].content[1].text | Should -Be ' — revised'
        }
        @(Get-TicketAttachment | Where-Object { $_.filename -eq 'research.md' }).Count | Should -Be 3
    }

    It 'T080 FR-015 deleting an artifact leaves its copies on the ticket and writes nothing' {
        Reset-ToSteadyState
        @(Get-TicketAttachment | Where-Object { $_.filename -eq 'research.md' }).Count | Should -Be 1

        Remove-Item -LiteralPath (Join-Path $script:FeatureDir 'research.md') -Force
        [System.IO.File]::WriteAllText($script:M.CallLog, '')
        $summary = Invoke-Mirror

        # Zero Jira writes of every publication kind: a deletion is not a
        # publication event, and there is nothing on the ticket to correct.
        (Measure-Call '^POST .*/attachments') | Should -Be 0
        (Measure-Call '^POST .*/comment') | Should -Be 0
        (Measure-Call '^PUT .*properties/spec-kit-jira-artifacts') | Should -Be 0

        @(Get-TicketAttachment | Where-Object { $_.filename -eq 'research.md' }).Count | Should -Be 1
        @($summary.artifacts | Where-Object { $_.path -eq 'research.md' }).Count | Should -Be 0
    }

    It 'T080 FR-015 the manifest entry for a deleted artifact is LEFT IN PLACE' {
        # Its attachment still exists on the ticket, so the manifest still
        # describes reality. Dropping it would make a later re-add look like a
        # first publication — a duplicate for no reason.
        Reset-ToSteadyState
        Remove-Item -LiteralPath (Join-Path $script:FeatureDir 'research.md') -Force
        Invoke-Mirror | Out-Null

        $u = "$($script:M.BaseUrl)/rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts"
        $manifest = ((Invoke-WebRequest -Uri $u -UseBasicParsing).Content | ConvertFrom-Json).value.artifacts
        $manifest.PSObject.Properties.Name | Should -Contain 'research.md'
    }
}
