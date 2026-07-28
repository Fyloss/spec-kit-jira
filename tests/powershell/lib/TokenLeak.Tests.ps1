# T092 — Dedicated SC-007 leak test (ELIMINATORY NFR-3), PowerShell side. Mirror of
# tests/bash/lib/test_token_leak.bats. Drives the full dispatcher at maximum
# verbosity (-Verbose) as a child process, folding every stream into one capture,
# and asserts the resolved token never appears anywhere.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $script:Entry = Join-Path $Root 'scripts/powershell/spec-kit-jira.ps1'
    $script:MockDir = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
}

Describe 'Credential leak guard (SC-007)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        $script:Spec = Join-Path $Work 'spec.md'
        @(
            '# Feature Specification: Leak Guard', '', 'A spec that mirrors to Jira.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a user', '- **When** they act', '- **Then** it works'
        ) -join "`n" | Set-Content -LiteralPath $Spec -NoNewline
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ0123456789'
        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'PROJ'
        $script:Mock = $null
    }
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'never surfaces the token in a full reconcile at max verbosity (SC-007)' {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $pwshPath = (Get-Process -Id $PID).Path
        $out = & $pwshPath -NoProfile -File $Entry reconcile --verbose --json $Spec *>&1 | Out-String
        $out | Should -Not -Match 'RAWSECRETXYZ0123456789'
    }
}

Describe 'adopt at maximum verbosity (003 T143, FR-025, NFR-3)' {
    BeforeEach {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:AdoptEntry = Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1'
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        Copy-Item -Recurse -Force -Path (Join-Path $script:Root 'tests/conformance/fixtures/repo-with-adoption/*') -Destination $script:Work
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ0123456789'
        $env:JIRA_NO_SLEEP = '1'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $script:Mock = $null
    }
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock; $script:Mock = $null }
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    BeforeAll {
        $script:Corpus = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
  "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
  "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
  "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
  "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
  "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
  "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}}
'@
        $script:Ambiguous = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-8":{"labels":["speckit-adopt:004-billing-export"]},
  "ADO-9":{"labels":["speckit-adopt:004-billing-export"]}}}
'@
        function Invoke-AdoptCaptured {
            param([string[]] $AdoptArgs)
            $pwshPath = (Get-Process -Id $PID).Path
            Push-Location $script:Work
            try { return (& $pwshPath -NoProfile -File $script:AdoptEntry adopt @AdoptArgs *>&1 | Out-String) }
            finally { Pop-Location }
        }
    }

    It 'never surfaces the token in a full adopt at max verbosity' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Corpus
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $out = Invoke-AdoptCaptured @('--yes', '--verbose', '--json')
        $out | Should -Not -Match 'RAWSECRETXYZ0123456789'
    }

    It 'never surfaces the site host in adopt output at any verbosity (FR-025)' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Corpus
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $out = Invoke-AdoptCaptured @('--yes', '--verbose', '--json')
        $out | Should -Not -Match '127\.0\.0\.1'
    }

    It 'keeps the prose output free of any credential or host too' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Corpus
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $out = Invoke-AdoptCaptured @('--dry-run', '--verbose')
        $out | Should -BeLike '*Adoption plan*'
        $out | Should -Not -Match 'RAWSECRETXYZ0123456789'
        $out | Should -Not -Match '127\.0\.0\.1'
        $out | Should -Not -Match 'user@example\.com'
    }

    It 'keeps a REFUSAL message free of any credential or host (FR-025)' {
        # Refusal messages name spec folders and issue keys — and nothing else.
        $script:Mock = Start-JiraMock -ConfigJson $script:Ambiguous
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $out = Invoke-AdoptCaptured @('--yes', '--verbose', '--json')
        $out | Should -BeLike '*several-candidates*'
        $out | Should -Not -Match 'RAWSECRETXYZ0123456789'
        $out | Should -Not -Match '127\.0\.0\.1'
    }
}
