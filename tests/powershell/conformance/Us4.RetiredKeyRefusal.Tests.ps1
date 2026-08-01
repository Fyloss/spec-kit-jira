# T025 [Phase 3, US4] — mirror of tests/bash/conformance/test_us4_retired_key_refusal.bats.
# A retired key refuses exit 4 direct, naming the key; under a hook, one
# WARNING and exit 0.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Harness = Join-Path $script:Root 'tests/conformance/run-scenario.sh'
    $script:Scenario = Join-Path $script:Root 'tests/conformance/scenarios/us4-retired-key-refusal.json'
}

Describe 'The retired-key refusal (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'exit 4 direct, naming the retired key, zero writes' {
        $outDir = Join-Path $script:Tmp 'out-ps'
        & bash $script:Harness $script:Scenario 'powershell' $outDir | Out-Null
        (Get-Content -LiteralPath (Join-Path $outDir 'exit') -Raw).Trim() | Should -Be '4'
        (Get-Content -LiteralPath (Join-Path $outDir 'stderr') -Raw) | Should -Match 'epic_strategy'
        (Get-Item -LiteralPath (Join-Path $outDir 'calls.log')).Length | Should -Be 0
    }

    It 'under a hook: exactly one WARNING and exit 0' {
        $outDir = Join-Path $script:Tmp 'out-ps-hook'
        # Through the harness's named channel, not the ambient environment: the
        # harness scrubs every ambient SPEC_KIT_JIRA_* so that a variable a
        # previous test file forgot to clear can never decide this run's
        # outcome.
        $env:SPEC_KIT_JIRA_HARNESS_ENV = 'SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify'
        try {
            & bash $script:Harness $script:Scenario 'powershell' $outDir | Out-Null
        } finally {
            Remove-Item Env:\SPEC_KIT_JIRA_HARNESS_ENV -ErrorAction SilentlyContinue
        }
        (Get-Content -LiteralPath (Join-Path $outDir 'exit') -Raw).Trim() | Should -Be '0'
        $stderr = Get-Content -LiteralPath (Join-Path $outDir 'stderr') -Raw
        @([regex]::Matches($stderr, '(?m)^WARNING: ')).Count | Should -Be 1
        $stderr | Should -Match 'epic_strategy'
    }
}
