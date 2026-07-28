# T017 [US1] — The official install alone registers the seven lifecycle events,
# PowerShell port. Twin of tests/bash/conformance/test_us1_install_hooks.bats
# (FR-001, FR-005, FR-006, SC-001, SC-004).
#
# This is the regression test for the reported defect, and it is the only kind of
# test that can be: the claim is about what `specify extension add` writes, so
# nothing short of running it into a real scratch repository verifies it. Every
# other test in this repository asserts what our code does with a registry that
# already exists.
#
# It skips with a clear reason when the `specify` CLI is absent — the CLI is a
# developer tool, not a runtime dependency of this extension.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    . (Join-Path $script:Root 'tests/conformance/InstallHarness.ps1')
    Import-Module (Join-Path $script:Root 'scripts/powershell/hooks/RegisterHooks.psm1') -Force
    $script:Events = @('before_specify', 'after_specify', 'after_clarify', 'after_plan',
        'after_tasks', 'after_implement', 'after_analyze')
    $script:Available = Test-HarnessAvailable
    $script:Skip = Get-HarnessSkipReason
    # Set even on the skip path below — AfterEach reads it under Set-StrictMode,
    # which throws on an unset variable rather than treating it as falsy.
    $script:Repo = $null
}

Describe 'The official install registers the hooks' {
    BeforeEach {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        $script:Repo = New-HarnessRepo
    }
    AfterEach {
        if ($script:Repo) { Remove-HarnessRepo -Repo $script:Repo }
    }

    It 'writes one jira entry per event, enabled and non-optional (FR-001, SC-001)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        Install-HarnessExtension -Repo $script:Repo
        foreach ($e in $script:Events) {
            $ours = @(Get-HarnessEntriesFor -Repo $script:Repo -LifecycleEvent $e | Where-Object { $_.Extension -eq 'jira' })
            $ours.Count | Should -Be 1 -Because "event $e must carry exactly one jira entry"
            $ours[0].Enabled | Should -BeTrue
            # Non-optional so the agent PERFORMS the hook rather than offering it.
            $ours[0].Optional | Should -BeFalse
        }
    }

    It 'needs no configuration ceremony for the hooks to be registered (SC-001)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        # The whole point: nothing but the install ran, and the registry is complete.
        Install-HarnessExtension -Repo $script:Repo
        $h = Get-JiraHookHealth -Path (Get-HarnessRegistryPath -Repo $script:Repo) | ConvertFrom-Json -Depth 100
        @($h.present).Count | Should -Be 7
        @($h.missing).Count | Should -Be 0
    }

    It 'produces no duplicates across two further --force reinstalls (FR-005, SC-004)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        Install-HarnessExtension -Repo $script:Repo
        Install-HarnessExtension -Repo $script:Repo -Force
        Install-HarnessExtension -Repo $script:Repo -Force
        foreach ($e in $script:Events) {
            $ours = @(Get-HarnessEntriesFor -Repo $script:Repo -LifecycleEvent $e | Where-Object { $_.Extension -eq 'jira' })
            $ours.Count | Should -Be 1 -Because "event $e must still carry exactly one jira entry"
        }
    }

    It 'leaves a pre-seeded foreign extension entry unchanged (FR-006)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-HarnessRegistry -Repo $script:Repo -Content @'
hooks:
  after_plan:
    - extension: git
      command: speckit.git.commit
      enabled: true
      optional: true
      priority: 10
      prompt: Execute speckit.git.commit?
      description: Commit the plan.
      condition: null
'@
        Install-HarnessExtension -Repo $script:Repo
        Install-HarnessExtension -Repo $script:Repo -Force

        $entries = @(Get-HarnessEntriesFor -Repo $script:Repo -LifecycleEvent 'after_plan')
        $foreign = @($entries | Where-Object { $_.Extension -eq 'git' })
        $foreign.Count | Should -Be 1
        $foreign[0].Command | Should -BeExactly 'speckit.git.commit'
        $foreign[0].Enabled | Should -BeTrue
        # Ours was added beside it, not instead of it.
        @($entries | Where-Object { $_.Extension -eq 'jira' }).Count | Should -Be 1
    }

    It 'names only commands the extension installs (FR-009, SC-002)' {
        if (-not $script:Available) { Set-ItResult -Skipped -Because $script:Skip; return }
        # The other half of the reported defect, verified end to end: after the
        # real install, every command a hook entry names has a document in the
        # installed tree.
        Install-HarnessExtension -Repo $script:Repo
        foreach ($e in $script:Events) {
            $cmd = @(Get-HarnessEntriesFor -Repo $script:Repo -LifecycleEvent $e | Where-Object { $_.Extension -eq 'jira' })[0].Command
            $cmd | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $script:Repo ".specify/extensions/jira/commands/$cmd.md") |
                Should -BeTrue -Because "event $e names $cmd, which must be installed"
        }
    }
}
