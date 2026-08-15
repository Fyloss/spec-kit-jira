# T140 [027] — Budget assertions at scale, through Invoke-JiraSeed's own
# resume path (contract seed-cli-contract.md §6, C-14, C-19). Mirror of
# tests/bash/ci/test_seed_budget.bats — PowerShell's own JSON/HTTP layer
# runs in-process (ConvertFrom-Json and the HTTP client are .NET calls, not
# subprocess spawns), so there is no PowerShell equivalent of the bash
# port's spawn_count.bash/argv_size.bash PATH-interposition: the meaningful,
# port-shared assertion is the REQUEST count, verified independently here
# via Get-JiraMockCallLog exactly as the bash twin verifies it via
# mock_calls.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Seed.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/SeedState.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_REPO = 'local/repo'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-add-payment-webhooks'

    function New-BudgetWork {
        $work = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        $featureDir = Join-Path $work 'specs/001-add-payment-webhooks'
        New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
        return (Join-Path $featureDir 'spec.md')
    }

    function Get-BudgetRouting {
        return (@{ project = 'PROJ'; declared_type_specification = 'Epic'; declared_type_story = 'Story'; terminal_statuses_csv = '' } | ConvertTo-Json -Compress)
    }

    function New-SeedNStories {
        param([string] $Spec, [int] $N)
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('# Feature')
        $designators = [System.Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le $N; $i++) {
            $designators.Add([ordered]@{ role = 'story'; form = 'key'; key = "PROJ-$i"; raw = "PROJ-$i"; position = ($i - 1) })
            [void]$sb.Append("`n`n### User Story $i - S$i (Priority: P1)`n<!-- speckit-jira pin=PROJ-$i -->`n`nBody $i.")
        }
        Set-Content -NoNewline -LiteralPath $Spec -Value ($sb.ToString() + "`n")
        $designatorsJson = ($designators | ConvertTo-Json -Depth 10 -Compress)
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson $designatorsJson -PlanDigest '' -RoutingJson (Get-BudgetRouting) -PlanSnapshotJson '[]'
        Save-JiraSeedState -SpecPath $Spec -DocumentJson $doc
    }

    function Get-BudgetIssuesHash {
        param([int] $N)
        $issues = @{}
        for ($i = 1; $i -le $N; $i++) {
            $issues["PROJ-$i"] = @{ summary = "S$i"; description = "body $i"; status = @{ name = 'To Do' }; issuetype = @{ name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        return $issues
    }

    function Invoke-SeedCaptured4 {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $code = Invoke-JiraSeed -Arguments $CmdArgs } finally { [Console]::SetOut($orig) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }
}

Describe 'Invoke-JiraSeed: budget at scale (T140)' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'C-14/C-19 at scale: 100 designators, first gate-reach then resume, exactly 1 bulkfetch on resume, never a comment field' {
        $spec = New-BudgetWork
        New-SeedNStories -Spec $spec -N 100
        $cfgJson = (@{ issues = (Get-BudgetIssuesHash -N 100) } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r1 = Invoke-SeedCaptured4 @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0

        $r2 = Invoke-SeedCaptured4 @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $calls = @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ })
        (@($calls | Where-Object { $_ -eq 'POST /rest/api/3/issue/bulkfetch' })).Count | Should -Be 1
        ($calls -join "`n") | Should -Not -Match 'comment'
    }

    It 'C-14 at scale: 101 designators, resume issues exactly 2 bulkfetch requests, never one per issue' {
        $spec = New-BudgetWork
        New-SeedNStories -Spec $spec -N 101
        $cfgJson = (@{ issues = (Get-BudgetIssuesHash -N 101) } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r1 = Invoke-SeedCaptured4 @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        $r2 = Invoke-SeedCaptured4 @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $calls = @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ })
        (@($calls | Where-Object { $_ -eq 'POST /rest/api/3/issue/bulkfetch' })).Count | Should -Be 2
        (@($calls | Where-Object { $_ -match '^GET .*/issue/[^/?]+\?' })).Count | Should -Be 0
    }
}
