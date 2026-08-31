# T014 [Phase 2, 036] — Pester twin of
# tests/bash/commands/test_reconcile_artifact_privacy.bats.
#
# The artifact privacy sweep is wired into the reconcile, and it sits BEFORE
# every Jira write (036 contracts/artifact-publication.md C5.1, C5.3, C5.5;
# FR-016).
#
# C5.5 states the assertion, and it is NOT "the upload was refused":
# publication runs after the description and story writes, so a guard beside
# the upload would leave those already written. The assertion is that the
# ticket was never touched — ZERO calls of EVERY write kind on the mock's own
# call log, which is what the run did rather than what its summary says.

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
    foreach ($v in 'SPEC_KIT_JIRA_PLAN_CONTEXT', 'SPEC_KIT_JIRA_LIFECYCLE', 'SPEC_KIT_JIRA_HOOK_CONTEXT', 'SPEC_KIT_JIRA_ALLOWLIST') {
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

    # Every write kind the sink can perform, as it appears in the mock's log.
    function Get-WriteCallCount {
        param($M)
        $lines = @(Get-JiraMockCallLog -Mock $M)
        return @($lines | Where-Object { $_ -match '^(POST|PUT|DELETE) ' }).Count
    }
}

Describe 'Invoke-JiraReconcile — the artifact privacy sweep (036 T014)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:FeatureDir = Join-Path $script:Work 'specs/001-billing-invoices'
        $script:Spec = Join-Path $script:FeatureDir 'spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        # The artifact set is `git ls-files` over the feature directory
        # (research R5), so the fixture has to be a repository — which every
        # consumer tree is.
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
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_ALLOWLIST -ErrorAction SilentlyContinue
    }

    It 'C5.5 a blocked shape in research.md leaves the ticket entirely untouched' {
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Research`n`nsee https://acme-real.atlassian.net/browse/X-1`n")

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 9
        # Not "no attachment was uploaded" — no CREATE, no UPDATE, no
        # TRANSITION, nothing. Only possible because the sweep runs first.
        (Get-WriteCallCount -M $script:M) | Should -Be 0
    }

    It 'C5.3 the refusal names the artifact and the shape, never the value' {
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Research`n`ntoken ATATTsecretvalue00099`n")

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec)
        $r.ExitCode | Should -Be 9
        $r.Out | Should -Match 'research\.md'
        $r.Out | Should -Match 'ATATT prefix'
        $r.Out | Should -Not -Match 'ATATTsecretvalue00099'
        (Get-WriteCallCount -M $script:M) | Should -Be 0
    }

    It 'C5.2 a blocked shape inside a BINARY artifact stops the run just the same' {
        $assets = Join-Path $script:FeatureDir 'assets'
        New-Item -ItemType Directory -Path $assets -Force | Out-Null
        $bytes = [System.Collections.Generic.List[byte]]::new()
        foreach ($b in 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01) { $bytes.Add([byte] $b) }
        $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes('ATATTdeadbeef99'))
        [System.IO.File]::WriteAllBytes((Join-Path $assets 'diagram.png'), $bytes.ToArray())

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec)
        $r.ExitCode | Should -Be 9
        $r.Out | Should -Match 'assets/diagram\.png'
        (Get-WriteCallCount -M $script:M) | Should -Be 0
    }

    It 'C5.1 dry-run refuses on the same finding — a dry-run that lies is worse than none' {
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Research`n`nsee https://acme-real.atlassian.net/browse/X-1`n")

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--dry-run')
        $r.ExitCode | Should -Be 9
        (Get-WriteCallCount -M $script:M) | Should -Be 0
    }

    It 'C5.3 a clean feature directory is unaffected — the sweep gates nothing it should not' {
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Research`n`nnothing sensitive here at all.`n")

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Not -Be 9
        $r.Out | Should -Not -Match 'blocked shape'
    }

    It 'FR-053 an allowlisted host in an artifact does not stop the run' {
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Research`n`nsee https://acme-real.atlassian.net/wiki/x`n")
        $env:SPEC_KIT_JIRA_ALLOWLIST = '["acme-real.atlassian.net"]'

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Not -Be 9
    }

    It 'Constitution III the refusal still never fails the host command in hook context' {
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Research`n`ntoken ATATTabc123XYZ`n")
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec)
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'WARNING'
        (Get-WriteCallCount -M $script:M) | Should -Be 0
    }
}
