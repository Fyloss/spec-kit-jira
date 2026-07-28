# T081 [US2] — Exit-code precedence, PowerShell side. Mirror of
# tests/bash/commands/test_adopt_exit_codes.bats (003 FR-013, FR-030).
#
# A mixed run applies its unambiguous bindings AND exits 4. When classes co-occur
# the HIGHEST applicable code wins: a privacy block (9) beats a refusal (4), a
# transport failure (2/3) beats a refusal, and a usage error (1) stops the run
# before any of them can be reached.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Entry = Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1'
    Import-Module (Join-Path $script:Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    # 003 is fully labelled; 004 has two candidates; 005 has none.
    $script:Mixed = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
  "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
  "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
  "ADO-8":{"labels":["speckit-adopt:004-billing-export"]},
  "ADO-9":{"labels":["speckit-adopt:004-billing-export"]}}}
'@
    $script:Clean = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
  "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
  "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
  "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
  "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
  "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
  "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}}
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

    function Get-PutCount {
        return @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count
    }
}

Describe 'a mixed run applies and exits 4 (FR-013)' {
    BeforeEach {
        $script:Mock = Start-JiraMock -ConfigJson $script:Mixed
        $script:Work = New-AdoptWorkdir
    }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'applies the unambiguous bindings AND exits 4' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')
        $r.ExitCode | Should -Be 4
        $j = $r.StdOut | ConvertFrom-Json
        @($j.adoption.bindings).Count | Should -Be 3
        @($j.adoption.refusals).Count | Should -BeGreaterThan 0
        $j.exit_code | Should -Be 4
        Get-PutCount | Should -Be 3
    }

    It 'leaves ZERO writes for a refused binding' {
        Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes') | Out-Null
        $log = (Get-JiraMockCallLog -Mock $script:Mock) -join "`n"
        $log | Should -Not -BeLike '*PUT /rest/api/3/issue/ADO-8/*'
        $log | Should -Not -BeLike '*PUT /rest/api/3/issue/ADO-9/*'
    }

    It 'reports one error per refusal' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $j.counts.errors | Should -Be @($j.adoption.refusals).Count
    }

    It 'still exits 4 on a decline, with zero writes' {
        $r = Invoke-Adopt -Workdir $script:Work -Extra @{ SPEC_KIT_JIRA_ADOPT_ANSWER = 'n' }
        $r.ExitCode | Should -Be 4
        Get-PutCount | Should -Be 0
    }

    It 'still exits 4 on a dry run, with zero writes' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')
        $r.ExitCode | Should -Be 4
        Get-PutCount | Should -Be 0
    }

    It 'lets a privacy block (9) beat a refusal (4)' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes') `
            -Extra @{ SPEC_KIT_JIRA_REPO = 'acme/mirror-of-acme.atlassian.net' }
        $r.ExitCode | Should -Be 9
        Get-PutCount | Should -Be 0
    }

    It 'stops on a usage error (1) before anything is read' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--nonsense')
        $r.ExitCode | Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'reports a configuration refusal (4) with no candidate read' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes') -Extra @{ JIRA_CONFIG_DIR = '.specify/jira-disabled' }
        $r.ExitCode | Should -Be 4
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'matches the summary exit_code to the process exit code' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')
        ($r.StdOut | ConvertFrom-Json).exit_code | Should -Be $r.ExitCode
    }
}

Describe 'a transport failure beats a refusal' {
    It 'exits 3 on an authentication failure during discovery' {
        $script:Mock = Start-JiraMock -ConfigJson '{"projects":{"ADO":"company"},"faults":{"ADO":{"status":401}},"issues":{"ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]}}}'
        $work = New-AdoptWorkdir
        try {
            $r = Invoke-Adopt -Workdir $work -AdoptArgs @('--yes')
            $r.ExitCode | Should -Be 3
            Get-PutCount | Should -Be 0
        }
        finally {
            Stop-JiraMock -Mock $script:Mock
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }
    }
}

Describe 'a clean run exits 0 (control)' {
    It 'exits 0 when every target binds' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Clean
        $work = New-AdoptWorkdir
        try {
            (Invoke-Adopt -Workdir $work -AdoptArgs @('--yes')).ExitCode | Should -Be 0
        }
        finally {
            Stop-JiraMock -Mock $script:Mock
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }
    }
}
