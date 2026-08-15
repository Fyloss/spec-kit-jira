# T094/T095 [027, US3] — SC-002: after seeding and binding, the NEXT FULL
# reconcile creates exactly the unpinned user stories under the
# already-adopted parent. Verification, not new production code — mirror of
# tests/bash/commands/test_seed_reconcile.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing-invoices'
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '2222222222222222'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-ReconcileCaptured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }
}

Describe 'SC-002: reconcile after seed-binding' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'creates exactly the remaining unpinned story, under the adopted parent' {
        $lines = @(
            '# Feature', '',
            '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->', '',
            '### User Story 1 - Accept a partial payment (Priority: P1)',
            '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->', '',
            'Body one.', '',
            '### User Story 2 - A brand new story the operator added (Priority: P1)', '',
            'Body two, no marker at all.'
        )
        Set-Content -NoNewline -LiteralPath $script:Spec -Value (($lines -join "`n") + "`n")

        $issues = @{
            'COMP-1'  = @{ summary = 'Billing invoices'; issuetype = @{ name = 'Epic' }; project = @{ key = 'COMP' }; properties = @{ 'spec-kit-jira' = @{ origin = 'human'; role = 'parent'; repo = 'acme/app'; spec_slug = '001-billing-invoices' } } }
            'COMP-11' = @{ summary = 'Accept a partial payment'; issuetype = @{ name = 'Story' }; project = @{ key = 'COMP' }; properties = @{ 'spec-kit-jira' = @{ origin = 'human'; role = 'story'; story = '3333333333333333'; repo = 'acme/app'; spec_slug = '001-billing-invoices' } } }
        }
        $cfgJson = (@{ projects = @{ COMP = 'company' }; issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r = Invoke-ReconcileCaptured @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        $out = $r.Out.Trim() | ConvertFrom-Json
        $out.counts.created | Should -Be 1

        $calls = @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ })
        ($calls -eq 'POST /rest/api/3/issue').Count | Should -Be 1
        ($calls -eq 'PUT /rest/api/3/issue/COMP-1').Count | Should -Be 1
    }
}
