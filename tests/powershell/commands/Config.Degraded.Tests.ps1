# T024 [US2] — Degraded mode: loud, provisional, write-free (FR-008/FR-009).
# Pester twin of tests/bash/commands/test_config_degraded.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Config.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_NO_SLEEP = '1'

    function Invoke-ConfigCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $code = Invoke-JiraConfig -Arguments $CmdArgs }
        finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'Config degraded mode' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $lines = @('projects:', '  - key: TEAM', '    epic_strategy: per_repo', '    task_strategy: subtask', 'routing_default: TEAM')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        Push-Location $Work
        git init -q -b main
        git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
        git branch 'ijt-12/invoice-export'
        git branch 'wex-3/onboarding'
        git branch 'feature/unrelated'
        $script:M = $null
    }
    AfterEach {
        Pop-Location
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'degrades on a missing base URL: exit 0, one warning, provisional proposals, zero writes' {
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        @($r.Err -split "`n" | Where-Object { $_ -match '^WARNING:' }).Count | Should -Be 1
        $r.Err | Should -Match 'SPEC_KIT_JIRA_BASE_URL'
        $obj = $r.Out.Trim() | ConvertFrom-Json
        @($obj.provisional).Count | Should -Be 2
        $obj.provisional[0].team_prefix | Should -Be 'ijt'
        $obj.provisional[0].provisional | Should -BeTrue
        $obj.provisional[1].team_prefix | Should -Be 'wex'
        $obj.rerun_guidance | Should -Not -BeNullOrEmpty
        $obj.effects.discovery.status | Should -Be 'skipped'
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
        (Test-Path (Join-Path $Work '.specify/extensions.yml')) | Should -BeFalse
        (Test-Path (Join-Path $Work 'README.md')) | Should -BeFalse
    }

    It 'leaves an existing config.local.yml byte-identical (FR-009)' {
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $localf = Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml'
        [System.IO.File]::WriteAllText($localf, "site_alias: prod`n")
        $before = [System.IO.File]::ReadAllBytes($localf)
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        [System.IO.File]::ReadAllBytes($localf) | Should -Be $before
    }

    It 'never degrades on defined-but-wrong credentials: auth exit (research §4)' {
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, '{"fault":{"status":401}}')
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $env:JIRA_API_TOKEN = 'WRONGTOKEN'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 3
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
    }

    It 'performs zero Jira calls in a degraded run' {
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, '{"projects":{"TEAM":"team"}}')
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'includes gitignore: skipped in the degraded effect set (T093)' {
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).effects.gitignore.status | Should -Be 'skipped'
        Test-Path (Join-Path $Work '.gitignore') | Should -BeFalse
    }

    It 'surfaces the proposals and rerun guidance in degraded prose (T093)' {
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match '  gitignore: skipped'
        $r.Out | Should -Match 'Provisional teams: ijt, wex'
        $r.Out | Should -Match ([regex]::Escape('Rerun: define SPEC_KIT_JIRA_BASE_URL, then re-run: .specify/extensions/jira/scripts/bash/spec-kit-jira.sh config (on Windows: .specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 config)'))
    }
}

Describe 'Degraded causes are told apart (T047, 003 US5)' {
    # The reported message named one cause ("CLI not installed") that was not the
    # real one and could not have been — this extension is not delivered as a
    # machine-wide CLI. FR-017 requires the message to name the TRUE cause. In
    # every degraded state the host command succeeds (SC-006): a ceremony that
    # cannot reach Jira is a report, not a failure.
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $lines = @('projects:', '  - key: TEAM', '    epic_strategy: per_repo', '    task_strategy: subtask', 'routing_default: TEAM')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $script:Work '.specify/extensions.yml'
    }
    AfterEach {
        Remove-Item Env:\SPEC_KIT_JIRA_EXTENSIONS_YML -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'names the missing variables, never a missing CLI (FR-017)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out + $r.Err) | Should -Match 'SPEC_KIT_JIRA_BASE_URL'
        ($r.Out + $r.Err) | Should -Not -Match 'CLI not installed'
        ($r.Out + $r.Err) | Should -Not -Match 'not installed'
    }

    It 'distinguishes credentials absent from base URL absent (FR-017)' {
        $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
        Remove-Item Env:\JIRA_API_TOKEN -ErrorAction SilentlyContinue
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out + $r.Err) | Should -Match 'JIRA_API_TOKEN'
        ($r.Out + $r.Err) | Should -Not -Match 'SPEC_KIT_JIRA_BASE_URL'
    }

    It 'names both in ONE message when both are absent (FR-016, FR-017)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\JIRA_API_TOKEN -ErrorAction SilentlyContinue
        $r = Invoke-ConfigCaptured @('config', '--json')
        ($r.Out + $r.Err) | Should -Match 'SPEC_KIT_JIRA_BASE_URL, JIRA_API_TOKEN'
        @([regex]::Matches($r.Err, 'WARNING:')).Count | Should -Be 1
    }

    It 'names a runnable bridge invocation in the re-run guidance (FR-018)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $guidance = ($r.Out.Trim() | ConvertFrom-Json).rerun_guidance
        # The repository-relative per-port form, never a bare executable name.
        $guidance | Should -Match ([regex]::Escape('.specify/extensions/jira/scripts/bash/spec-kit-jira.sh config'))
        $guidance | Should -Match ([regex]::Escape('.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 config'))
        $guidance | Should -Not -Match '(^|[^/])spec-kit-jira\s+config'
    }

    It 'reports an unreadable registry as its OWN cause (T062, FR-017, FR-024)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        [System.IO.File]::WriteAllText($env:SPEC_KIT_JIRA_EXTENSIONS_YML,
            "hooks:`n  after_plan:`n   - broken`n     : : :`n", (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        # The discovery effect is skipped for the connection; the hooks effect is
        # unreadable for the file. Two causes, two reports, one run.
        $obj.effects.discovery.status | Should -BeExactly 'skipped'
        $obj.effects.hooks.status | Should -BeExactly 'unreadable'
        # It must not tell the operator to reinstall over a file it merely failed
        # to parse — the install would not fix it, and the hooks may be fine.
        $obj.effects.hooks.detail | Should -Not -Match 'specify extension add'
        $obj.effects.hooks.detail | Should -Match 'no claim is made about the hooks'
    }

    It 'names a YAML anchor as the construct that defeated the reader (T062, FR-024)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        [System.IO.File]::WriteAllText($env:SPEC_KIT_JIRA_EXTENSIONS_YML,
            "defaults: &defaults`n  enabled: true`nhooks:`n  after_plan:`n    - extension: jira`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $obj = (Invoke-ConfigCaptured @('config', '--json')).Out.Trim() | ConvertFrom-Json
        $obj.effects.hooks.status | Should -BeExactly 'unreadable'
        $obj.effects.hooks.detail | Should -Match 'anchor'
    }

    It 'leaves an unreadable registry byte-identical (FR-022, FR-023)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $broken = "hooks:`n  after_plan:`n   - broken`n     : : :`n"
        [System.IO.File]::WriteAllText($env:SPEC_KIT_JIRA_EXTENSIONS_YML, $broken, (New-Object System.Text.UTF8Encoding($false)))
        $null = Invoke-ConfigCaptured @('config', '--json')
        (Get-Content -Raw -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML) | Should -BeExactly $broken
    }
}
