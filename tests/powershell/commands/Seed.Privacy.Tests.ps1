# T077 [027] — FR-065: the two-tier pre-write privacy guard over content
# seeded from a named Jira issue. Pester twin of test_seed_privacy.bats.
# One fixture per tier — moment 1 (commands/Feature.psm1).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Feature.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Write-PrivacySeedConfig {
        $lines = @(
            'projects:', '  - key: PROJ', '    hierarchy:', '      specification: Epic', '      story: Story',
            'routing_default: PROJ', 'teams:',
            '  - id: proj', '    project: PROJ', '    folder_prefix: "proj-"', '    branch_pattern: "proj-<ID>/<FEATURE_NAME>"'
        )
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: proj`n")
    }

    function Start-PrivacyMock([string]$Description) {
        $issues = @{
            'PROJ-11' = @{ summary = 'Accept a partial payment'; description = $Description; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        $cfgJson = (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, $cfgJson)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }

    function Invoke-FeatureCaptured3 {
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

Describe 'FR-065 privacy guard over seeded content' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        Write-PrivacySeedConfig
        $script:M = $null
        Remove-Item -LiteralPath 'Env:\SPEC_KIT_JIRA_ALLOWLIST' -ErrorAction SilentlyContinue
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:\JIRA_CONFIG_DIR' -ErrorAction SilentlyContinue
    }

    It 'a known coordinate (an ATATT token) in a seeded description BLOCKs, exit 9' {
        Start-PrivacyMock 'See token ATATTxxxxSECRETxxxx for access'
        $r = Invoke-FeatureCaptured3 @('feature', '--json', '--story', 'PROJ-11', 'invoice export')
        $r.ExitCode | Should -Be 9
    }

    It 'a generic email in a seeded description WARNs without blocking' {
        Start-PrivacyMock 'Contact jane.doe@example.com for follow-up'
        $r = Invoke-FeatureCaptured3 @('feature', '--json', '--story', 'PROJ-11', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeTrue
    }

    It 'an allowlisted Confluence link in a seeded description passes silently' {
        $env:SPEC_KIT_JIRA_ALLOWLIST = '["https://acme.atlassian.net/wiki/"]'
        Start-PrivacyMock 'See https://acme.atlassian.net/wiki/spaces/X/page for detail'
        $r = Invoke-FeatureCaptured3 @('feature', '--json', '--story', 'PROJ-11', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeTrue
    }
}
