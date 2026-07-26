# T043 [US1] — The config run reports three effects separately (FR-054).
# Mirror of tests/bash/commands/test_config_three_effects.bats. A single config
# run has three effects — discovery, hook registration, README-block management —
# each reported SEPARATELY. At this phase only discovery performs its write; the
# hooks/README effects are wired in later increments (T085, T065). This asserts
# the summary STRUCTURE: all three effects appear as distinct, named sections.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $script:Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-config'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
}

Describe 'Config three-effect reporting' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $M
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'reports discovery, hooks, and readme effects separately in --json' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--json')) }
        finally { [Console]::SetOut($orig) }
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        # All effects are present as distinct, named sections (002 adds gitignore).
        ($obj.effects.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'discovery,gitignore,hooks,readme'
        $obj.effects.discovery.status | Should -Be 'written'
        $obj.effects.hooks.status | Should -Not -BeNullOrEmpty
        $obj.effects.readme.status | Should -Not -BeNullOrEmpty
        $obj.effects.gitignore.status | Should -Not -BeNullOrEmpty
    }

    It 'names each of the three effects in the prose summary' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config')) }
        finally { [Console]::SetOut($orig) }
        $text = $sw.ToString()
        $text | Should -Match 'discovery'
        $text | Should -Match 'hooks'
        $text | Should -Match 'readme'
    }
}
