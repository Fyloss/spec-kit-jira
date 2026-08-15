# T099/T100 [027, US6] — quickstart.md Scenario 2, FR-009/FR-010/SC-009: the
# load-bearing one-way-read guarantee. Mirror of test_seed_oneway.bats.

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
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-ReconcileCaptured2 {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }
}

Describe 'Scenario 2 (FR-009/FR-010/SC-009): the one-way read' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'editing a named issue Jira-side, then a full reconcile, leaves spec.md byte-identical' {
        $lines = @(
            '# Feature', '',
            '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->', '',
            '### User Story 1 - Accept a partial payment (Priority: P1)',
            '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->', '',
            'Body one, as the human wrote it.'
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

        $before = Get-Content -Raw -LiteralPath $script:Spec

        Invoke-RestMethod -Uri "$($M.BaseUrl)/rest/api/3/issue/COMP-1" -Method Put -ContentType 'application/json' `
            -Body (@{ fields = @{ summary = 'RENAMED after seeding'; description = 'Completely rewritten Jira-side.' } } | ConvertTo-Json -Depth 10) | Out-Null
        Invoke-RestMethod -Uri "$($M.BaseUrl)/rest/api/3/issue/COMP-11" -Method Put -ContentType 'application/json' `
            -Body (@{ fields = @{ summary = 'RENAMED after seeding too'; description = 'Also completely rewritten Jira-side.' } } | ConvertTo-Json -Depth 10) | Out-Null

        $r = Invoke-ReconcileCaptured2 @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0

        $after = Get-Content -Raw -LiteralPath $script:Spec
        $after | Should -Be $before
    }

    It 'T101 (FR-030): the managed boundary marker is appended BELOW a human''s existing description on the first reconcile after binding' {
        $lines = @(
            '# Feature', '',
            '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->', '',
            '### User Story 1 - Accept a partial payment (Priority: P1)',
            '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->', '',
            'Mirrored body.'
        )
        Set-Content -NoNewline -LiteralPath $script:Spec -Value (($lines -join "`n") + "`n")

        $humanDesc = @{ type = 'doc'; version = 1; content = @(@{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'A HUMAN wrote this before the ceremony ever ran.' }) }) }
        $issues = @{
            'COMP-1'  = @{ summary = 'Billing invoices'; issuetype = @{ name = 'Epic' }; project = @{ key = 'COMP' }; properties = @{ 'spec-kit-jira' = @{ origin = 'human'; role = 'parent'; repo = 'acme/app'; spec_slug = '001-billing-invoices' } } }
            'COMP-11' = @{ summary = 'Accept a partial payment'; description = $humanDesc; issuetype = @{ name = 'Story' }; project = @{ key = 'COMP' }; properties = @{ 'spec-kit-jira' = @{ origin = 'human'; role = 'story'; story = '3333333333333333'; repo = 'acme/app'; spec_slug = '001-billing-invoices' } } }
        }
        $cfgJson = (@{ projects = @{ COMP = 'company' }; issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r = Invoke-ReconcileCaptured2 @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0

        $desc = (Invoke-RestMethod -Uri "$($M.BaseUrl)/rest/api/3/issue/COMP-11").fields.description
        $texts = @($desc.content | ForEach-Object { $_.content[0].text })
        $humanIdx = [array]::IndexOf($texts, 'A HUMAN wrote this before the ceremony ever ran.')
        $markerArrayIdx = [array]::FindIndex([string[]]$texts, [Predicate[string]] { param($t) $t -match 'Synced from spec-kit' })
        $humanIdx | Should -BeGreaterOrEqual 0
        $markerArrayIdx | Should -BeGreaterOrEqual 0
        $humanIdx | Should -BeLessThan $markerArrayIdx
    }

    It 'T103 (FR-030 inventory): assignee, reporter, priority, issue links, and hand-applied labels survive the first reconcile after binding' {
        $lines = @(
            '# Feature', '',
            '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->', '',
            '### User Story 1 - Accept a partial payment (Priority: P1)',
            '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->', '',
            'Mirrored body.'
        )
        Set-Content -NoNewline -LiteralPath $script:Spec -Value (($lines -join "`n") + "`n")

        $issues = @{
            'COMP-1'  = @{ summary = 'Billing invoices'; issuetype = @{ name = 'Epic' }; project = @{ key = 'COMP' }; properties = @{ 'spec-kit-jira' = @{ origin = 'human'; role = 'parent'; repo = 'acme/app'; spec_slug = '001-billing-invoices' } } }
            'COMP-11' = @{
                summary    = 'Accept a partial payment'; issuetype = @{ name = 'Story' }; project = @{ key = 'COMP' }
                assignee   = @{ accountId = 'hand-assigned-owner' }
                reporter   = @{ accountId = 'the-product-owner' }
                issuelinks = @(@{ type = @{ name = 'Blocks' }; outwardIssue = @{ key = 'COMP-999' } })
                labels     = @('hand-applied-label')
                properties = @{ 'spec-kit-jira' = @{ origin = 'human'; role = 'story'; story = '3333333333333333'; repo = 'acme/app'; spec_slug = '001-billing-invoices' } }
            }
        }
        $cfgJson = (@{ projects = @{ COMP = 'company' }; issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r = Invoke-ReconcileCaptured2 @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0

        $fields = (Invoke-RestMethod -Uri "$($M.BaseUrl)/rest/api/3/issue/COMP-11").fields
        $fields.assignee.accountId | Should -Be 'hand-assigned-owner'
        $fields.reporter.accountId | Should -Be 'the-product-owner'
        $fields.issuelinks[0].outwardIssue.key | Should -Be 'COMP-999'
        @($fields.labels) | Should -Contain 'hand-applied-label'
    }

    It 'T105: a human edit to the preserved region AFTER binding still survives the next reconcile' {
        $lines = @(
            '# Feature', '',
            '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->', '',
            '### User Story 1 - Accept a partial payment (Priority: P1)',
            '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->', '',
            'Mirrored body.'
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

        $r1 = Invoke-ReconcileCaptured2 @('reconcile', $script:Spec, '--json')
        $r1.ExitCode | Should -Be 0

        $adf = @{
            type    = 'doc'; version = 1
            content = @(
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'An edit the human made AFTER binding.' }) }
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'Synced from spec-kit — do not edit below this line'; marks = @(@{ type = 'strong' }) }) }
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'Mirrored body.' }) }
            )
        }
        Invoke-RestMethod -Uri "$($M.BaseUrl)/rest/api/3/issue/COMP-11" -Method Put -ContentType 'application/json' `
            -Body (@{ fields = @{ description = $adf } } | ConvertTo-Json -Depth 20) | Out-Null

        $r2 = Invoke-ReconcileCaptured2 @('reconcile', $script:Spec, '--json')
        $r2.ExitCode | Should -Be 0

        $desc = (Invoke-RestMethod -Uri "$($M.BaseUrl)/rest/api/3/issue/COMP-11").fields.description
        $desc.content[0].content[0].text | Should -Be 'An edit the human made AFTER binding.'
    }
}
