# T032 [US3] — The diagnostics catalogue. Pester twin of
# tests/bash/commands/test_reconcile_diagnostics.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out; $oe = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($se)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }

    function Assert-NoLeak {
        param([string] $Text)
        # FR-018: no diagnostic ever names the site host or a credential shape.
        $Text | Should -Not -Match ([regex]::Escape((([Uri]$script:M.BaseUrl).Authority)))
        $Text | Should -Not -Match 'ATATT'
        $Text | Should -Not -Match '@'
    }

    function Assert-FaultProperties {
        param([string] $Needle)
        # (1) Direct invocation: exit 4, the named cause appears, zero requests.
        $r = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:Spec)
        $r.ExitCode | Should -Be 4
        ($r.Out + $r.Err) | Should -Match ([regex]::Escape($Needle))
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
        Assert-NoLeak -Text ($r.Out + $r.Err)

        # (2) Hook context: exit 0, exactly one occurrence, zero requests.
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        try {
            $r2 = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:Spec)
            $r2.ExitCode | Should -Be 0
            @([regex]::Matches(($r2.Out + $r2.Err), [regex]::Escape($Needle))).Count | Should -Be 1
            @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
            Assert-NoLeak -Text ($r2.Out + $r2.Err)
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue }

        # (3) --verbose changes nothing about the leak guarantee (FR-018, "at any verbosity").
        $r3 = Invoke-Captured @('reconcile', '--dry-run', '--json', '--verbose', $script:Spec)
        Assert-NoLeak -Text ($r3.Out + $r3.Err)
    }
}

Describe 'Diagnostics catalogue (US3)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue

        $script:Spec = Join-Path $script:Work 'spec.md'
        @(
            '# Feature Specification: Diagnostics', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a signed-in user', '- **When** they open the board', '- **Then** the widgets load'
        ) -join "`n" | Set-Content -LiteralPath $script:Spec -NoNewline

        $script:M = Start-JiraMock -ConfigPath (New-Item -ItemType File -Path (Join-Path $script:Work 'mock.json') -Value '{}' -Force).FullName
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'routing-unresolved: no rule and no routing_default (contract cause 2)' {
        # routing_default is schema-mandatory on the committed team layer, so
        # this state is reached the way a real repository would reach it: the
        # machine layer's own override nulls it out (schema-valid on both
        # layers — neither layer's own routing_default is invalid, only the
        # merged result is empty).
        @'
projects:
  - key: COMP
    style: company_managed
routing_default: COMP
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -NoNewline
        @'
overrides:
  routing_default: null
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml') -NoNewline
        # 033: the needle changed with the message. It used to end "add
        # routing_default to config.yml", which C6.5 now forbids as the SOLE
        # remedy — a repository may have declined that key deliberately, and
        # three other ranks could equally have placed this specification.
        Assert-FaultProperties -Needle 'routing could not be resolved'
    }

    It 'placeholder-binding: the resolved key equals the shipped placeholder (contract cause 3)' {
        @'
projects:
  - key: PROJ
    style: company_managed
routing_default: PROJ
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -NoNewline
        Assert-FaultProperties -Needle 'placeholder'
    }

    It "unknown-project: a routing rule names a project projects[] does not declare (contract cause 4)" {
        @'
projects:
  - key: COMP
    style: company_managed
routing_default: NOPE
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -NoNewline
        Assert-FaultProperties -Needle 'not declared'
    }

    It 'project-not-bound: the resolved project has no resolved_ids entry (contract cause 5)' {
        @'
projects:
  - key: COMP
    style: company_managed
routing_default: COMP
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -NoNewline
        @'
resolved_ids:
  OTHERPROJ:
    style: company_managed
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml') -NoNewline
        Assert-FaultProperties -Needle 'has not been bound yet'
    }

    It 'an unreadable local binding fails closed with zero writes, not reported as unbound (007 FR-010, R7 case 9)' {
        @'
projects:
  - key: COMP
    style: company_managed
routing_default: COMP
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -NoNewline
        @'
resolved_ids:
  COMP:
    this line has no delimiter
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml') -NoNewline
        $r = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:Spec)
        $r.ExitCode | Should -Be 4
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
        ($r.Out + $r.Err) | Should -Not -Match 'has not been bound yet'
        ($r.Out + $r.Err) | Should -Not -Match 'not bound to a Jira project yet'
        ($r.Out + $r.Err) | Should -Match 'cannot parse this line as a mapping entry'
    }
}
