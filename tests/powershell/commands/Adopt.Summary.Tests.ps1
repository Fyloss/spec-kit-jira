# T141 [US5] — The adoption run summary, PowerShell side. Mirror of
# tests/bash/commands/test_adopt_summary.bats (003 FR-024, NFR-4).
#
# Prose is the default (Principle XVI); `--json` is the opt-in machine form and
# must satisfy the 001 run-summary schema plus the 003 adoption delta — a CLOSED
# object, so a stray key is a failure rather than a harmless extra.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Entry = Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1'
    $script:AdoptSchema = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'specs/003-label-based-adoption/contracts/adoption-plan.schema.json') | ConvertFrom-Json
    $script:RunSchema = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'specs/001-jira-reconcile-engine/contracts/run-summary.schema.json') | ConvertFrom-Json
    Import-Module (Join-Path $script:Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    # Bindings AND refusals in one run, so both halves of the summary are populated.
    $script:Mixed = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
  "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
  "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
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
}

Describe 'the adoption run summary' {
    BeforeEach { $script:Mock = Start-JiraMock -ConfigJson $script:Mixed; $script:Work = New-AdoptWorkdir }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'carries the run-summary core with command adopt' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $j.schema_version | Should -Be '1.0'
        $j.command | Should -Be 'adopt'
        (($j.counts.PSObject.Properties.Name | Sort-Object) -join ',') | Should -Be 'created,errors,skipped,updated,warnings'
        $j.PSObject.Properties.Name | Should -Contain 'exit_code'
        @($script:RunSchema.properties.command.enum) | Should -Contain 'adopt'
    }

    It 'reports adopted, skipped and refused counts (FR-024)' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $j.counts.updated | Should -Be @($j.adoption.bindings | Where-Object { $_.status -eq 'adopt' }).Count
        $j.counts.skipped | Should -Be @($j.adoption.bindings | Where-Object { $_.status -eq 'already-adopted' }).Count
        $j.counts.errors | Should -Be @($j.adoption.refusals).Count
        $j.counts.created | Should -Be 0
    }

    It 'emits exactly the adoption block the schema declares (closed)' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $required = (@($script:AdoptSchema.required) | Sort-Object) -join ','
        (($j.adoption.PSObject.Properties.Name | Sort-Object) -join ',') | Should -Be $required
        $script:AdoptSchema.additionalProperties | Should -BeFalse
    }

    It 'gives every applied binding a reason from the closed enum (FR-024)' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $allowed = @($script:AdoptSchema.properties.bindings.items.properties.reason.enum)
        ($allowed -join ',') | Should -Be 'label-match,explicit-binding'
        foreach ($b in @($j.adoption.bindings)) { $allowed | Should -Contain $b.reason }
    }

    It 'gives every refusal a message, a remediation and a closed reason (SC-005)' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        @($j.adoption.refusals).Count | Should -BeGreaterThan 0
        $closed = @($script:AdoptSchema.properties.refusals.items.properties.reason.enum)
        foreach ($r in @($j.adoption.refusals)) {
            $r.message | Should -Not -BeNullOrEmpty
            $r.remediation | Should -Not -BeNullOrEmpty
            $closed | Should -Contain $r.reason
        }
    }

    It 'matches the schema key set for every binding and every refusal' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $bindKeys = (@($script:AdoptSchema.properties.bindings.items.properties.PSObject.Properties.Name) | Sort-Object) -join ','
        foreach ($b in @($j.adoption.bindings)) {
            (($b.PSObject.Properties.Name | Sort-Object) -join ',') | Should -Be $bindKeys
        }
        $refKeys = (@($script:AdoptSchema.properties.refusals.items.properties.PSObject.Properties.Name) | Sort-Object) -join ','
        foreach ($r in @($j.adoption.refusals)) {
            (($r.PSObject.Properties.Name | Sort-Object) -join ',') | Should -Be $refKeys
        }
    }

    It 'reports the effective configuration and the confirmation' {
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--yes', '--json')).StdOut | ConvertFrom-Json
        $j.adoption.enabled | Should -BeTrue
        $j.adoption.label_prefix | Should -Be 'speckit-adopt:'
        $j.adoption.confirmed | Should -BeTrue
    }

    It 'emits PROSE by default, not JSON (Principle XVI)' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')
        $r.StdOut | Should -BeLike 'Adoption plan*'
        { $r.StdOut | ConvertFrom-Json -ErrorAction Stop } | Should -Throw
    }

    It 'renders one remediation line per refusal in the prose' {
        $r = Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run')
        $j = (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).StdOut | ConvertFrom-Json
        $r.StdOut | Should -BeLike '*REFUSED*'
        @(($r.StdOut -split "`n") | Where-Object { $_ -like '      remediation: *' }).Count |
            Should -Be @($j.adoption.refusals).Count
    }

    It 'is deterministic — the same state emits the same bytes' {
        (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).StdOut |
            Should -Be (Invoke-Adopt -Workdir $script:Work -AdoptArgs @('--dry-run', '--json')).StdOut
    }
}
