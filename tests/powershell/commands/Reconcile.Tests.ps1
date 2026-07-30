# T059 [US3] — The reconcile command, PowerShell side. Mirror of
# tests/bash/commands/test_reconcile.bats. Cross-port parity is proven in bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    # 004 T014b: migrated off the placeholder key, which config resolution
    # (FR-005) now refuses outright. Both the project key and epic strategy
    # are overridden here, so config.yml is never read (contract
    # "Precedence"); the fixture's config.local.yml supplies the persisted
    # binding this suite's creation-context assertions now resolve through.
    $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
    $env:SPEC_KIT_JIRA_EPIC_STRATEGY = 'per_repo'
    $env:JIRA_CONFIG_DIR = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-reconcile-legacy/.specify/jira'
    $env:SPEC_KIT_JIRA_PLAN_CONTEXT = $null

    $script:SpecWith = Join-Path $TestDrive 'with.md'
    @(
        '# Feature Specification: Rich Tickets', '', 'We need a reconcile bridge for specs.', '',
        '### User Story 1 - The core story (Priority: P1)', '', 'Estimation: 5', '',
        '- **Given** a signed-in user', '- **When** they open the board', '- **Then** the widgets load'
    ) -join "`n" | Set-Content -LiteralPath $script:SpecWith -NoNewline

    $script:SpecNoSummary = Join-Path $TestDrive 'nosummary.md'
    '# Only A Title' | Set-Content -LiteralPath $script:SpecNoSummary -NoNewline

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile (dry-run)' {
    It 'plans a create with the story title and a rich ADF description' {
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) | ConvertFrom-Json
        $out.actions[0].method | Should -Be 'POST'
        $out.actions[0].body.fields.summary | Should -Be 'The core story'
        $out.actions[0].body.fields.description.type | Should -Be 'doc'
        @($out.actions[0].body.fields.description.content | Where-Object { $_.type -eq 'panel' }).Count | Should -Be 1
    }

    It 'yields a non-empty description for a spec with no ## Summary (SC-002)' {
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecNoSummary) | ConvertFrom-Json
        $out.actions[0].body.fields.summary | Should -Be 'Only A Title'
        @($out.actions[0].body.fields.description.content | Where-Object { $_.type -eq 'paragraph' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'never re-sends the estimation on update (FR-018)' {
        # T018: the durable identifier is pinned via SPEC_KIT_JIRA_ID_SOURCE
        # (research R4) rather than the retired positional "s1", since a
        # marker-less story is now assigned a fresh identifier before parsing.
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111'
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"estimation_field_id":"customfield_30044","tickets":{"1111111111111111":"ABC-1"}}'
        try {
            $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) | ConvertFrom-Json
            $out.actions[0].method | Should -Be 'PUT'
            $out.actions[0].body.fields.PSObject.Properties.Name | Should -Not -Contain 'customfield_30044'
        }
        finally { $env:SPEC_KIT_JIRA_PLAN_CONTEXT = $null; $env:SPEC_KIT_JIRA_ID_SOURCE = $null }
    }

    It 'reports host-relative action urls (no coordinate leaks)' {
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) | ConvertFrom-Json
        $out.actions[0].url | Should -Be '/rest/api/3/issue'
    }

    It 'resolves a bare relative spec filename from the current directory (NFR-1)' {
        # Split-Path -Parent yields '' for a bare filename, where the Bash port's
        # dirname yields '.' — the folder must still resolve instead of failing
        # the interchange schema with an empty spec_ref.folder.
        Push-Location $TestDrive
        try {
            $out = Invoke-Captured @('reconcile', '--dry-run', '--json', 'with.md') 2> $null | ConvertFrom-Json
            $script:code | Should -Be 0
            $out.actions[0].body.fields.summary | Should -Be 'The core story'
        }
        finally { Pop-Location }
    }

    It 'an override equal to the shipped placeholder is refused, zero writes (004 FR-005)' {
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'PROJ'
        try {
            $null = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) 2>$null
            $script:code | Should -Not -Be 0
        }
        finally { $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST' }
    }

    It 'maps an invalid SPEC_KIT_JIRA_LIFECYCLE to exit 4 with an actionable error (FR-032)' {
        $env:SPEC_KIT_JIRA_LIFECYCLE = '{not json'
        try {
            $null = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) 2>$null
            $script:code | Should -Be 4
        }
        finally { $env:SPEC_KIT_JIRA_LIFECYCLE = $null }
    }
}

Describe 'Message discipline (T049 / T088, 003 US5)' {
    # Under `optional: false` the assistant PERFORMS this step inside every
    # lifecycle command, so whatever it says is said seven times a feature. Two
    # limits follow, and neither is cosmetic: at most one message per run
    # (FR-016), and the not-yet-configured notice — the state of every repository
    # for its first hour — capped at three lines (FR-019).
    #
    # The causes must also be told apart. The reported defect's message named a
    # machine-wide CLI that was never how this extension is delivered, which sent
    # the developer to install something that does not exist.
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Config.psm1') -Force

        function Invoke-Degraded {
            param([string[]] $ArgList)
            $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
            $oo = [Console]::Out; $oe = [Console]::Error
            [Console]::SetOut($sw); [Console]::SetError($se)
            try { $code = Invoke-JiraReconcile -Arguments $ArgList }
            finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
            return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
        }
    }

    BeforeEach {
        $script:MdWork = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:MdWork '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $script:MdWork '.specify/jira'
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $script:MdWork '.specify/extensions.yml'
        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        $script:SavedBase = $env:SPEC_KIT_JIRA_BASE_URL
    }
    AfterEach {
        $env:SPEC_KIT_JIRA_BASE_URL = $script:SavedBase
        Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_EXTENSIONS_YML -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_EXTENSION_ROOT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:MdWork -ErrorAction SilentlyContinue
    }

    It 'reports "not yet configured" in at most THREE lines, exit 0 (FR-019)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $r = Invoke-Degraded @('reconcile', '--json', $script:SpecWith)
        $r.ExitCode | Should -Be 0
        @($r.Err.TrimEnd("`n") -split "`n").Count | Should -BeLessOrEqual 3
        $r.Err | Should -Match 'not bound to a Jira project yet'
        # It names the configuration command, spelled as it is registered (FR-018)...
        $r.Err | Should -Match ([regex]::Escape('/speckit.jira.config'))
        # ...and does not read as a failure: the host command succeeded.
        $r.Err | Should -Match 'completed normally'
    }

    It 'never reports the unconfigured state as a missing CLI (FR-017)' {
        # The exact wording of the reported defect. It was wrong twice: the cause
        # was not a missing CLI, and this extension is not delivered as one.
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $r = Invoke-Degraded @('reconcile', '--json', $script:SpecWith)
        ($r.Out + $r.Err) | Should -Not -Match 'CLI not installed'
        ($r.Out + $r.Err) | Should -Not -Match 'not installed'
    }

    It 'reports a missing entry point as its OWN cause (T088, T090, FR-017)' {
        # A half-broken install: this port running while its twin is missing. The
        # remedy is an install, not a configuration — so saying "not configured"
        # here would send the operator to the wrong place entirely.
        $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
        $fake = Join-Path $script:MdWork 'fake-root'
        New-Item -ItemType Directory -Path (Join-Path $fake 'scripts/bash') -Force | Out-Null
        Set-Content -Path (Join-Path $fake 'scripts/bash/spec-kit-jira.sh') -Value '#!/usr/bin/env bash' -NoNewline
        # ...and no scripts/powershell/spec-kit-jira.ps1.
        $env:SPEC_KIT_JIRA_EXTENSION_ROOT = $fake
        $r = Invoke-Degraded @('reconcile', '--json', $script:SpecWith)
        $r.ExitCode | Should -Be 0
        $r.Err | Should -Match 'bridge entry point'
        $r.Err | Should -Match ([regex]::Escape('powershell/spec-kit-jira.ps1'))
        $r.Err | Should -Match 'install is incomplete'
        # Distinguished from the not-configured cause...
        $r.Err | Should -Not -Match 'not bound to a Jira project'
        # ...and from the generic prerequisite gate.
        $r.Err | Should -Not -Match 'missing required command'
        # The remedy is the official install, in its runnable form (FR-018).
        $r.Err | Should -Match ([regex]::Escape('specify extension add --dev <path-to-spec-kit-jira> --force'))
    }

    It 'emits exactly ONE message per run (FR-016)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $r = Invoke-Degraded @('reconcile', '--json', $script:SpecWith)
        @([regex]::Matches($r.Err, 'Jira mirror skipped')).Count | Should -Be 1
        @([regex]::Matches($r.Err, 'WARNING:')).Count | Should -Be 0
    }

    It 'emits exactly one WARNING naming the true cause in hook context (FR-016, FR-017)' {
        $env:SPEC_KIT_JIRA_BASE_URL = 'http://127.0.0.1:1'
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        # Credentials must RESOLVE for the run to reach the apply step at all;
        # this case is about the mirror failing, not about it being unconfigured.
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        # This test is about hook-context WARNING behaviour on a network
        # failure, not the config-resolved binding ($script:MdWork has none) —
        # bypass it with a minimal override supplying the issue type the
        # assembly guard needs.
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10004"}'
        $r = Invoke-Degraded @('reconcile', '--json', $script:SpecWith)
        $r.ExitCode | Should -Be 0
        @([regex]::Matches($r.Err, 'WARNING:')).Count | Should -Be 1
        $r.Err | Should -Match 'Jira mirror not completed'
        $r.Err | Should -Match 'This spec-kit command completed normally'
        # It names only commands runnable as spelled — never the removed flag.
        $r.Err | Should -Not -Match 'repair-hooks'
        $r.Err | Should -Match ([regex]::Escape('/speckit.jira.config'))
    }

    It 'says NOTHING for a disabled event — not even that it was skipped (FR-020)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_plan' -ConfigDir $env:JIRA_CONFIG_DIR
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        $r = Invoke-Degraded @('reconcile', '--json', $script:SpecWith)
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeNullOrEmpty
        $r.Err | Should -BeNullOrEmpty
    }
}
