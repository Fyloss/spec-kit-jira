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
