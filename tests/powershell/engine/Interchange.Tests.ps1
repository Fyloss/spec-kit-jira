# T020 — Neutral-interchange schema validation, PowerShell side.
# Mirror of tests/bash/engine/test_interchange.bats. Cross-port agreement proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Interchange.psm1') -Force
    $ValidPath = Join-Path $PSScriptRoot '../../conformance/fixtures/neutral-valid.json'
    $script:Valid = Get-Content -Raw $ValidPath
}

Describe 'Test-JiraInterchange' {
    It 'accepts a well-formed document' {
        Test-JiraInterchange $script:Valid | Should -BeTrue
    }

    It 'rejects a wrong schema_version' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.schema_version = '2.0'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects a malformed spec_slug' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.spec_ref.spec_slug = 'bad slug'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects an invalid project_key' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.routing.project_key = 'proj-1'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects an empty stories array' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.stories = @()
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects invalid JSON input' {
        Test-JiraInterchange 'not json' 2>$null | Should -BeFalse
    }

    It 'rejects a case-variant priority_logical like the Bash port — "p1" is not "P1" (NFR-1)' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.stories[0].priority_logical = 'p1'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects a case-variant epic.strategy like the Bash port — "Per_repo" is not "per_repo" (NFR-1)' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.epic.strategy = 'Per_repo'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }
}
