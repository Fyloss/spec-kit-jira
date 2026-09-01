# T084/T085/T086/T088/T090/T092 [Phase 6, 036] — Pester twin of
# tests/bash/commands/test_reconcile_artifacts_faults.bats.
#
# The operator can predict and audit the publication, and no publication
# failure ever fails the host command (contracts/artifact-publication.md
# C3.2-C3.6; FR-018, FR-020, FR-021; US4 AS1-AS4; SC-006, SC-011).
#
# THIS FILE EXISTS BECAUSE ITS ABSENCE COST A DEFECT. The dry-run path on this
# port read `$applyOutcome` — a variable only the apply assigns, and a dry run
# never applies — so under StrictMode it threw at run time. It was unreachable
# while a dry run's artifact set was empty, and the moment the set became real
# the whole run died with exit 1. Nothing caught it until the conformance
# corpus compared the two ports; the Bash twin had covered dry-run prediction
# from the start and this side had not.
#
# The faults are declared at mock STARTUP rather than mutated mid-test: this
# port's mock server reads its config once, into $Faults, where the Bash shim
# re-reads the file on every request.

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

    function Invoke-Run {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out; $origErr = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($sw)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        $text = $sw.ToString()
        $line = @($text -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $json = if ($line.Count -gt 0) { $line[0] | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $text; Json = $json }
    }

    function Start-Faulted {
        param([string] $Fragment, [int] $Status)
        $cfg = Write-JiraMockConfig -Json (@{
                projects = @{ COMP = 'company' }
                faults   = @{ $Fragment = @{ status = $Status } }
            } | ConvertTo-Json -Depth 5 -Compress)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }

    function Start-Clean {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }

    function Measure-Call {
        param([string] $Pattern)
        return @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match $Pattern }).Count
    }
}

Describe 'Invoke-JiraReconcile — predicting and surviving a publication failure (036 Phase 6)' {
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
        $script:M = $null
    }

    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }

    It 'T084 FR-020 a dry-run names what it would publish and issues ZERO writes' {
        Start-Clean
        $r = Invoke-Run @('reconcile', $script:Spec, '--dry-run', '--json')

        # The exit code first. A StrictMode read of a variable the apply never
        # assigns killed this exact path, and every assertion below would then
        # fail for a reason that looks like the feature rather than the port.
        $r.ExitCode | Should -Be 0

        @($r.Json.artifacts | Where-Object { $_.action -eq 'would-publish' }).Count | Should -BeGreaterThan 0
        @($r.Json.artifacts | Where-Object { $_.action -in 'published', 'revised' }).Count | Should -Be 0
        (Measure-Call '^(POST|PUT|DELETE) ') | Should -Be 0
    }

    It 'T084 FR-020 the dry-run names the comment it would post, verbatim' {
        Start-Clean
        $r = Invoke-Run @('reconcile', $script:Spec, '--dry-run', '--json')
        $comment = @($r.Json.actions | Where-Object { ([string]$_.url).EndsWith('/comment') })[0]
        $comment.body.body.type | Should -Be 'doc'
        @($comment.body.body.content[1].content).Count | Should -BeGreaterThan 0
    }

    It "T085 SC-006 the dry-run's predicted set equals the real run's actual set, exactly" {
        Start-Clean
        $predicted = @((Invoke-Run @('reconcile', $script:Spec, '--dry-run', '--json')).Json.artifacts |
            Where-Object { $_.action -in 'would-publish', 'would-revise' } | ForEach-Object { $_.path }) |
        Sort-Object -CaseSensitive
        $actual = @((Invoke-Run @('reconcile', $script:Spec, '--json')).Json.artifacts |
            Where-Object { $_.action -in 'published', 'revised' } | ForEach-Object { $_.path }) |
        Sort-Object -CaseSensitive

        ($predicted -join ',') | Should -Not -BeNullOrEmpty
        ($predicted -join ',') | Should -Be ($actual -join ',')
    }

    It 'T086 FR-021 a whole-publication withholding is reported per artifact, never as published' {
        # The one an audit trail cannot afford to get wrong: the site refused
        # everything, and every entry must say so.
        $cfg = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"attachment_meta":{"enabled":false}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-Run @('reconcile', $script:Spec, '--json')
        @($r.Json.artifacts).Count | Should -BeGreaterThan 0
        @($r.Json.artifacts | Where-Object { $_.action -ne 'withheld' }).Count | Should -Be 0
        @($r.Json.artifacts | Where-Object { $_.reason -ne 'site-disabled' }).Count | Should -Be 0
    }

    It 'T088 C3.2 a 403 on the upload withholds and leaves the run exit code unchanged' {
        # THE test. Without the translation at the call site, `auth` (exit 3)
        # propagates and every reconcile fails for a token that merely lacks
        # one optional permission.
        Start-Faulted -Fragment 'rest/api/3/issue/COMP-1/attachments' -Status 403
        $r = Invoke-Run @('reconcile', $script:Spec, '--json')

        $r.ExitCode | Should -Be 0
        @($r.Json.warnings | Where-Object { $_ -match 'Create attachments' }).Count | Should -Be 1
        # The warning names the TICKET, not merely the capability.
        @($r.Json.warnings | Where-Object { $_ -match 'COMP-1' }).Count | Should -BeGreaterThan 0
        @($r.Json.artifacts | Where-Object { $_.reason -eq 'upload-failed' }).Count | Should -BeGreaterThan 0
        # …and the reconcile's OWN writes stand.
        $r.Json.counts.created | Should -BeGreaterThan 0
    }

    It 'T090 C3.4 a 5xx withholds and writes NO manifest' {
        Start-Faulted -Fragment 'rest/api/3/issue/COMP-1/attachments' -Status 500
        $r = Invoke-Run @('reconcile', $script:Spec, '--json')

        $r.ExitCode | Should -Be 0
        # Recording a publication that did not happen makes the next run skip
        # exactly the artifacts this one lost.
        (Measure-Call '^PUT .*properties/spec-kit-jira-artifacts') | Should -Be 0
        @($r.Json.warnings | Where-Object { $_ -match 'could not be uploaded' }).Count | Should -Be 1
    }

    It 'T090 C3.5 a failed comment still writes the manifest — the attachments landed' {
        Start-Faulted -Fragment 'rest/api/3/issue/COMP-1/comment' -Status 500
        $r = Invoke-Run @('reconcile', $script:Spec, '--json')

        $r.ExitCode | Should -Be 0
        (Measure-Call '^POST .*/attachments') | Should -Be 1
        (Measure-Call '^PUT .*properties/spec-kit-jira-artifacts') | Should -Be 1
        @($r.Json.warnings | Where-Object { $_ -match 'comment announcing them could not be posted' }).Count | Should -Be 1
    }

    It 'T090 C4.4.2 a manifest write refused with a 4xx names SIZE as the cause' {
        # Not a generic "the record did not save": C4.4.1 already checked the
        # size, so a site refusing the document anyway means the assumed cap is
        # wrong, and the operator needs the number to say so.
        Start-Faulted -Fragment 'rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts' -Status 400
        $r = Invoke-Run @('reconcile', $script:Spec, '--json')

        $r.ExitCode | Should -Be 0
        @($r.Json.warnings | Where-Object { $_ -match 'refused the \d+-byte record' }).Count | Should -Be 1
        @($r.Json.warnings | Where-Object { $_ -match 'assumed cap' }).Count | Should -Be 1
    }

    It 'T113 C3.3 a 413 names the file count and the site limit, not a generic failure' {
        # The row T090 skipped. Both ports translated a 413 from the day the
        # publication shipped and NO test on either exercised it — code without
        # the test Constitution XIII requires to precede it, on a
        # message-composing branch, which is the exact shape of this port's
        # StrictMode defect: parses clean, lints clean, dies when reached.
        Start-Faulted -Fragment 'rest/api/3/issue/COMP-1/attachments' -Status 413
        $r = Invoke-Run @('reconcile', $script:Spec, '--json')

        $r.ExitCode | Should -Be 0
        @($r.Json.warnings | Where-Object { $_ -match 'rejected by COMP-1 as too large' }).Count | Should -Be 1
        @($r.Json.warnings | Where-Object { $_ -match 'offered \d+ files' }).Count | Should -Be 1
        @($r.Json.warnings | Where-Object { $_ -match '\d+-byte per-file limit' }).Count | Should -Be 1
        @($r.Json.artifacts | Where-Object { $_.reason -eq 'upload-failed' }).Count | Should -BeGreaterThan 0
        (Measure-Call '^PUT .*properties/spec-kit-jira-artifacts') | Should -Be 0
    }

    It 'T111 T112 the default prose output names the withheld artifacts and the remedy' {
        # No `--json` here, and that is the whole point: prose is the DEFAULT
        # rendering, and until T111/T112 a 403 printed `Warnings: 2, Errors: 0`
        # and nothing else — no file, no reason, no remedy.
        Start-Faulted -Fragment 'rest/api/3/issue/COMP-1/attachments' -Status 403
        $r = Invoke-Run @('reconcile', $script:Spec)

        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'Artifacts: 0 published'
        $r.Out | Should -Match 'withheld — upload-failed'
        $r.Out | Should -Match 'Artifact warnings:'
        $r.Out | Should -Match 'Create attachments'
        $r.Out | Should -Match 'COMP-1'
    }

    It 'T111 FR-017 the default output names an oversized artifact, its size and the limit' {
        $cfg = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"attachment_meta":{"enabled":true,"uploadLimit":8}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-Run @('reconcile', $script:Spec)
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'withheld — oversized \('
        $r.Out | Should -Match ' bytes, limit 8\)'
    }

    It 'T092 SC-011 a publication failure in HOOK context leaves exit 0' {
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        Start-Faulted -Fragment 'rest/api/3/issue/COMP-1/attachments' -Status 403
        $r = Invoke-Run @('reconcile', $script:Spec)
        $r.ExitCode | Should -Be 0
    }
}
