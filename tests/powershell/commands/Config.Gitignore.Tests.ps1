# T049 [US3] — The config ceremony's gitignore effect (FR-019). Pester twin of
# tests/bash/commands/test_config_gitignore.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Config.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Invoke-ConfigCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $code = Invoke-JiraConfig -Arguments $CmdArgs }
        finally { [Console]::SetOut($orig) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }
}

Describe 'Config gitignore effect' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $lines = @('projects:', '  - key: TEAM', '    epic_strategy: per_repo', '    task_strategy: subtask', 'routing_default: TEAM')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, '{"projects":{"TEAM":"team"}}')
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $script:GitignorePath = Join-Path $Work '.gitignore'
    }
    AfterEach {
        Stop-JiraMock -Mock $M
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'creates an absent .gitignore with the three managed lines (FR-019)' {
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).effects.gitignore.status | Should -Be 'created'
        $content = Get-Content -LiteralPath $GitignorePath
        $content | Should -Contain '.specify/jira/personal.yml'
        $content | Should -Contain '.specify/jira/config.local.yml'
        $content | Should -Contain '.specify/jira/.env'
    }

    It 'appends only the missing lines (written)' {
        [System.IO.File]::WriteAllText($GitignorePath, "node_modules/`n.specify/jira/config.local.yml`n")
        $r = Invoke-ConfigCaptured @('config', '--json')
        ($r.Out.Trim() | ConvertFrom-Json).effects.gitignore.status | Should -Be 'written'
        $content = Get-Content -LiteralPath $GitignorePath
        $content | Should -Contain 'node_modules/'
        @($content | Where-Object { $_ -ceq '.specify/jira/config.local.yml' }).Count | Should -Be 1
        $content | Should -Contain '.specify/jira/personal.yml'
    }

    It 'is idempotent: second run unchanged with a byte-identical file' {
        [void](Invoke-ConfigCaptured @('config', '--json'))
        $before = [System.IO.File]::ReadAllBytes($GitignorePath)
        $r = Invoke-ConfigCaptured @('config', '--json')
        ($r.Out.Trim() | ConvertFrom-Json).effects.gitignore.status | Should -Be 'unchanged'
        [System.IO.File]::ReadAllBytes($GitignorePath) | Should -Be $before
    }

    It 'computes the status in --dry-run without touching the file' {
        $r = Invoke-ConfigCaptured @('config', '--dry-run', '--json')
        ($r.Out.Trim() | ConvertFrom-Json).effects.gitignore.status | Should -Be 'created'
        (Test-Path $GitignorePath) | Should -BeFalse
    }

    It 'derives the repo root from a single-component JIRA_CONFIG_DIR without throwing (T092)' {
        # Split-Path -Parent (Split-Path -Parent 'jira') throws on the empty
        # inner result; the bash twin (dirname of dirname) lands on '.'.
        Push-Location $Work
        $origCwd = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $Work
        try {
            New-Item -ItemType Directory -Path (Join-Path $Work 'jira') -Force | Out-Null
            Copy-Item (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') (Join-Path $Work 'jira/config.yml')
            $env:JIRA_CONFIG_DIR = 'jira'
            $r = Invoke-ConfigCaptured @('config', '--json')
            $r.ExitCode | Should -Be 0
            ($r.Out.Trim() | ConvertFrom-Json).effects.gitignore.status | Should -Be 'created'
            Test-Path -LiteralPath $GitignorePath | Should -BeTrue
        }
        finally {
            Pop-Location
            [System.Environment]::CurrentDirectory = $origCwd
        }
    }
}
