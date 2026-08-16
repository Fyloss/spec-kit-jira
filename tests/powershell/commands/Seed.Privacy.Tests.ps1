# T077 [027] — FR-065: the two-tier pre-write privacy guard over content
# seeded from a named Jira issue. Pester twin of test_seed_privacy.bats.
# One fixture per tier — moment 1 (commands/Feature.psm1).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Feature.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Seed.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/SeedState.psm1') -Force
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

Describe 'T158: FR-065 tier 2 — the scan over spec.md on the Invoke-JiraSeed binding path' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = $null
        Remove-Item -LiteralPath 'Env:\SPEC_KIT_JIRA_ALLOWLIST' -ErrorAction SilentlyContinue
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:\JIRA_CONFIG_DIR' -ErrorAction SilentlyContinue
    }

    It 'a known coordinate in spec.md as it now stands BLOCKs seed --confirm, exit 9, zero writes' {
        $featureDir = Join-Path $Work 'specs/001-add-payment-webhooks'
        New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
        $spec = Join-Path $featureDir 'spec.md'
        # A poisoned body — as if the operator pasted a credential into
        # spec.md after the drafting agent wrote it, before confirming.
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - A (Priority: P1)`n<!-- speckit-jira pin=PROJ-11 -->`n`nSee token ATATTxxxxSECRETxxxx for access.`n"
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' -PlanDigest ''
        Save-JiraSeedState -SpecPath $spec -DocumentJson $doc

        $cfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $rc = Invoke-JiraSeed -Arguments @($spec, '--confirm', '--json')
        $rc | Should -Be 9
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
        # Zero writes: the pinning marker is still `pin=`, never consumed,
        # and the seed record survives (a BLOCK is not a binding).
        (Get-Content -Raw -LiteralPath $spec) | Should -Match 'pin=PROJ-11'
        Read-JiraSeedState -SpecPath $spec | Should -Not -BeNullOrEmpty
    }
}
