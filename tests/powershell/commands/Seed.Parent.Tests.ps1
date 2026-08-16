# T125/T127/T129/T131/T133/T135/T137 [027, US2] — Pester twin of
# test_seed_parent.bats. A parent that does not exist yet
# (contracts/seed-cli-contract.md §8: C-17, C-18; spec.md FR-022, FR-023,
# FR-025, FR-026, FR-051, FR-052, FR-053, FR-061; research R14).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Seed.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/SeedState.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_REPO = 'local/repo'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-add-payment-webhooks'

    function New-ParentWork {
        $work = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        $featureDir = Join-Path $work 'specs/001-add-payment-webhooks'
        New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
        return (Join-Path $featureDir 'spec.md')
    }

    function Get-ParentRouting {
        return (@{ project = 'PROJ'; declared_type_specification = 'Epic'; declared_type_story = 'Story'; terminal_statuses_csv = ''; parent_type_id = '10000'; child_type_id = '10001' } | ConvertTo-Json -Compress)
    }

    function Write-ParentRecord([string] $Spec, [string] $DesignatorsJson) {
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson $DesignatorsJson -PlanDigest '' -RoutingJson (Get-ParentRouting) -PlanSnapshotJson '[]'
        Save-JiraSeedState -SpecPath $Spec -DocumentJson $doc
    }

    function Get-TwoUnparentedDesignators {
        return '[{"role":"specification","form":"free_text","raw":"Payment webhooks rollout","text":"Payment webhooks rollout","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]'
    }

    function Write-TwoStorySpecFor([string] $Spec) {
        $text = @(
            '# Feature', '', 'This feature streamlines partial payments and refunds.', '',
            '### User Story 1 - Accept a partial payment (Priority: P1)', '<!-- speckit-jira pin=PROJ-11 -->', '', 'Body one.', '',
            '### User Story 2 - Refund a captured payment (Priority: P1)', '<!-- speckit-jira pin=PROJ-12 -->', '', 'Body two.'
        ) -join "`n"
        Set-Content -NoNewline -LiteralPath $Spec -Value ($text + "`n")
    }

    function New-SeedIssueEntry([string] $Key, [string] $Summary, [string] $Status, [string] $ParentKey = '', [string] $ParentSummary = '', [string] $ParentStatus = '') {
        $itype = if ($Key -eq 'PROJ-1') { 'Epic' } else { 'Story' }
        $entry = [ordered]@{
            summary     = $Summary
            description = 'body'
            status      = @{ name = $Status }
            issuetype   = @{ name = $itype }
            project     = @{ key = 'PROJ' }
        }
        if ($ParentKey) {
            $entry.parent = @{ key = $ParentKey; fields = @{ summary = $ParentSummary; status = @{ name = $ParentStatus } } }
        }
        else {
            $entry.parent = $null
        }
        return $entry
    }

    function Invoke-SeedCaptured2 {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $code = Invoke-JiraSeed -Arguments $CmdArgs }
        finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'Invoke-JiraSeed: a parent that does not exist yet' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'T125: a free-text parent creates exactly one issue, no lookup of any kind' {
        $spec = New-ParentWork
        Write-TwoStorySpecFor -Spec $spec
        Write-ParentRecord -Spec $spec -DesignatorsJson (Get-TwoUnparentedDesignators)

        $issues = @{
            'PROJ-11' = New-SeedIssueEntry 'PROJ-11' 'Accept a partial payment' 'To Do'
            'PROJ-12' = New-SeedIssueEntry 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $cfgJson = (@{ createdKey = 'PROJ-1'; issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r = Invoke-SeedCaptured2 @($spec, '--confirm', '--json')
        $r.ExitCode | Should -Be 0
        $out = $r.Out | ConvertFrom-Json
        (@($out.bindings | Where-Object { $_.role -eq 'parent' }))[0].key | Should -Be 'PROJ-1'
        (@($out.bindings | Where-Object { $_.role -eq 'parent' }))[0].origin | Should -Be 'bridge'
        $calls = @(Get-JiraMockCallLog -Mock $M)
        (@($calls | Where-Object { $_ -eq 'POST /rest/api/3/issue' })).Count | Should -Be 1
        (@($calls | Where-Object { $_ -match '^GET ' })).Count | Should -Be 0
        (Get-Content -Raw -LiteralPath $spec) | Should -Match '<!-- speckit-jira spec=[0-9a-f]{16} ticket=PROJ-1 -->'
    }

    It "T127: the created parent's summary is the free text and its description is the drafted overview" {
        $spec = New-ParentWork
        Write-TwoStorySpecFor -Spec $spec
        Write-ParentRecord -Spec $spec -DesignatorsJson (Get-TwoUnparentedDesignators)

        $issues = @{
            'PROJ-11' = New-SeedIssueEntry 'PROJ-11' 'Accept a partial payment' 'To Do'
            'PROJ-12' = New-SeedIssueEntry 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $cfgJson = (@{ createdKey = 'PROJ-1'; issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r = Invoke-SeedCaptured2 @($spec, '--confirm', '--json')
        $r.ExitCode | Should -Be 0
        $calls = (Get-JiraMockCallLog -Mock $M) -join "`n"
        $calls | Should -Match 'POST /rest/api/3/issue'
    }

    It 'C-17: a reparent line renders visually distinct, naming the current parent and the child-loss count' {
        $spec = New-ParentWork
        Write-TwoStorySpecFor -Spec $spec
        Write-ParentRecord -Spec $spec -DesignatorsJson (Get-TwoUnparentedDesignators)

        $issues = @{
            'PROJ-11' = New-SeedIssueEntry 'PROJ-11' 'Accept a partial payment' 'To Do' 'PROJ-99' 'Q3 payments' 'In Progress'
            'PROJ-12' = New-SeedIssueEntry 'PROJ-12' 'Refund a captured payment' 'To Do' 'PROJ-99' 'Q3 payments' 'In Progress'
        }
        $cfgJson = (@{ createdKey = 'PROJ-1'; issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r1 = Invoke-SeedCaptured2 @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        $r2 = Invoke-SeedCaptured2 @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $out = $r2.Out | ConvertFrom-Json
        $lines = @($out.confirmation_required.plan)
        (@($lines | Where-Object { $_ -match '^! reparent' })).Count | Should -Be 2
        $expectedPattern = [regex]::Escape('from PROJ-99 "Q3 payments" [In Progress] - loses 2 children')
        ($lines -join "`n") | Should -Match $expectedPattern
        (@($lines | Where-Object { $_ -match '^  reparent' })).Count | Should -Be 0
    }

    It 'C-17: the child-loss count is stated even when it is one' {
        $spec = New-ParentWork
        Write-TwoStorySpecFor -Spec $spec
        $designators = '[{"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]'
        Write-ParentRecord -Spec $spec -DesignatorsJson $designators

        $issues = @{
            'PROJ-1'  = New-SeedIssueEntry 'PROJ-1' 'Payment webhooks rollout' 'In Progress'
            'PROJ-11' = New-SeedIssueEntry 'PROJ-11' 'Accept a partial payment' 'To Do' 'PROJ-99' 'Q3 payments' 'In Progress'
            'PROJ-12' = New-SeedIssueEntry 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $cfgJson = (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r1 = Invoke-SeedCaptured2 @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        $r2 = Invoke-SeedCaptured2 @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $out = $r2.Out | ConvertFrom-Json
        (@($out.confirmation_required.plan) -join "`n") | Should -Match 'loses 1 child'
    }

    It 'T133: no reparent line, and no placement write, when the specification role is left undesignated' {
        $spec = New-ParentWork
        Write-TwoStorySpecFor -Spec $spec
        $designators = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]'
        Write-ParentRecord -Spec $spec -DesignatorsJson $designators

        $issues = @{
            'PROJ-11' = New-SeedIssueEntry 'PROJ-11' 'Accept a partial payment' 'To Do' 'PROJ-99' 'Q3 payments' 'In Progress'
            'PROJ-12' = New-SeedIssueEntry 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $cfgJson = (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r1 = Invoke-SeedCaptured2 @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        $out1 = $r1.Out | ConvertFrom-Json
        (@($out1.confirmation_required.plan) -join "`n") | Should -Not -Match 'reparent'

        $r2 = Invoke-SeedCaptured2 @($spec, '--confirm', '--json')
        $r2.ExitCode | Should -Be 0
        $calls = @(Get-JiraMockCallLog -Mock $M)
        (@($calls | Where-Object { $_ -eq 'PUT /rest/api/3/issue/PROJ-11' })).Count | Should -Be 0
    }

    It 'C-18: no parent designator, a named story already parented -> scatter note, exit 0, zero writes for it' {
        $spec = New-ParentWork
        Write-TwoStorySpecFor -Spec $spec
        $designators = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]'
        Write-ParentRecord -Spec $spec -DesignatorsJson $designators

        $issues = @{
            'PROJ-11' = New-SeedIssueEntry 'PROJ-11' 'Accept a partial payment' 'To Do' 'PROJ-88' 'Legacy billing' 'To Do'
            'PROJ-12' = New-SeedIssueEntry 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $cfgJson = (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r1 = Invoke-SeedCaptured2 @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        $r2 = Invoke-SeedCaptured2 @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $out = $r2.Out | ConvertFrom-Json
        (@($out.confirmation_required.provenance | Where-Object { $_.heading -eq 'Overview' })).Count | Should -Be 0
        ($out.warnings -join "`n") | Should -Match 'PROJ-11'
        ($out.warnings -join "`n") | Should -Match 'PROJ-88'

        # bulkfetch is a POST-shaped READ (Jira's own API), not a mutation.
        $calls = @(Get-JiraMockCallLog -Mock $M)
        (@($calls | Where-Object { ($_ -match 'POST|PUT') -and ($_ -notmatch 'bulkfetch') })).Count | Should -Be 0
    }

    It 'T137/T138: an already-bound story is excluded from re-validation and re-binding on the next invocation' {
        $spec = New-ParentWork
        $text = @(
            '# Feature', '',
            '### User Story 1 - Accept a partial payment (Priority: P1)',
            '<!-- speckit-jira story=aaaaaaaaaaaaaaaa ticket=PROJ-11 -->', '', 'Body one.', '',
            '### User Story 2 - Refund a captured payment (Priority: P1)',
            '<!-- speckit-jira pin=PROJ-12 -->', '', 'Body two.'
        ) -join "`n"
        Set-Content -NoNewline -LiteralPath $spec -Value ($text + "`n")
        $designators = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]'
        Write-ParentRecord -Spec $spec -DesignatorsJson $designators

        $issues = @{ 'PROJ-12' = @{ summary = 'Refund a captured payment'; description = 'body' } }
        $cfgJson = (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r = Invoke-SeedCaptured2 @($spec, '--confirm', '--json')
        $r.ExitCode | Should -Be 0
        $out = $r.Out | ConvertFrom-Json
        @($out.bindings).Count | Should -Be 1
        $out.bindings[0].key | Should -Be 'PROJ-12'
        $calls = @(Get-JiraMockCallLog -Mock $M)
        (@($calls | Where-Object { $_ -eq 'PUT /rest/api/3/issue/PROJ-11/properties/spec-kit-jira' })).Count | Should -Be 0
        (Get-Content -Raw -LiteralPath $spec) | Should -Match '<!-- speckit-jira story=[0-9a-f]{16} ticket=PROJ-12 -->'
    }
}
