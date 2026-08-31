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
        # Re-import -Force: resets Credentials.psm1's $script:-scoped credential
        # cache (021, US3) via Config.psm1's own cascade — Pester runs every It
        # in one process, so module scope has no per-test isolation otherwise.
        Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Config.psm1') -Force
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $lines = @('projects:', '  - key: TEAM', 'routing_default: TEAM')
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

    It 'T062 — reports gitignore and personal with their TRUE status (030, research R5)' {
        # Reordered ahead of the degraded early return: the fresh-setup case
        # IS degraded mode, and it is exactly when personal.yml must be
        # created and covered by the ignore rule (research R5) — reporting
        # either "skipped" would be a lie about work that was in fact
        # performed.
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.effects.gitignore.status | Should -Be 'created'
        $obj.effects.personal.status | Should -Be 'created'
        Test-Path (Join-Path $Work '.gitignore') | Should -BeTrue
        Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'personal.yml') | Should -BeTrue
    }

    It 'surfaces the proposals and rerun guidance in degraded prose (T093)' {
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match '  gitignore: created'
        $r.Out | Should -Match '  personal: created'
        $r.Out | Should -Match 'Provisional teams: ijt, wex'
        $r.Out | Should -Match ([regex]::Escape('Rerun: define SPEC_KIT_JIRA_BASE_URL, then re-run: .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh config (on Windows: .specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1 config)'))
    }
}

Describe 'Degraded causes are told apart (T047, 003 US5)' {
    # The reported message named one cause ("CLI not installed") that was not the
    # real one and could not have been — this extension is not delivered as a
    # machine-wide CLI. FR-017 requires the message to name the TRUE cause. In
    # every degraded state the host command succeeds (SC-006): a ceremony that
    # cannot reach Jira is a report, not a failure.
    BeforeEach {
        # Re-import -Force: resets Credentials.psm1's $script:-scoped credential
        # cache (021, US3) via Config.psm1's own cascade — Pester runs every It
        # in one process, so module scope has no per-test isolation otherwise.
        Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Config.psm1') -Force
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $lines = @('projects:', '  - key: TEAM', 'routing_default: TEAM')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
    }
    AfterEach {
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
        $guidance | Should -Match ([regex]::Escape('.specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh config'))
        $guidance | Should -Match ([regex]::Escape('.specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1 config'))
        $guidance | Should -Not -Match '(^|[^/])spec-kit-jira\s+config'
    }


    It 'T053 [011] — degraded mode asks no field-default question and writes nothing to config.yml (FR-009)' {
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $before = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')
        $r = Invoke-ConfigCaptured @('config', '--field-default', 'TEAM=Epic=Business Owner=Platform Team', '--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'field_defaults'
        (Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')) | Should -Be $before
    }

    It '015 T034 — a degraded-mode ceremony with no Jira read performs no allowed-value check at all, and stays silent about it' {
        # No Jira read means no defaultable_fields is ever discovered, so rule
        # A3 (contract §6.2) excludes every entry from examination — a
        # recorded value that WOULD be outside_allowed against a real
        # project's metadata is not checked here, and the run neither
        # refuses nor mentions the field.
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $path = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        Add-Content -LiteralPath $path -Value "field_defaults:`n  TEAM:`n    ask: true`n    Epic:`n      Region: NotAnAllowedValue"
        $before = Get-Content -Raw -LiteralPath $path
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'must be one of'
        $r.Out | Should -Not -Match 'NotAnAllowedValue'
        (Get-Content -Raw -LiteralPath $path) | Should -Be $before
    }
}

# =============================================================================
# T044c [030, US1] — the ceremony's degraded trigger splits the credential
# reason (contracts/credential-resolution.md C6.4-C6.6, FR-038)
# =============================================================================

Describe 'T044c — the degraded trigger splits the credential reason' {
    BeforeEach {
        Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Config.psm1') -Force
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $lines = @('projects:', '  - key: TEAM', 'routing_default: TEAM')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_PAT_COMMAND = $null
    }
    AfterEach {
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
        $env:JIRA_PAT_COMMAND = $null
    }

    It 'T044c — with no JIRA_PAT_COMMAND declared, degraded mode is silent about the rung (C6.4)' {
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'JIRA_API_TOKEN'
        $r.Err | Should -Not -Match 'JIRA_PAT_COMMAND'
    }

    It 'T044c — a declared and failing JIRA_PAT_COMMAND reports its reason on stderr and in detail, exit 0 (C6.5)' {
        $env:JIRA_PAT_COMMAND = Join-Path $Work 'nonexistent-pat-helper'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $r.Err | Should -Match 'JIRA_PAT_COMMAND'
        $r.Err | Should -Match 'could not be executed'
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.effects.personal.status | Should -Not -BeNullOrEmpty
    }
}

Describe '034 — the ceremony says nothing about the hook registry (FR-002, SC-001)' {
    # Mirror of the 034 block in tests/bash/commands/test_config_degraded.bats.
    #
    # The three states are asserted together because the claim is about their
    # EQUALITY rather than about any one of them: a correct registry, an absent
    # one and a malformed one must produce summaries identical in hook-related
    # content, and that content must be none.
    #
    # The malformed case is the load-bearing one. Before 034 the extension
    # parsed this file, so unparseable bytes produced an `unreadable` verdict.
    # A file the extension never opens cannot do that. If this case ever
    # diverges from the other two, something is still reading the registry.
    BeforeAll {
        # Pester 5 executes It blocks in a scope that sees only helpers defined
        # in BeforeAll — one declared in the Describe body is invisible there,
        # and fails at run time with CommandNotFoundException.
        function Set-Registry {
            param([Parameter(Mandatory)] [string] $State, [Parameter(Mandatory)] [string] $Path)
            switch ($State) {
                'absent' { Remove-Item -LiteralPath $Path -ErrorAction SilentlyContinue }
                'malformed' { [System.IO.File]::WriteAllText($Path, "hooks:`n  - [unclosed`n`t`tbroken`n") }
                'correct' {
                    $sb = [System.Text.StringBuilder]::new()
                    [void]$sb.AppendLine('hooks:')
                    foreach ($e in @('before_specify', 'after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_implement', 'after_analyze')) {
                        [void]$sb.AppendLine("  ${e}:")
                        [void]$sb.AppendLine('  - extension: jira-mirror')
                        [void]$sb.AppendLine('    command: speckit.jira-mirror.reconcile')
                        [void]$sb.AppendLine('    enabled: true')
                        [void]$sb.AppendLine('    optional: false')
                    }
                    [System.IO.File]::WriteAllText($Path, $sb.ToString())
                }
            }
        }
    }

    BeforeEach {
        Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Config.psm1') -Force
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $lines = @('projects:', '  - key: TEAM', 'routing_default: TEAM')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        Push-Location $Work
        git init -q -b main
        git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        Remove-Item Env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }
    AfterEach {
        Pop-Location
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'gives identical hook content — none — for a correct, absent and malformed registry (SC-001)' {
        $reg = Join-Path $Work '.specify/extensions.yml'
        $seen = @()
        $codes = @()
        foreach ($state in @('correct', 'absent', 'malformed')) {
            Set-Registry -State $state -Path $reg
            $r = Invoke-ConfigCaptured @('config', '--json')
            $obj = $r.Out.Trim() | ConvertFrom-Json
            # Each summary individually carries no registry claim (US1 AC1-AC3).
            $obj.PSObject.Properties.Name | Should -Not -Contain 'hook_health'
            $obj.effects.PSObject.Properties.Name | Should -Not -Contain 'hooks'
            $seen += ($obj.effects.PSObject.Properties.Name | Sort-Object) -join ','
            $codes += $r.ExitCode
        }
        # ...and the three agree with each other, which is the actual SC-001 claim.
        $seen[0] | Should -BeExactly $seen[1]
        $seen[1] | Should -BeExactly $seen[2]
        $codes[0] | Should -Be $codes[1]
        $codes[1] | Should -Be $codes[2]
    }
}
