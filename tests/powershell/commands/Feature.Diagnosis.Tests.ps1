# 031, T014 — Pester twin of tests/bash/commands/test_feature.bats' Phase 3
# (US1) tests: a broken configuration announces itself.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Feature.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Cli.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    # Feature.psm1 imports Config.psm1 as a NESTED module — its exports are
    # visible to Feature.psm1's own code but not automatically re-exported to
    # this session. Imported again here, LAST, so Resolve-JiraConnection
    # (called directly below, T040) is actually reachable.
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Start-TestMock {
        param([string]$ConfigJson)
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, $ConfigJson)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }

    function Invoke-FeatureCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $code = Invoke-JiraFeature -Arguments $CmdArgs }
        finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'Feature command — a broken configuration announces itself (031, US1)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = $null
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:\JIRA_CONFIG_DIR' -ErrorAction SilentlyContinue
    }

    It 'T010: a malformed config.yml is reported with file and located reason, exit 0, zero Jira calls (C2.1, C3.1, C3.2; AS1)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: IJT`nteams:`nthis line has no delimiter`n")
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeFalse
        # '/'-concatenation, not Join-Path: mirrors what Config.psm1 actually
        # emits — Join-Path renormalises to the host's own separator and
        # would pass even if the code regressed to a mixed-separator report
        # (code review, PR #55; bash's own twin test does the same literal
        # "${JIRA_CONFIG_DIR}/config.yml" match).
        $r.Err | Should -Match ([regex]::Escape("$env:JIRA_CONFIG_DIR/config.yml"))
        $r.Err | Should -Match 'cannot parse this line'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'T011: a schema-violating config.yml names the offending key, never the bare word "invalid" (C2.1; AS2)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: IJT`nteams: []`nunknown_top_level_key: true`n")
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeFalse
        $r.Err | Should -Match 'unknown top-level key: unknown_top_level_key'
        $r.Err | Should -Not -Match '^invalid$'
    }

    It 'T013: an EMPTY config.yml and an EMPTY personal.yml stay silent, never reported as load failures (C2.5)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), '')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), '')
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out.Trim() | Should -Be '{"active":false}'
        $r.Err | Should -BeNullOrEmpty
    }

    It 'T022: --dry-run output and exit code are unchanged on the config-unloadable branch (Principle XI)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: IJT`nteams:`nthis line has no delimiter`n")
        $r = Invoke-FeatureCaptured @('feature', '--json', '--dry-run', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeFalse
    }

    It 'T022: --dry-run output and exit code are unchanged on the personal-unloadable branch (Principle XI)' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: IJT`nrouting_default: IJT`nteams:`n  - id: ijt`n    project: IJT`n")
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: Not_Valid`n")
        $r = Invoke-FeatureCaptured @('feature', '--json', '--dry-run', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeFalse
    }

    It 'T039: a credential-shaped value is reported by its located reason WITHOUT the value appearing, even at --verbose (Principle IV, C2.6)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: IJT`nteams: []`nbase_url: `"ATATT3xFfGF0secrettoken`"`n")
        $r = Invoke-FeatureCaptured @('feature', '--json', '--verbose', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeFalse
        $r.Err | Should -Not -Match 'ATATT3xFfGF0secrettoken'
    }

    It 'T040: an unloadable personal.yml still fails closed on a path that WOULD reach the network (C3.4 — C6.2 survives)' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: Not_Valid`n")
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $rc = Resolve-JiraConnection -ConfigDir $env:JIRA_CONFIG_DIR
        $rc | Should -Be 4
    }
}
