# T156 [US6] — Partial adoption through --spec, PowerShell side. Mirror of
# tests/bash/commands/test_adopt_scope.bats (003 FR-026, data-model §6).
#
# The claim is stronger than "the others are not written to": an out-of-scope
# folder contributes NO LABEL to any query, so there is zero read and zero write
# against its tickets.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Entry = Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1'
    Import-Module (Join-Path $script:Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    $script:Corpus = @'
{"projects":{"ADO":"company","BILL":"team"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-alpha-report"]},
  "ADO-2":{"labels":["speckit-adopt:003-alpha-report:us1"],"parent":"ADO-1"},
  "ADO-3":{"labels":["speckit-adopt:004-beta-import"]},
  "ADO-4":{"labels":["speckit-adopt:004-beta-import:us1"],"parent":"ADO-3"},
  "ADO-5":{"labels":["speckit-adopt:004-gamma-export"]},
  "ADO-6":{"labels":["speckit-adopt:004-gamma-export:us1"],"parent":"ADO-5"},
  "BILL-1":{"labels":["speckit-adopt:005-delta-billing"]},
  "BILL-2":{"labels":["speckit-adopt:005-delta-billing:us1"],"parent":"BILL-1"},
  "BILL-3":{"labels":["speckit-adopt:006-epsilon-ledger"]},
  "BILL-4":{"labels":["speckit-adopt:006-epsilon-ledger:us1"],"parent":"BILL-3"}}}
'@
    $script:ShortOnly = '{"projects":{"ADO":"company"},"issues":{"ADO-40":{"labels":["speckit-adopt:004"]}}}'

    function New-MultiWorkdir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Copy-Item -Recurse -Force -Path (Join-Path $script:Root 'tests/conformance/fixtures/repo-with-adoption-multi/*') -Destination $d
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

    function Get-CallLog { return ((Get-JiraMockCallLog -Mock $script:Mock) -join "`n") }
    function Get-PutCount { return @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count }
}

Describe 'only the scoped folders are discovered (FR-026)' {
    BeforeEach { $script:Mock = Start-JiraMock -ConfigJson $script:Corpus; $script:Work = New-MultiWorkdir }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'binds only the scoped folders' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '003-alpha-report', '--spec', '005-delta-billing', '--yes', '--json')
        $r.ExitCode | Should -Be 0
        $j = $r.StdOut | ConvertFrom-Json
        ((@($j.adoption.bindings | ForEach-Object { $_.spec_folder }) | Select-Object -Unique | Sort-Object) -join ',') |
            Should -Be '003-alpha-report,005-delta-billing'
        @($j.adoption.bindings).Count | Should -Be 4
        Get-PutCount | Should -Be 4
    }

    It 'reports the rest out of scope, sorted ascending' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '003-alpha-report', '--spec', '005-delta-billing', '--yes', '--json')).StdOut | ConvertFrom-Json
        (@($j.adoption.out_of_scope) -join ',') | Should -Be '004-beta-import,004-gamma-export,006-epsilon-ledger'
    }

    It 'never reads or writes an out-of-scope ticket (US6 AS-1)' {
        Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '003-alpha-report', '--yes') | Out-Null
        $log = Get-CallLog
        foreach ($k in @('ADO-3', 'ADO-4', 'ADO-5', 'ADO-6', 'BILL-1', 'BILL-2', 'BILL-3', 'BILL-4')) {
            $log | Should -Not -BeLike "*$k*"
        }
        foreach ($l in @('004-beta-import', '006-epsilon-ledger')) { $log | Should -Not -BeLike "*$l*" }
    }

    It 'searches only the projects still in scope' {
        Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '003-alpha-report', '--yes') | Out-Null
        @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'GET /rest/api/3/search/jql*' }).Count | Should -Be 1
        (Get-CallLog) | Should -BeLike '*%22ADO%22*'
        (Get-CallLog) | Should -Not -BeLike '*%22BILL%22*'
    }

    It 'considers every folder on disk when no --spec is given' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        @($j.adoption.out_of_scope).Count | Should -Be 0
        (@($j.adoption.bindings | ForEach-Object { $_.spec_folder }) | Select-Object -Unique).Count | Should -Be 5
    }

    It 'accumulates a repeated --spec rather than replacing it' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '003-alpha-report', '--spec', '004-beta-import', '--spec', '006-epsilon-ledger', '--yes', '--json')).StdOut | ConvertFrom-Json
        (@($j.adoption.bindings | ForEach-Object { $_.spec_folder }) | Select-Object -Unique).Count | Should -Be 3
        (@($j.adoption.out_of_scope) -join ',') | Should -Be '004-gamma-export,005-delta-billing'
    }

    It 'names the out-of-scope folders in the prose plan (Principle XVI)' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '003-alpha-report', '--dry-run')
        $r.StdOut | Should -BeLike '*out of scope: 004-beta-import, 004-gamma-export, 005-delta-billing, 006-epsilon-ledger*'
    }

    It 'omits the out-of-scope line when nothing is excluded' {
        (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')).StdOut | Should -Not -BeLike '*out of scope*'
    }
}

Describe 'an unknown scope stops the run (US6 AS-3)' {
    BeforeEach { $script:Mock = Start-JiraMock -ConfigJson $script:Corpus; $script:Work = New-MultiWorkdir }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'is a usage error with exit 1' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '009-never-on-disk', '--yes')
        $r.ExitCode | Should -Be 1
        $r.StdErr | Should -BeLike '*009-never-on-disk*'
    }

    It 'stops BEFORE anything is read or written' {
        Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '009-never-on-disk', '--yes') | Out-Null
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'stops even when only one of several folders is unknown' {
        (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '003-alpha-report', '--spec', '009-never-on-disk', '--yes')).ExitCode |
            Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }
}

Describe 'scope is applied BEFORE label derivation (data-model §6)' {
    BeforeEach { $script:Mock = Start-JiraMock -ConfigJson $script:ShortOnly; $script:Work = New-MultiWorkdir }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'makes the short form unambiguous when only ONE 004 folder is in scope' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '004-beta-import', '--yes', '--json')).StdOut | ConvertFrom-Json
        @($j.adoption.bindings | Where-Object { $_.issue_key -eq 'ADO-40' }).Count | Should -Be 1
        @($j.adoption.refusals | Where-Object { $_.reason -eq 'ambiguous-short-number' }).Count | Should -Be 0
    }

    It 'makes it ambiguous again when BOTH 004 folders are in scope' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--spec', '004-beta-import', '--spec', '004-gamma-export', '--yes', '--json')
        $r.ExitCode | Should -Be 4
        $j = $r.StdOut | ConvertFrom-Json
        @($j.adoption.refusals | Where-Object { $_.reason -eq 'ambiguous-short-number' }).Count | Should -Be 2
        Get-PutCount | Should -Be 0
    }
}
