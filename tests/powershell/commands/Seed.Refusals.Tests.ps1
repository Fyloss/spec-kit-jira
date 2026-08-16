# T150/T152 [027] — Pester twin of test_seed_refusals.bats. C-2: the uniform
# refusal property across all fourteen classes of
# contracts/seed-cli-contract.md §8. C-3: refusals at §3 steps 1-4 issue zero
# requests, generalised beyond the host-mismatch case.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Seed.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/SeedState.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_REPO = 'local/repo'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-add-payment-webhooks'

    function New-RefusalsWork {
        $work = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        $featureDir = Join-Path $work 'specs/001-add-payment-webhooks'
        New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
        return (Join-Path $featureDir 'spec.md')
    }

    function Get-RefusalsRouting {
        return (@{ project = 'PROJ'; declared_type_specification = 'Epic'; declared_type_story = 'Story'; terminal_statuses_csv = 'Done'; parent_type_id = '10000'; child_type_id = '10001' } | ConvertTo-Json -Compress)
    }

    function Write-TwoStoryRecord([string] $Spec) {
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]' -PlanDigest '' -RoutingJson (Get-RefusalsRouting) -PlanSnapshotJson '[]'
        Save-JiraSeedState -SpecPath $Spec -DocumentJson $doc
    }

    function Write-TwoStorySpec([string] $Spec) {
        $text = @(
            '# Feature', '',
            '### User Story 1 - Accept a partial payment (Priority: P1)', '<!-- speckit-jira pin=PROJ-11 -->', '', 'Body one.', '',
            '### User Story 2 - Refund a captured payment (Priority: P1)', '<!-- speckit-jira pin=PROJ-12 -->', '', 'Body two.'
        ) -join "`n"
        Set-Content -NoNewline -LiteralPath $Spec -Value ($text + "`n")
    }

    function New-RefusalsIssue([string] $Key, [string] $Summary, [string] $Status, [string] $IType = 'Story', [string] $Project = 'PROJ') {
        return @{ summary = $Summary; description = 'body'; status = @{ name = $Status }; issuetype = @{ name = $IType }; project = @{ key = $Project } }
    }

    function Invoke-SeedCaptured3 {
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

    function Assert-Uniform($r, [string] $Code, [string] $Needle = '') {
        $r.ExitCode | Should -Be 4
        $combined = $r.Out + $r.Err
        $combined | Should -Match ([regex]::Escape($Code))
        if ($Needle) { $combined | Should -Match ([regex]::Escape($Needle)) }
    }

    function Invoke-DeclineThenResumeWith($Spec, $IssuesHash) {
        Write-TwoStorySpec -Spec $Spec
        Write-TwoStoryRecord -Spec $Spec
        $emptyCfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $emptyCfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r1 = Invoke-SeedCaptured3 @($Spec, '--json')
        $r1.ExitCode | Should -Be 0
        Stop-JiraMock -Mock $script:M
        $cfgJson = (@{ issues = $IssuesHash } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        return (Invoke-SeedCaptured3 @($Spec, '--json'))
    }
}

Describe 'Invoke-JiraSeed: C-2 uniform refusal property, all fourteen classes' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'REF-EXISTS: zero writes, names the folder, remediation present' {
        $spec = New-RefusalsWork
        $cfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        Write-TwoStorySpec -Spec $spec
        $r = Invoke-SeedCaptured3 @($spec, '--json')
        Assert-Uniform $r 'REF-EXISTS' $spec
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'REF-DESIGNATOR: a malformed resupplied designator, zero requests' {
        $spec = New-RefusalsWork
        $cfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        Write-TwoStorySpec -Spec $spec
        Write-TwoStoryRecord -Spec $spec
        $r = Invoke-SeedCaptured3 @($spec, '--story', 'not a valid designator at all', '--json')
        Assert-Uniform $r 'REF-DESIGNATOR'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'REF-HOST: a resupplied URL from an unconfigured host, zero requests' {
        $spec = New-RefusalsWork
        $cfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        Write-TwoStorySpec -Spec $spec
        Write-TwoStoryRecord -Spec $spec
        $r = Invoke-SeedCaptured3 @($spec, '--story', 'https://not-the-configured-host.example.com/browse/PROJ-11', '--json')
        Assert-Uniform $r 'REF-HOST'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'REF-DUPLICATE: the same key resupplied twice, zero requests' {
        $spec = New-RefusalsWork
        $cfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        Write-TwoStorySpec -Spec $spec
        Write-TwoStoryRecord -Spec $spec
        $r = Invoke-SeedCaptured3 @($spec, '--story', 'PROJ-11', '--story', 'PROJ-11', '--json')
        Assert-Uniform $r 'REF-DUPLICATE' 'PROJ-11'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'REF-RESEED: a resupplied set differing from the recorded one, zero requests' {
        $spec = New-RefusalsWork
        $cfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        Write-TwoStorySpec -Spec $spec
        Write-TwoStoryRecord -Spec $spec
        $r = Invoke-SeedCaptured3 @($spec, '--story', 'PROJ-11', '--story', 'PROJ-99', '--json')
        Assert-Uniform $r 'REF-RESEED'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'REF-DECOMP: a missing pinning marker on a first run, naming the key' {
        $spec = New-RefusalsWork
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - A (Priority: P1)`n`nBody, no marker.`n"
        Write-TwoStoryRecord -Spec $spec
        $r = Invoke-SeedCaptured3 @($spec, '--json')
        Assert-Uniform $r 'REF-DECOMP' 'PROJ-11'
    }

    It 'REF-DRAFT-EDIT: a pinned story deleted between decline and resume' {
        $spec = New-RefusalsWork
        Write-TwoStorySpec -Spec $spec
        Write-TwoStoryRecord -Spec $spec
        $issues = @{
            'PROJ-11' = New-RefusalsIssue 'PROJ-11' 'Accept a partial payment' 'To Do'
            'PROJ-12' = New-RefusalsIssue 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $cfg = Write-JiraMockConfig -Json (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r1 = Invoke-SeedCaptured3 @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - Accept a partial payment (Priority: P1)`n<!-- speckit-jira pin=PROJ-11 -->`n`nBody one.`n"
        $r2 = Invoke-SeedCaptured3 @($spec, '--json')
        Assert-Uniform $r2 'REF-DRAFT-EDIT' 'PROJ-12'
    }

    It 'REF-UNRESOLVED: a designated key absent from the read' {
        $spec = New-RefusalsWork
        $issues = @{ 'PROJ-11' = New-RefusalsIssue 'PROJ-11' 'Accept a partial payment' 'To Do' }
        $r = Invoke-DeclineThenResumeWith $spec $issues
        Assert-Uniform $r 'REF-UNRESOLVED' 'PROJ-12'
    }

    It 'REF-ROLE: a story-role key whose Jira type does not match hierarchy.story' {
        $spec = New-RefusalsWork
        $issues = @{
            'PROJ-11' = New-RefusalsIssue 'PROJ-11' 'Accept a partial payment' 'To Do' 'Bug'
            'PROJ-12' = New-RefusalsIssue 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $r = Invoke-DeclineThenResumeWith $spec $issues
        Assert-Uniform $r 'REF-ROLE' 'PROJ-11'
    }

    It 'REF-ROUTING: a named issue outside the routed project' {
        $spec = New-RefusalsWork
        $issues = @{
            'PROJ-11' = New-RefusalsIssue 'PROJ-11' 'Accept a partial payment' 'To Do' 'Story' 'OTHER'
            'PROJ-12' = New-RefusalsIssue 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $r = Invoke-DeclineThenResumeWith $spec $issues
        Assert-Uniform $r 'REF-ROUTING' 'PROJ-11'
    }

    It 'REF-MULTIPROJECT: named story-role issues span more than one project' {
        $spec = New-RefusalsWork
        $issues = @{
            'PROJ-11' = New-RefusalsIssue 'PROJ-11' 'Accept a partial payment' 'To Do' 'Story' 'PROJ'
            'PROJ-12' = New-RefusalsIssue 'PROJ-12' 'Refund a captured payment' 'To Do' 'Story' 'OTHER'
        }
        $r = Invoke-DeclineThenResumeWith $spec $issues
        Assert-Uniform $r 'REF-MULTIPROJECT'
    }

    It 'REF-TERMINAL: a named issue in a configured terminal status' {
        $spec = New-RefusalsWork
        $issues = @{
            'PROJ-11' = New-RefusalsIssue 'PROJ-11' 'Accept a partial payment' 'Done'
            'PROJ-12' = New-RefusalsIssue 'PROJ-12' 'Refund a captured payment' 'To Do'
        }
        $r = Invoke-DeclineThenResumeWith $spec $issues
        Assert-Uniform $r 'REF-TERMINAL' 'PROJ-11'
    }

    It "REF-CLAIMED: a named issue already carries another specification's identity" {
        $spec = New-RefusalsWork
        $issue11 = New-RefusalsIssue 'PROJ-11' 'Accept a partial payment' 'To Do'
        $issue11.properties = @{ 'spec-kit-jira' = @{ origin = 'human'; role = 'story'; repo = 'local/repo'; spec_slug = '999-someone-elses-spec' } }
        $issues = @{ 'PROJ-11' = $issue11; 'PROJ-12' = New-RefusalsIssue 'PROJ-12' 'Refund a captured payment' 'To Do' }
        $r = Invoke-DeclineThenResumeWith $spec $issues
        Assert-Uniform $r 'REF-CLAIMED' 'PROJ-11'
    }

    It "REF-THIN: a named issue's description has no non-whitespace character" {
        $spec = New-RefusalsWork
        $issue11 = New-RefusalsIssue 'PROJ-11' 'Accept a partial payment' 'To Do'
        $issue11.description = '   '
        $issues = @{ 'PROJ-11' = $issue11; 'PROJ-12' = New-RefusalsIssue 'PROJ-12' 'Refund a captured payment' 'To Do' }
        $r = Invoke-DeclineThenResumeWith $spec $issues
        Assert-Uniform $r 'REF-THIN' 'PROJ-11'
    }

    It 'C-3: REF-DESIGNATOR, REF-HOST, REF-DUPLICATE, REF-RESEED, and REF-EXISTS all precede any request' {
        $spec = New-RefusalsWork
        $cfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        Write-TwoStorySpec -Spec $spec
        $r0 = Invoke-SeedCaptured3 @($spec, '--json')
        $r0.ExitCode | Should -Be 4
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0

        Write-TwoStoryRecord -Spec $spec
        $r1 = Invoke-SeedCaptured3 @($spec, '--story', 'https://not-configured.example.com/browse/PROJ-11', '--json')
        $r1.ExitCode | Should -Be 4
        $r2 = Invoke-SeedCaptured3 @($spec, '--story', 'PROJ-11', '--story', 'PROJ-11', '--json')
        $r2.ExitCode | Should -Be 4
        $r3 = Invoke-SeedCaptured3 @($spec, '--story', 'PROJ-99', '--story', 'PROJ-11', '--json')
        $r3.ExitCode | Should -Be 4
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }
}
