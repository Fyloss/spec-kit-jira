# T139 [US5] — The dry-run twin is EXACT, PowerShell side. Mirror of
# tests/bash/commands/test_adopt_dry_run.bats (003 FR-023, SC-003).
#
# For `adopt` this is structural rather than behavioural: the action set IS the
# prediction, so there is no second code path that could drift.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Entry = Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1'
    Import-Module (Join-Path $script:Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    $script:Full = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
  "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
  "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
  "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
  "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
  "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
  "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}}
'@
    $script:Mixed = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
  "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
  "ADO-8":{"labels":["speckit-adopt:004-billing-export"]},
  "ADO-9":{"labels":["speckit-adopt:004-billing-export"]}}}
'@

    function New-AdoptWorkdir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Copy-Item -Recurse -Force -Path (Join-Path $script:Root 'tests/conformance/fixtures/repo-with-adoption/*') -Destination $d
        return $d
    }

    function Invoke-Adopt {
        param([string] $Workdir, [string[]] $AdoptArgs = @(), [hashtable] $Extra = @{})
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Process -Id $PID).Path
        foreach ($a in @('-NoProfile', '-File', $script:Entry, 'adopt') + $AdoptArgs) { $psi.ArgumentList.Add($a) }
        $psi.WorkingDirectory = $Workdir
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['SPEC_KIT_JIRA_BASE_URL'] = $script:Mock.BaseUrl
        $psi.EnvironmentVariables['JIRA_EMAIL'] = 'user@example.com'
        $psi.EnvironmentVariables['JIRA_API_TOKEN'] = 'RAWSECRETXYZ'
        $psi.EnvironmentVariables['JIRA_NO_SLEEP'] = '1'
        $psi.EnvironmentVariables['SPEC_KIT_JIRA_REPO'] = 'acme/app'
        foreach ($k in $Extra.Keys) { $psi.EnvironmentVariables[$k] = $Extra[$k] }
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
    }

    function Get-WriteCount {
        return @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -match '^(PUT|POST|DELETE|PATCH) ' }).Count
    }
    function Get-Compact { param($Value) return (ConvertTo-Json -InputObject $Value -Depth 30 -Compress) }
}

Describe 'a dry run writes nothing (FR-023)' {
    BeforeEach { $script:Mock = Start-JiraMock -ConfigJson $script:Full; $script:Work = New-AdoptWorkdir }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'performs zero writes of every kind' {
        (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).ExitCode | Should -Be 0
        Get-WriteCount | Should -Be 0
    }

    It 'still READS — it is a real discovery, not a stub' {
        Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json') | Out-Null
        $log = Get-JiraMockCallLog -Mock $script:Mock
        @($log | Where-Object { $_ -like 'GET /rest/api/3/search/jql*' }).Count | Should -Be 1
        @($log | Where-Object { $_ -like 'GET *properties/spec-kit-jira' }).Count | Should -Be 7
    }

    It 'marks itself a dry run, and the real run does not' {
        $dry = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).StdOut | ConvertFrom-Json
        $dry.dry_run | Should -BeTrue
        $dry.adoption.confirmed | Should -BeFalse
        $real = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $real.dry_run | Should -BeFalse
        $real.adoption.confirmed | Should -BeTrue
    }

    It 'never prompts, even with an answer available' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run') -Extra @{ SPEC_KIT_JIRA_ADOPT_ANSWER = 'y' }
        $r.StdOut | Should -Not -BeLike '*Apply this plan?*'
        Get-WriteCount | Should -Be 0
    }

    It 'wins over --yes: the operator asked to see, not to write' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--yes', '--json')
        $r.ExitCode | Should -Be 0
        Get-WriteCount | Should -Be 0
        ($r.StdOut | ConvertFrom-Json).adoption.confirmed | Should -BeFalse
    }
}

Describe 'the reported action set is IDENTICAL (SC-003)' {
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'matches the real run for a corpus where everything binds' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Full; $script:Work = New-AdoptWorkdir
        $dry = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).StdOut | ConvertFrom-Json
        $real = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        (Get-Compact $dry.actions) | Should -Be (Get-Compact $real.actions)
        @($dry.actions).Count | Should -Be 7
    }

    It 'matches for a plan that MIXES bindings and refusals' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Mixed; $script:Work = New-AdoptWorkdir
        $dry = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).StdOut | ConvertFrom-Json
        $real = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        (Get-Compact $dry.actions) | Should -Be (Get-Compact $real.actions)
        (Get-Compact $dry.counts) | Should -Be (Get-Compact $real.counts)
    }

    It 'predicts the exit code the real run returns' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Mixed; $script:Work = New-AdoptWorkdir
        $dry = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')
        $real = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes')
        $dry.ExitCode | Should -Be $real.ExitCode
        $real.ExitCode | Should -Be 4
    }

    It 'performs exactly the number of writes it predicted, and no more' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Full; $script:Work = New-AdoptWorkdir
        $predicted = @(((Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).StdOut | ConvertFrom-Json).actions).Count
        Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes') | Out-Null
        Get-WriteCount | Should -Be $predicted
    }
}
