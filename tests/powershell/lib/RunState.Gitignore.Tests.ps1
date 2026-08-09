# T025 [Phase 4, US2] — Pester twin of tests/bash/lib/test_run_state_gitignore.bats.
# contracts/run-state.md §6/FR-026: `git status --porcelain` stays clean after
# the state directory is written, even in a repository whose root
# `.gitignore` predates this feature, because Save-JiraRunState writes its own
# self-ignoring `.gitignore` before writing the state document.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '../../../scripts/powershell/lib/RunState.psm1'
    Import-Module $ModulePath -Force
}

Describe 'RunState gitignore' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        & git -C $script:Work init -q

        # Deliberately predates this feature: no mention of .specify/jira/state.
        [System.IO.File]::WriteAllText((Join-Path $script:Work '.gitignore'), "node_modules/`n*.log`n")
        New-Item -ItemType Directory -Path (Join-Path $script:Work 'specs/021-example') -Force | Out-Null
        $script:Spec = Join-Path $script:Work 'specs/021-example/spec.md'
        [System.IO.File]::WriteAllText($script:Spec, "# Feature Specification: Example`n")

        & git -C $script:Work add -A
        & git -C $script:Work -c user.name=Test -c user.email=test@example.com commit -q -m initial

        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }

    AfterEach {
        Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'T025 — git status --porcelain stays clean after the state directory is written' {
        (& git -C $script:Work status --porcelain) | Should -BeNullOrEmpty

        Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'

        Test-Path -LiteralPath (Join-Path $script:Work '.specify/jira/state/.gitignore') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:Work '.specify/jira/state/021-example.json') | Should -Be $true
        (& git -C $script:Work status --porcelain) | Should -BeNullOrEmpty
    }
}
