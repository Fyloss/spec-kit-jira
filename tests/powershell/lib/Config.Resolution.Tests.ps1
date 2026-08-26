# 031, T026 — Pester twin of tests/bash/lib/test_config.bats' T023/T024 and
# tests/bash/commands/test_feature.bats' T025: the configuration directory is
# found from the repository, not the shell (contract C1.1/C1.2/C1.4).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    # Feature.psm1 imports Config.psm1 internally with -Force — importing it
    # here a SECOND time, LAST, is load-bearing: a sink module's own -Force
    # re-import can clobber the caller's earlier one (see the identical note
    # in AGENTS.md's Windows-portability lessons), so Config.psm1 is imported
    # again after Feature.psm1 to make sure ITS export list — including
    # Resolve-JiraConfigDir, which this file calls directly — is what
    # actually lands in this session.
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Feature.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Cli.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force

    function New-TempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
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

Describe 'Resolve-JiraConfigDir' {
    BeforeEach {
        Remove-Item -LiteralPath 'Env:\JIRA_CONFIG_DIR' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:\SPECIFY_INIT_DIR' -ErrorAction SilentlyContinue
        $script:OrigLocation = Get-Location
    }
    AfterEach {
        Set-Location $OrigLocation
        Remove-Item -LiteralPath 'Env:\JIRA_CONFIG_DIR' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:\SPECIFY_INIT_DIR' -ErrorAction SilentlyContinue
    }

    It 'T023: resolves in order JIRA_CONFIG_DIR, then SPECIFY_INIT_DIR, then the nearest ancestor carrying .specify/ (C1.1, FR-014, FR-015)' {
        $rootA = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $rootA '.specify') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $rootA 'sub') -Force | Out-Null
        $rootB = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $rootB '.specify') -Force | Out-Null
        $explicit = New-TempDir

        Set-Location (Join-Path $rootA 'sub')
        Resolve-JiraConfigDir | Should -Be "$rootA/.specify/jira"

        $env:SPECIFY_INIT_DIR = $rootB
        Resolve-JiraConfigDir | Should -Be "$rootB/.specify/jira"

        $env:JIRA_CONFIG_DIR = $explicit
        Resolve-JiraConfigDir | Should -Be $explicit

        Remove-Item -Recurse -Force $rootA, $rootB, $explicit -ErrorAction SilentlyContinue
    }

    It 'T024: the walk goes upward only and stops at the filesystem root (C1.2)' {
        $root = New-TempDir
        $leaf = Join-Path $root 'a/b/c'
        New-Item -ItemType Directory -Path $leaf -Force | Out-Null
        # A decoy .specify/ only reachable by DESCENDING — proves the walk
        # never descends, only ever goes up.
        New-Item -ItemType Directory -Path (Join-Path $leaf 'decoy/.specify') -Force | Out-Null

        Set-Location $leaf
        Resolve-JiraConfigDir | Should -BeNullOrEmpty

        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }

    It 'T025: no ancestor carries .specify/ ⇒ a report naming the directory walked from, exit 0, no fallback (C1.4, FR-008; AS3)' {
        $isolated = New-TempDir
        Set-Location $isolated
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out.Trim() | Should -Be '{"active":false}'
        $r.Err | Should -Match 'no project found'
        $r.Err | Should -Match ([regex]::Escape($isolated))
        Remove-Item -Recurse -Force $isolated -ErrorAction SilentlyContinue
    }
}
