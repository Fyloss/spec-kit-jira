# 031, T035 — Pester twin of tests/bash/commands/test_feature.bats' Phase 5
# (US3) tests: an operator can ask which state produced the pass-through
# (contract C4.1/C4.2).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Feature.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Cli.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
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

Describe 'Feature command — an operator can ask which state produced it (031, US3)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: IJT`nrouting_default: IJT`nteams:`n  - id: ijt`n    project: IJT`n    folder_prefix: `"ijt-`"`n    branch_pattern: `"ijt-<ID>/<FEATURE_NAME>`"`n")
        $script:M = $null
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:\JIRA_CONFIG_DIR' -ErrorAction SilentlyContinue
    }

    It 'T033: --verbose names the resolution state, the absolute path, and what would change it' {
        $r = Invoke-FeatureCaptured @('feature', '--json', '--verbose', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Err | Should -Match 'resolution state: no-personal-file'
        $r.Err | Should -Match ([regex]::Escape("path consulted: $($env:JIRA_CONFIG_DIR)"))
    }

    It 'T034: WITHOUT --verbose, default and --json output carry no new line and no new key (C4.2, FR-011)' {
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.Out.Trim() | Should -Be '{"active":false}'
        $r.Err | Should -BeNullOrEmpty

        $r2 = Invoke-FeatureCaptured @('feature', 'invoice export')
        $r2.Out.Trim() | Should -Be 'Feature: inactive'
    }

    It 'T038: --verbose introduces no new argument surface — --dry-run/--json still parse exactly as before' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: ijt`n")
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', '--json', '--verbose', '--dry-run', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeTrue
    }
}
