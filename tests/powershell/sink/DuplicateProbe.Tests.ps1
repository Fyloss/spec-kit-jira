# T047 [US4, P3, droppable] — mirror of tests/bash/sink/test_duplicate_probe.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/DuplicateProbe.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
}

Describe 'Get-JiraDuplicateProbeResult' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T1, T2 -- hit: sorted keys, found tickets untouched' {
        $cfg = Write-JiraMockConfig -Json '{"labelSearch":{"speckit-001-x":["COMP-9","COMP-2"]}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Get-JiraDuplicateProbeResult -BaseUrl $script:M.BaseUrl -ProjectKey 'COMP' -Label 'speckit-001-x'
        $r.Verdict | Should -Be 'hit'
        ($r.Keys -join ',') | Should -Be 'COMP-2,COMP-9'
    }

    It 'T5 -- no labelled ticket: clear' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $r = Get-JiraDuplicateProbeResult -BaseUrl $script:M.BaseUrl -ProjectKey 'COMP' -Label 'speckit-001-nothing-here'
        $r.Verdict | Should -Be 'clear'
    }

    It 'T4 -- 400/403/404 on the probe: unavailable, never propagated as an error' {
        foreach ($code in 400, 403, 404) {
            $cfg = Write-JiraMockConfig -Json "{`"faults`":{`"rest/api/3/search/jql`":{`"status`":$code}}}"
            $script:M = Start-JiraMock -ConfigPath $cfg
            $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
            $r = Get-JiraDuplicateProbeResult -BaseUrl $script:M.BaseUrl -ProjectKey 'COMP' -Label 'speckit-001-x'
            $r.Verdict | Should -Be 'unavailable'
            Stop-JiraMock -Mock $script:M
            $script:M = $null
        }
    }

    It '017 regression -- a missing credential degrades to unavailable rather than throwing (Get-JiraAuthHeader''s -Email is Mandatory)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $savedEmail = $env:JIRA_EMAIL
        Remove-Item Env:\JIRA_EMAIL -ErrorAction SilentlyContinue
        try {
            $r = Get-JiraDuplicateProbeResult -BaseUrl $script:M.BaseUrl -ProjectKey 'COMP' -Label 'speckit-001-x'
            $r.Verdict | Should -Be 'unavailable'
        }
        finally { $env:JIRA_EMAIL = $savedEmail }
    }
}

# --- Full pipeline: T1, T3, T6, T7, T9 --------------------------------------

Describe 'Invoke-JiraReconcile -- the duplicate probe, full pipeline' {
    BeforeAll {
        Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force
        function Invoke-Captured2 {
            # Mirrors bats' `run`: stdout and stderr merged into one string,
            # since a fault/WARNING line (FR-016) is written to stderr, not
            # the --json summary.
            param([string[]] $ArgList)
            $sw = [System.IO.StringWriter]::new()
            $se = [System.IO.StringWriter]::new()
            $oo = [Console]::Out
            $oe = [Console]::Error
            [Console]::SetOut($sw)
            [Console]::SetError($se)
            try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
            return $sw.ToString() + $se.ToString()
        }
    }
    BeforeEach {
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing-invoices'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'COMP'
        # A COPY of the fixture's config, never the fixture itself: 021's
        # Save-JiraRunState writes $JIRA_CONFIG_DIR/state/<feature>.json on
        # every successful reconcile, and this test reaches one. Pointed at the
        # source tree it deposits a machine-specific document (absolute paths,
        # the live mock port, the real extension version) inside
        # tests/conformance/fixtures, where the state/.gitignore's `*` then
        # hides it from git status. Mirror of the bats twin.
        $cfgDir = Join-Path $TestDrive 'jira-config'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        Copy-Item -Path (Join-Path $Root 'tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira/*.yml') -Destination $cfgDir -Force
        $env:JIRA_CONFIG_DIR = $cfgDir
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT, Env:\SPEC_KIT_JIRA_LIFECYCLE, Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue

        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'fresh') -Force | Out-Null
        $script:Spec = Join-Path $TestDrive 'fresh/spec.md'
        @(
            '# Feature Specification: Billing Invoices', '', 'We need a reconcile bridge for specs.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a signed-in user', '- **When** they open the board', '- **Then** the widgets load'
        ) -join "`n" | Set-Content -LiteralPath $script:Spec -NoNewline
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T1 -- full pipeline: a hit refuses before creating the parent, zero writes, exit 4' {
        $cfg = Write-JiraMockConfig -Json '{"labelSearch":{"speckit-001-billing-invoices":["COMP-9","COMP-2"]}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        Clear-Content -LiteralPath $script:M.CallLog
        $out = Invoke-Captured2 @('reconcile', $script:Spec, '--json')
        $script:code | Should -Be 4
        $out | Should -Match 'COMP-2, COMP-9'
        $out | Should -Match 'mention <issue-key>'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' }).Count | Should -Be 0
    }

    It 'T3 -- markers present, binding those very tickets: the probe never fires, no request' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111'
        $null = Invoke-Captured2 @('reconcile', $script:Spec, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $null = Invoke-Captured2 @('reconcile', $script:Spec, '--json')
        $script:code | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'search/jql' }).Count | Should -Be 0
    }

    It 'T6 -- a settled re-run issues no probe request at all' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111'
        $null = Invoke-Captured2 @('reconcile', $script:Spec, '--json')
        $null = Invoke-Captured2 @('reconcile', $script:Spec, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $null = Invoke-Captured2 @('reconcile', $script:Spec, '--json')
        $script:code | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'search/jql' }).Count | Should -Be 0
    }

    It 'T7 -- --dry-run predicts the refusal' {
        $cfg = Write-JiraMockConfig -Json '{"labelSearch":{"speckit-001-billing-invoices":["COMP-9"]}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $out = Invoke-Captured2 @('reconcile', $script:Spec, '--dry-run', '--json')
        $script:code | Should -Be 4
        $out | Should -Match 'COMP-9'
    }

    It 'T9 -- under a hook context, the hit refusal returns 0 wrapped in the standard WARNING form' {
        $cfg = Write-JiraMockConfig -Json '{"labelSearch":{"speckit-001-billing-invoices":["COMP-9"]}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        try {
            $out = Invoke-Captured2 @('reconcile', $script:Spec, '--json')
        } finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue }
        $script:code | Should -Be 0
        $out | Should -Match '^WARNING: .*\(exit 4\)'
        $out | Should -Match 'This spec-kit command completed normally\.'
    }

    It 'unavailable: 400 on the probe lets the run complete as it does with the probe absent, plus one warning' {
        $cfg = Write-JiraMockConfig -Json '{"faults":{"rest/api/3/search/jql":{"status":400}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $out = Invoke-Captured2 @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $out.counts.created | Should -Be 2
        (@($out.warnings) -join ' ') | Should -Match 'duplicate-label check could not be performed'
    }
}
