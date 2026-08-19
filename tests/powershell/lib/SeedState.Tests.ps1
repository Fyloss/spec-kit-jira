# T049/T052 [027] — Pester twin of test_seed_state.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/SeedState.psm1') -Force

    function New-SeedTestWork {
        $work = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        $specDir = Join-Path $work 'specs/001-add-payment-webhooks'
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        $spec = Join-Path $specDir 'spec.md'
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n"
        return [pscustomobject]@{ Work = $work; Spec = $spec }
    }

    function New-SeedRecordFile([string] $Key) {
        Set-Content -NoNewline -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR "state/$Key.seed.json") -Value '{}'
    }

    function Get-SpecPathIn([string] $FeatureDir) {
        return (Join-Path $script:Ctx.Work "specs/$FeatureDir/spec.md")
    }

    $script:DesignatorsJson = '[{"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
}

Describe 'Get-JiraSeedStatePath' {
    It 'is a sibling of the run-state path, suffixed .seed.json' {
        $ctx = New-SeedTestWork
        $p = Get-JiraSeedStatePath -SpecPath $ctx.Spec
        $p | Should -Be (Join-Path $env:JIRA_CONFIG_DIR 'state/001-add-payment-webhooks.seed.json')
    }
}

Describe 'New-JiraSeedStateDocument (S-1)' {
    It 'carries bindings: [] and the ordered designator set' {
        $doc = New-JiraSeedStateDocument -Slug 'ijt-add-payment-webhooks' -DesignatorsJson $script:DesignatorsJson -PlanDigest ''
        $obj = $doc | ConvertFrom-Json
        $obj.schema_version | Should -Be 1
        $obj.slug | Should -Be 'ijt-add-payment-webhooks'
        @($obj.bindings).Count | Should -Be 0
        @($obj.designators).Count | Should -Be 2
    }
}

Describe 'Save/Read/Remove round-trip' {
    It 'round-trips the exact document' {
        $ctx = New-SeedTestWork
        $doc = New-JiraSeedStateDocument -Slug 'ijt-add-payment-webhooks' -DesignatorsJson $script:DesignatorsJson -PlanDigest ''
        Save-JiraSeedState -SpecPath $ctx.Spec -DocumentJson $doc
        $read = Read-JiraSeedState -SpecPath $ctx.Spec
        $read | Should -Be $doc
    }

    It 'reading an absent record returns $null' {
        $ctx = New-SeedTestWork
        Read-JiraSeedState -SpecPath $ctx.Spec | Should -BeNullOrEmpty
    }

    It 'Remove-JiraSeedState deletes the record' {
        $ctx = New-SeedTestWork
        $doc = New-JiraSeedStateDocument -Slug 'ijt-add-payment-webhooks' -DesignatorsJson $script:DesignatorsJson -PlanDigest ''
        Save-JiraSeedState -SpecPath $ctx.Spec -DocumentJson $doc
        Remove-JiraSeedState -SpecPath $ctx.Spec
        Read-JiraSeedState -SpecPath $ctx.Spec | Should -BeNullOrEmpty
    }
}

Describe 'S-9: gitignored' {
    It 'the state directory carries a self-ignoring .gitignore' {
        $ctx = New-SeedTestWork
        $doc = New-JiraSeedStateDocument -Slug 'ijt-add-payment-webhooks' -DesignatorsJson $script:DesignatorsJson -PlanDigest ''
        Save-JiraSeedState -SpecPath $ctx.Spec -DocumentJson $doc
        $gi = Join-Path (Split-Path -Parent (Get-JiraSeedStatePath -SpecPath $ctx.Spec)) '.gitignore'
        Test-Path -LiteralPath $gi | Should -Be $true
        (Get-Content -Raw -LiteralPath $gi) | Should -Match '\*'
    }
}

Describe 'Test-JiraSeedStateDesignatorsEqual (§3/FR-041)' {
    It 'identical two-item sets compare equal' {
        Test-JiraSeedStateDesignatorsEqual -RecordedJson $script:DesignatorsJson -CurrentJson $script:DesignatorsJson | Should -Be $true
    }

    It "a SINGLE-designator set compares equal to itself (regression: PowerShell's single-element array collapse)" {
        $a = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
        $b = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
        Test-JiraSeedStateDesignatorsEqual -RecordedJson $a -CurrentJson $b | Should -Be $true
    }

    It 'a single differing story key compares unequal' {
        $a = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
        $b = '[{"role":"story","form":"key","key":"PROJ-99","raw":"PROJ-99","position":0}]'
        Test-JiraSeedStateDesignatorsEqual -RecordedJson $a -CurrentJson $b | Should -Be $false
    }

    It 'S-3: a key and its URL for the same issue compare equal' {
        $a = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
        $b = '[{"role":"story","form":"url","key":"PROJ-11","raw":"https://example.com/browse/PROJ-11","position":0}]'
        Test-JiraSeedStateDesignatorsEqual -RecordedJson $a -CurrentJson $b | Should -Be $true
    }

    It 'S-4: reordered story keys compare unequal' {
        $a = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]'
        $b = '[{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":1}]'
        Test-JiraSeedStateDesignatorsEqual -RecordedJson $a -CurrentJson $b | Should -Be $false
    }

    It 'a free-text specification-role value compares byte-equal' {
        $a = '[{"role":"specification","form":"free_text","raw":"Payment webhooks","text":"Payment webhooks","position":0}]'
        $b = '[{"role":"specification","form":"free_text","raw":"Payment webhooks","text":"Payment webhooks","position":0}]'
        Test-JiraSeedStateDesignatorsEqual -RecordedJson $a -CurrentJson $b | Should -Be $true
        $c = '[{"role":"specification","form":"free_text","raw":"Payment webhooks!","text":"Payment webhooks!","position":0}]'
        Test-JiraSeedStateDesignatorsEqual -RecordedJson $a -CurrentJson $c | Should -Be $false
    }
}

Describe 'New-JiraSeedStateDocument: a single-item designators array survives round-trip' {
    It "does not collapse a one-element designators array to a bare object (regression)" {
        $one = '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson $one -PlanDigest ''
        $parsed = $doc | ConvertFrom-Json
        ($parsed.designators -is [array]) | Should -Be $true
        @($parsed.designators).Count | Should -Be 1
    }
}

Describe 'Get-JiraSeedStateRecordKey — the record key vs the directory the host creates' {
    # `feature` writes the record under the resolved short name; spec-kit's
    # create-new-feature.sh then creates `specs/<FEATURE_NUM>-<short-name>`
    # and truncates the suffix past its branch-length cap.
    BeforeEach {
        $script:Ctx = New-SeedTestWork
        New-Item -ItemType Directory -Path (Join-Path $env:JIRA_CONFIG_DIR 'state') -Force | Out-Null
    }

    It 'an exact match wins outright' {
        New-SeedRecordFile '001-add-payment-webhooks'
        Get-JiraSeedStateRecordKey -SpecPath $script:Ctx.Spec | Should -Be '001-add-payment-webhooks'
    }

    It "the host's NNN- numbering is stripped" {
        New-SeedRecordFile 'ijt-42'
        Get-JiraSeedStateRecordKey -SpecPath (Get-SpecPathIn '022-ijt-42') | Should -Be 'ijt-42'
    }

    It "the host's timestamp numbering is stripped" {
        New-SeedRecordFile 'ijt-42'
        Get-JiraSeedStateRecordKey -SpecPath (Get-SpecPathIn '20260818-150950-ijt-42') | Should -Be 'ijt-42'
    }

    It 'a suffix the host truncated still resolves' {
        New-SeedRecordFile 'ijt-a-very-long-feature-short-name'
        Get-JiraSeedStateRecordKey -SpecPath (Get-SpecPathIn '022-ijt-a-very-long-feature') |
            Should -Be 'ijt-a-very-long-feature-short-name'
    }

    It 'a one- or two-digit prefix is NOT the host''s numbering' {
        # Every non-timestamp path in create-new-feature.sh ends at
        # `printf "%03d"`, an explicit `--number 1` included, so a shorter
        # prefix is part of the name rather than numbering.
        New-SeedRecordFile 'ijt-42'
        Get-JiraSeedStateRecordKey -SpecPath (Get-SpecPathIn '1-ijt') | Should -Be '1-ijt'
        Get-JiraSeedStateRecordKey -SpecPath (Get-SpecPathIn '22-ijt') | Should -Be '22-ijt'
    }

    It 'two candidates resolve to nothing rather than the wrong one' {
        New-SeedRecordFile 'ijt-42'
        New-SeedRecordFile 'ijt-42-extra'
        Get-JiraSeedStateRecordKey -SpecPath (Get-SpecPathIn '022-ijt-42') | Should -Be '022-ijt-42'
    }

    It 'no record at all resolves to the directory itself' {
        Get-JiraSeedStateRecordKey -SpecPath (Get-SpecPathIn '022-ijt-42') | Should -Be '022-ijt-42'
    }

    It 'Read-JiraSeedState finds the record moment 1 wrote under the un-numbered name' {
        $doc = New-JiraSeedStateDocument -Slug 'ijt-42' -DesignatorsJson $script:DesignatorsJson -PlanDigest ''
        Save-JiraSeedState -SpecPath (Join-Path $script:Ctx.Work 'specs/ijt-42/spec.md') -DocumentJson $doc
        $read = Read-JiraSeedState -SpecPath (Get-SpecPathIn '022-ijt-42')
        ($read | ConvertFrom-Json).slug | Should -Be 'ijt-42'
    }

    It 'Remove-JiraSeedState removes the record the read resolved, not a phantom' {
        $doc = New-JiraSeedStateDocument -Slug 'ijt-42' -DesignatorsJson $script:DesignatorsJson -PlanDigest ''
        Save-JiraSeedState -SpecPath (Join-Path $script:Ctx.Work 'specs/ijt-42/spec.md') -DocumentJson $doc
        Remove-JiraSeedState -SpecPath (Get-SpecPathIn '022-ijt-42')
        (Test-Path -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'state/ijt-42.seed.json')) | Should -BeFalse
    }
}
