# T040 [US1] — The adopt command's two phases, PowerShell side. Mirror of
# tests/bash/commands/test_adopt.bats (003 FR-001, FR-006, FR-023).
#
# The command is driven through the REAL dispatcher in a child process, exactly
# as the conformance harness does, so the [Console]-stream contract and the
# numeric exit code are both exercised.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Entry = Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1'
    Import-Module (Join-Path $script:Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    $script:Corpus = @'
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
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($script:Entry)
        $psi.ArgumentList.Add('adopt')
        foreach ($a in $AdoptArgs) { $psi.ArgumentList.Add($a) }
        $psi.WorkingDirectory = $Workdir
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['SPEC_KIT_JIRA_BASE_URL'] = $script:Mock.BaseUrl
        $psi.EnvironmentVariables['JIRA_EMAIL'] = 'user@example.com'
        $psi.EnvironmentVariables['JIRA_API_TOKEN'] = 'RAWSECRETXYZ'
        $psi.EnvironmentVariables['JIRA_NO_SLEEP'] = '1'
        $psi.EnvironmentVariables['SPEC_KIT_JIRA_REPO'] = 'acme/app'
        foreach ($k in $Extra.Keys) { $psi.EnvironmentVariables[$k] = $Extra[$k] }
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
    }

    function Get-PutCount {
        return @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count
    }
}

Describe 'adopt phases' {
    BeforeEach {
        $script:Mock = Start-JiraMock -ConfigJson $script:Corpus
        $script:Work = New-AdoptWorkdir
    }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'short-circuits when adoption is disabled: exit 4, ZERO candidate reads' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes') -Extra @{ JIRA_CONFIG_DIR = '.specify/jira-disabled' }
        $r.ExitCode | Should -Be 4
        $r.StdErr | Should -BeLike '*adoption.enabled*'
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'prints the plan BEFORE any write' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes')
        $r.ExitCode | Should -Be 0
        $lines = $r.StdOut -split "`n"
        $planAt = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like 'Adoption plan*' })
        $sumAt = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like '*Updated: 7*' })
        $planAt | Should -BeGreaterOrEqual 0
        $sumAt | Should -BeGreaterThan $planAt
    }

    It 'lists one line per target with its key and reason' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')
        $r.StdOut | Should -BeLike '*003-label-based-adoption*ADO-1*adopt*(label match)*'
        $r.StdOut | Should -BeLike '*005-audit-trail:us1*'
    }

    It 'applies the plan with --yes' {
        (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes')).ExitCode | Should -Be 0
        Get-PutCount | Should -Be 7
    }

    It 'applies the plan on an affirmative answer' {
        $r = Invoke-Adopt -Workdir $script:Work -Extra @{ SPEC_KIT_JIRA_ADOPT_ANSWER = 'y' }
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike '*Apply this plan? [[]y/N]*'
        Get-PutCount | Should -Be 7
    }

    It 'treats a decline as an operator choice: exit 0, zero writes, cancellation reported' {
        $r = Invoke-Adopt -Workdir $script:Work -Extra @{ SPEC_KIT_JIRA_ADOPT_ANSWER = 'n' }
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike '*Adoption cancelled*'
        Get-PutCount | Should -Be 0
    }

    It 'declines on any non-affirmative answer (fail-closed)' {
        $r = Invoke-Adopt -Workdir $script:Work -Extra @{ SPEC_KIT_JIRA_ADOPT_ANSWER = 'maybe later' }
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike '*Adoption cancelled*'
        Get-PutCount | Should -Be 0
    }

    It 'names --yes and writes nothing when there is no terminal' {
        $r = Invoke-Adopt -Workdir $script:Work
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike '*--yes*'
        $r.StdOut | Should -BeLike '*no terminal is attached*'
        Get-PutCount | Should -Be 0
    }

    It 'never prompts and never writes on --dry-run' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Not -BeLike '*Apply this plan?*'
        $r.StdOut | Should -BeLike '*Dry run: nothing was written.*'
        Get-PutCount | Should -Be 0
    }

    It 'emits prose by default and the machine form only on --json' {
        (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')).StdOut | Should -BeLike 'Adoption plan*'
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).StdOut | ConvertFrom-Json
        $j.command | Should -Be 'adopt'
        $j.schema_version | Should -Be '1.0'
        $j.adoption.label_prefix | Should -Be 'speckit-adopt:'
    }

    It 'never carries the token or the site host at any verbosity (FR-025)' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--verbose', '--json')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Not -BeLike '*RAWSECRETXYZ*'
        $r.StdOut | Should -Not -BeLike '*127.0.0.1*'
    }
}

# T191 — nothing in scope (spec Edge Cases). A repository carrying no spec
# folder is not an error. The run completes, reads nothing, writes nothing —
# and SAYS so, rather than printing a bare header the operator is left to
# interpret as success (Constitution XVI).
Describe 'nothing in scope' {
    BeforeEach {
        $script:Mock = Start-JiraMock -ConfigJson $script:Corpus
        $script:Work = New-AdoptWorkdir
        # The repository with adoption enabled and not one spec folder.
        Remove-Item -Recurse -Force (Join-Path $script:Work 'specs') -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path (Join-Path $script:Work 'specs') -Force | Out-Null
    }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'exits 0 with zero reads and zero writes' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes')
        $r.ExitCode | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
        Get-PutCount | Should -Be 0
    }

    It 'states in the plan that nothing was found' {
        (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes')).StdOut |
            Should -BeLike '*nothing was found*'
    }

    It 'carries no binding, no refusal, and no out-of-scope folder' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')
        $r.ExitCode | Should -Be 0
        $j = $r.StdOut | ConvertFrom-Json
        @($j.adoption.bindings).Count | Should -Be 0
        @($j.adoption.refusals).Count | Should -Be 0
        @($j.adoption.out_of_scope).Count | Should -Be 0
    }
}

Describe 'a plan that DOES carry targets' {
    It 'never claims nothing was found' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Corpus
        $work = New-AdoptWorkdir
        try {
            (Invoke-Adopt -Workdir $work -AdoptArgs @('--dry-run')).StdOut |
                Should -Not -BeLike '*nothing was found*'
        }
        finally {
            Stop-JiraMock -Mock $script:Mock
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the dry-run twin is exact (FR-023, SC-003)' {
    It 'reports the same action set as the real run for the same state' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Corpus
        $work = New-AdoptWorkdir
        try {
            $dry = (Invoke-Adopt -Workdir $work -AdoptArgs @('--dry-run', '--json')).StdOut | ConvertFrom-Json
            $real = (Invoke-Adopt -Workdir $work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
            (ConvertTo-Json -InputObject $dry.actions -Depth 20 -Compress) |
                Should -Be (ConvertTo-Json -InputObject $real.actions -Depth 20 -Compress)
        }
        finally {
            Stop-JiraMock -Mock $script:Mock
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }
    }
}
