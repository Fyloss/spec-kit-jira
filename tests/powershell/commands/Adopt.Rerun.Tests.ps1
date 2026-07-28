# T107 [US3] / T160 [US6] — Re-running adoption on an adopted corpus, PowerShell
# side. Mirror of tests/bash/commands/test_adopt_rerun.bats
# (003 FR-019, FR-027, SC-004, SC-007).

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Entry = Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1'
    Import-Module (Join-Path $script:Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    $script:Issues = @'
{"ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
 "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
 "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
 "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
 "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
 "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
 "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}
'@

    function Get-SlugFor {
        param([string] $Key)
        switch ($Key) {
            { $_ -in 'ADO-1', 'ADO-2', 'ADO-3' } { return '003-label-based-adoption' }
            { $_ -in 'ADO-4', 'ADO-5' } { return '004-billing-export' }
            default { return '005-audit-trail' }
        }
    }

    function Start-WithAdopted {
        # The corpus with those keys already carrying this spec's human-origin
        # marker — i.e. already adopted by a previous run.
        param([string[]] $Adopted = @())
        $identity = [ordered]@{}
        foreach ($k in $Adopted) {
            $identity[$k] = [ordered]@{ origin = 'human'; repo = 'acme/app'; spec_slug = (Get-SlugFor $k) }
        }
        $cfg = [ordered]@{
            projects = [ordered]@{ ADO = 'company' }
            identity = $identity
            issues   = ($script:Issues | ConvertFrom-Json -AsHashtable)
        }
        $script:Mock = Start-JiraMock -ConfigJson (ConvertTo-Json -InputObject $cfg -Depth 20 -Compress)
    }

    function New-AdoptWorkdir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Copy-Item -Recurse -Force -Path (Join-Path $script:Root 'tests/conformance/fixtures/repo-with-adoption/*') -Destination $d
        return $d
    }

    function Invoke-Adopt {
        param([string] $Workdir, [string[]] $AdoptArgs = @())
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
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
    }

    function Get-WriteCount {
        return @((Get-JiraMockCallLog -Mock $script:Mock) |
                Where-Object { $_ -match '^(PUT|POST|DELETE|PATCH) ' }).Count
    }
}

Describe 'a fully adopted corpus (FR-019, SC-004)' {
    BeforeEach { $script:Work = New-AdoptWorkdir; Start-WithAdopted @('ADO-1', 'ADO-2', 'ADO-3', 'ADO-4', 'ADO-5', 'ADO-6', 'ADO-7') }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'performs ZERO writes and exits 0' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')
        $r.ExitCode | Should -Be 0
        Get-WriteCount | Should -Be 0
        @(($r.StdOut | ConvertFrom-Json).actions).Count | Should -Be 0
    }

    It 'reports every binding already-adopted and counts them as skipped' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        @($j.adoption.bindings | Where-Object { $_.status -eq 'already-adopted' }).Count | Should -Be 7
        $j.counts.skipped | Should -Be 7
        $j.counts.updated | Should -Be 0
        $j.counts.errors | Should -Be 0
        @($j.adoption.refusals).Count | Should -Be 0
    }

    It 'calls the ticket already adopted in the prose plan, not refused' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')
        $r.StdOut | Should -BeLike '*already adopted*'
        $r.StdOut | Should -Not -BeLike '*REFUSED*'
    }

    It 'writes nothing on a dry re-run either' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')
        $r.ExitCode | Should -Be 0
        Get-WriteCount | Should -Be 0
        @(($r.StdOut | ConvertFrom-Json).actions).Count | Should -Be 0
    }
}

Describe 'an interrupted adoption completes on re-run (FR-027, SC-007)' {
    BeforeEach { $script:Work = New-AdoptWorkdir; Start-WithAdopted @('ADO-1', 'ADO-2', 'ADO-3') }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'skips what was already stamped and writes only the remainder' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $j.counts.skipped | Should -Be 3
        $j.counts.updated | Should -Be 4
        $log = (Get-JiraMockCallLog -Mock $script:Mock) -join "`n"
        foreach ($k in @('ADO-1', 'ADO-2', 'ADO-3')) { $log | Should -Not -BeLike "*PUT /rest/api/3/issue/$k/*" }
        foreach ($k in @('ADO-4', 'ADO-5', 'ADO-6', 'ADO-7')) { $log | Should -BeLike "*PUT /rest/api/3/issue/$k/*" }
    }
}

Describe 'a stale claim by another spec is refused, never silently skipped' {
    It 'refuses rather than skipping when the marker names a different spec' {
        $cfg = [ordered]@{
            projects = [ordered]@{ ADO = 'company' }
            identity = [ordered]@{ 'ADO-4' = [ordered]@{ origin = 'human'; repo = 'acme/app'; spec_slug = '009-elsewhere' } }
            issues   = ($script:Issues | ConvertFrom-Json -AsHashtable)
        }
        $script:Mock = Start-JiraMock -ConfigJson (ConvertTo-Json -InputObject $cfg -Depth 20 -Compress)
        $work = New-AdoptWorkdir
        try {
            $r = Invoke-Adopt -Workdir $work -AdoptArgs @('--yes', '--json')
            $r.ExitCode | Should -Be 4
            $j = $r.StdOut | ConvertFrom-Json
            @($j.adoption.refusals | Where-Object { $_.reason -eq 'already-claimed' }).Count | Should -Be 1
            ((Get-JiraMockCallLog -Mock $script:Mock) -join "`n") | Should -Not -BeLike '*PUT /rest/api/3/issue/ADO-4/*'
        }
        finally {
            Stop-JiraMock -Mock $script:Mock
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }
    }
}
