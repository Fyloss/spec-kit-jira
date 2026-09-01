# T061/T063/T066/T067/T068/T069 [Phase 4, 036] — Pester twin of
# tests/bash/commands/test_reconcile_artifacts_idempotent.bats.
#
# Re-running changes nothing (contracts/artifact-publication.md C1 "Call
# budget", C4.3, C4.4; FR-009, FR-010; US2 AS1-AS3; SC-003, SC-010).
#
# Every assertion reads the mock's call log, never the summary. A run that
# reported `unchanged` and issued the writes anyway is precisely the defect, and
# only the call log can tell the two apart.
#
# THE STEADY STATE IS THE SECOND RUN. Run 1 creates the tickets, stamps its
# identity marker into spec.md, and publishes the set as it stands AFTER that
# write — so run 2 has nothing left to do.

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

    function Invoke-Mirror {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out; $origErr = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($sw)
        try { Invoke-JiraReconcile -Arguments @('reconcile', $script:Spec, '--json') | Out-Null }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        $text = $sw.ToString()
        $line = @($text -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
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
        [System.IO.File]::WriteAllText($script:M.CallLog, '')
    }

    function Measure-Call {
        param([string] $Pattern)
        return @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match $Pattern }).Count
    }

    function Measure-Upload { return (Measure-Call '^POST .*/attachments( |$)') }
    function Measure-Comment { return (Measure-Call '^POST .*/comment( |$)') }
    function Measure-ManifestWrite { return (Measure-Call '^PUT .*properties/spec-kit-jira-artifacts') }
    function Measure-ManifestRead { return (Measure-Call '^GET .*properties/spec-kit-jira-artifacts') }
}

Describe 'Invoke-JiraReconcile — the zero-churn floor (036 Phase 4)' {
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
        Remove-Item Env:\SPEC_KIT_JIRA_PROPERTY_CAP -ErrorAction SilentlyContinue
    }

    It 'T066 FR-009 an unchanged directory issues ZERO writes of all three kinds' {
        Reset-ToSteadyState
        Invoke-Mirror | Out-Null

        (Measure-Upload) | Should -Be 0
        (Measure-Comment) | Should -Be 0
        (Measure-ManifestWrite) | Should -Be 0
    }

    It 'T066 the run still REPORTS every artifact, as unchanged' {
        # Zero writes must not mean zero information: the operator needs to see
        # that the run considered each file and decided nothing.
        Reset-ToSteadyState
        $summary = Invoke-Mirror
        @($summary.artifacts).Count | Should -BeGreaterThan 0
        @($summary.artifacts | Where-Object { $_.action -ne 'unchanged' }).Count | Should -Be 0
    }

    It 'T067 C1 a run that proceeds with everything unchanged makes exactly ONE artifact call' {
        # The middle row of the call budget, and the one a loose reading gets
        # wrong: not zero — the manifest still has to be read to know nothing
        # changed — and not more than one, because the trust rule's ticket read
        # is conditional and every id is still on the ticket.
        Reset-ToSteadyState
        Invoke-Mirror | Out-Null

        (Measure-ManifestRead) | Should -Be 1
        (Measure-Upload) | Should -Be 0
        (Measure-Comment) | Should -Be 0
        (Measure-ManifestWrite) | Should -Be 0
    }

    It 'T067 C1 a run that publishes makes the bounded set and no more' {
        [System.IO.File]::WriteAllText($script:M.CallLog, '')
        Invoke-Mirror | Out-Null

        (Measure-Call '^GET /rest/api/3/attachment/meta$') | Should -Be 1
        (Measure-ManifestRead) | Should -Be 1
        (Measure-Upload) | Should -Be 1
        (Measure-Comment) | Should -Be 1
        (Measure-ManifestWrite) | Should -Be 1
    }

    It 'T068 US2 AS2 the third and fourth runs leave the counts where the first left them' {
        Reset-ToSteadyState

        Invoke-Mirror | Out-Null
        $up = Measure-Upload
        $cm = Measure-Comment

        Invoke-Mirror | Out-Null
        (Measure-Upload) | Should -Be $up
        (Measure-Comment) | Should -Be $cm
        (Measure-Upload) | Should -Be 0
    }

    It 'T069 FR-010 SC-003 exactly one changed artifact publishes exactly that one' {
        Reset-ToSteadyState

        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Phase 0 — Research`n`nOne line changed, nothing else.`n")
        $summary = Invoke-Mirror

        (Measure-Upload) | Should -Be 1
        $post = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^POST .*/attachments' })
        ($post[0] -replace '^.* parts=', '') | Should -Be 'research.md'
        (Measure-Comment) | Should -Be 1
        (@($summary.artifacts | Where-Object { $_.action -in 'published', 'revised' } |
                ForEach-Object { $_.path }) -join ',') | Should -Be 'research.md'
    }

    It 'T069 FR-008 SC-004 exactly ONE comment per publishing run, and zero otherwise' {
        Reset-ToSteadyState
        (Measure-Comment) | Should -Be 0

        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'), "# Research`n`nA change.`n")
        Invoke-Mirror | Out-Null
        (Measure-Comment) | Should -Be 1

        [System.IO.File]::WriteAllText($script:M.CallLog, '')
        Invoke-Mirror | Out-Null
        (Measure-Comment) | Should -Be 0
    }

    It "T061 C4.3 the ticket's attachment list is read ONLY when the manifest claims an id" {
        # A first run has no manifest, so there is nothing to disbelieve and the
        # extra read would be a request for nothing.
        [System.IO.File]::WriteAllText($script:M.CallLog, '')
        Invoke-Mirror | Out-Null
        (Measure-Call '^GET /rest/api/3/issue/[^/]+\?fields=attachment') | Should -Be 0

        [System.IO.File]::WriteAllText($script:M.CallLog, '')
        Invoke-Mirror | Out-Null
        (Measure-Call '^GET /rest/api/3/issue/[^/]+\?fields=attachment') | Should -Be 1
    }

    It 'T061 SC-010 a manifest ahead of the ticket republishes rather than trusting itself' {
        # The property write landed and the upload did not — the shape a run
        # that died partway leaves behind. Without the trust rule the artifact
        # reads `unchanged` forever and never exists on the ticket.
        Reset-ToSteadyState

        $url = "$($script:M.BaseUrl)/rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts"
        $current = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content | ConvertFrom-Json -AsHashtable
        $artifacts = $current.value.artifacts
        foreach ($k in @($artifacts.Keys)) { $artifacts[$k].attachment_id = '999999' }
        $doc = @{ schema = 1; artifacts = $artifacts } | ConvertTo-Json -Depth 10 -Compress
        Invoke-WebRequest -Method Put -Uri $url -Body $doc -ContentType 'application/json' -UseBasicParsing | Out-Null
        [System.IO.File]::WriteAllText($script:M.CallLog, '')

        $summary = Invoke-Mirror
        (Measure-Upload) | Should -Be 1
        @($summary.artifacts | Where-Object { $_.action -eq 'published' }).Count | Should -BeGreaterThan 0
    }

    It 'T061 SC-010 an upload that landed with no manifest written republishes, as a revision' {
        # The other half of the partial-run pair: the attachments are on the
        # ticket and nothing recorded them. The duplicate is accepted — Jira
        # allows two attachments with one name, and losing an artifact is worse
        # than carrying it twice (FR-014).
        #
        # An EMPTY manifest, not a deleted property: the classifier reads both
        # the same way, and Jira's property DELETE is a route neither mock
        # serves, so a delete would silently do nothing.
        Reset-ToSteadyState
        $url = "$($script:M.BaseUrl)/rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts"
        Invoke-WebRequest -Method Put -Uri $url -Body '{"schema":1,"artifacts":{}}' `
            -ContentType 'application/json' -UseBasicParsing | Out-Null
        [System.IO.File]::WriteAllText($script:M.CallLog, '')

        $summary = Invoke-Mirror
        (Measure-Upload) | Should -Be 1
        @($summary.artifacts | Where-Object { $_.action -eq 'unchanged' }).Count | Should -Be 0
        (Measure-ManifestWrite) | Should -Be 1
    }

    It 'T063 C4.4.1 a manifest that would overflow withholds the WHOLE publication before any upload' {
        # Fail closed rather than publishing what fits: a partial manifest would
        # make the next run republish exactly the artifacts this one dropped,
        # forever. The cap is lowered rather than the fixture widened.
        $env:SPEC_KIT_JIRA_PROPERTY_CAP = '1'
        $summary = Invoke-Mirror

        (Measure-Upload) | Should -Be 0
        (Measure-Comment) | Should -Be 0
        (Measure-ManifestWrite) | Should -Be 0
        @($summary.warnings | Where-Object { $_ -match 'more artifacts than one ticket can track' }).Count | Should -Be 1
    }
}
