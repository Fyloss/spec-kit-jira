# T056 [US6] — The hook registry is byte-identical after every command in every
# documented state, PowerShell port. Twin of
# tests/bash/commands/test_registry_never_written.bats
# (FR-022, FR-023, SC-007, SC-012).
#
# This is the headline guarantee of the feature, and it is stated without
# exemption on purpose. The consuming project asked a direct question — does the
# configuration ceremony overwrite our `.specify/extensions.yml`? — and the honest
# answer required removing the writer rather than narrowing it.
#
# The seed is deliberately hostile to a round-trip: operator comments (which the
# reader drops), an unusual key order (which the writer would sort), and a
# foreign extension's entries (which a merge could reorder). If any command ever
# re-serialises this file, one of these WILL change.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $script:Root 'scripts/powershell/commands/Config.psm1') -Force
    Import-Module (Join-Path $script:Root 'scripts/powershell/commands/Reconcile.psm1') -Force
    Import-Module (Join-Path $script:Root 'scripts/powershell/lib/Config.psm1') -Force

    $script:Seed = @'
# Our team's hook registry. Please keep the comments — they are the only record
# of why after_implement is off.
installed:
- jira
- git
settings:
  auto_execute_hooks: true
hooks:
  after_plan:
  - extension: git          # the other extension's entry, and it stays put
    command: speckit.git.commit
    enabled: true
  - extension: jira
    command: speckit.jira.reconcile
    enabled: true
    optional: false
    priority: 10
    prompt: Execute speckit.jira.reconcile?
    description: Mirror the implementation plan into Jira Cloud.
    condition: null
  before_specify:
  - extension: jira
    command: speckit.jira.feature
    enabled: true
    optional: false
    priority: 10
    prompt: Execute speckit.jira.feature?
    description: Resolve the Jira ticket and name the feature before creation.
    condition: null
'@

    function Invoke-EveryCommand {
        # The ceremony and the reconcile entry point, in both real and dry-run
        # form. Failures are expected in several states and are irrelevant: what
        # is under test is the file, not the exit code.
        param([string] $Spec)
        $sw = [System.IO.StringWriter]::new(); $orig = [Console]::Out; [Console]::SetOut($sw)
        try {
            try { $null = Invoke-JiraConfig -Arguments @('config', '--json') } catch { }
            try { $null = Invoke-JiraConfig -Arguments @('config', '--dry-run', '--json') } catch { }
            try { $null = Invoke-JiraReconcile -Arguments @('reconcile', '--json', $Spec) } catch { }
            try { $null = Invoke-JiraReconcile -Arguments @('reconcile', '--dry-run', '--json', $Spec) } catch { }
        }
        finally { [Console]::SetOut($orig) }
    }
}

Describe 'The registry is never written (FR-022, SC-007, SC-012)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $script:Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $script:Work '.specify/extensions.yml'
        $script:Ext = $env:SPEC_KIT_JIRA_EXTENSIONS_YML

        # A minimal committed config so the ceremony gets past its config read.
        Set-Content -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -NoNewline `
            -Value "projects:`n  - key: TEAM`n    epic_strategy: per_repo`n    task_strategy: subtask`nrouting_default: TEAM`n"

        $script:Spec = Join-Path $script:Work 'spec.md'
        @(
            '# Feature Specification: Untouched', '', 'A spec that mirrors to Jira.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a user', '- **When** they act', '- **Then** it works'
        ) -join "`n" | Set-Content -LiteralPath $script:Spec -NoNewline

        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_EXTENSIONS_YML -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'leaves a healthy registry byte-identical (SC-007)' {
        $complete = $script:Seed
        foreach ($e in @('after_specify', 'after_clarify', 'after_tasks', 'after_implement', 'after_analyze')) {
            $complete += "  ${e}:`n  - extension: jira`n    command: speckit.jira.reconcile`n    enabled: true`n    optional: false`n    priority: 10`n    prompt: Execute speckit.jira.reconcile?`n    description: Mirror.`n    condition: null`n"
        }
        [System.IO.File]::WriteAllText($script:Ext, $complete, (New-Object System.Text.UTF8Encoding($false)))
        $before = Get-Content -Raw -LiteralPath $script:Ext
        Invoke-EveryCommand -Spec $script:Spec
        (Get-Content -Raw -LiteralPath $script:Ext) | Should -BeExactly $before
    }

    It 'leaves an incomplete registry byte-identical — reported, never registered (FR-025)' {
        [System.IO.File]::WriteAllText($script:Ext, $script:Seed, (New-Object System.Text.UTF8Encoding($false)))
        $before = Get-Content -Raw -LiteralPath $script:Ext
        Invoke-EveryCommand -Spec $script:Spec
        (Get-Content -Raw -LiteralPath $script:Ext) | Should -BeExactly $before
    }

    It 'records a disabled entry in OUR file and leaves the registry alone (FR-007)' {
        [System.IO.File]::WriteAllText($script:Ext, ($script:Seed -replace '(?m)^    enabled: true$', '    enabled: false'), (New-Object System.Text.UTF8Encoding($false)))
        $before = Get-Content -Raw -LiteralPath $script:Ext
        Invoke-EveryCommand -Spec $script:Spec
        (Get-Content -Raw -LiteralPath $script:Ext) | Should -BeExactly $before
        # The decision was captured — in the local binding, not by editing the registry.
        @((Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | ConvertFrom-Json).Count |
            Should -BeGreaterThan 0
    }

    It 'leaves a leftover pre-manifest entry in place — reported, never removed (FR-028)' {
        $seeded = $script:Seed + "  after_tasks:`n  - command: speckit.jira.reconcile`n    enabled: true`n    optional: true`n"
        [System.IO.File]::WriteAllText($script:Ext, $seeded, (New-Object System.Text.UTF8Encoding($false)))
        $before = Get-Content -Raw -LiteralPath $script:Ext
        Invoke-EveryCommand -Spec $script:Spec
        (Get-Content -Raw -LiteralPath $script:Ext) | Should -BeExactly $before
    }

    It 'leaves an unreadable registry byte-identical — reported, never rewritten (FR-024)' {
        $broken = "# a file we cannot read, and must not touch`nhooks:`n  after_plan: &anchor`n    - extension: jira`n"
        [System.IO.File]::WriteAllText($script:Ext, $broken, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-EveryCommand -Spec $script:Spec
        (Get-Content -Raw -LiteralPath $script:Ext) | Should -BeExactly $broken
    }

    It 'leaves the registry alone in a repository that is not configured (SC-007)' {
        [System.IO.File]::WriteAllText($script:Ext, $script:Seed, (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item -Force (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')
        $before = Get-Content -Raw -LiteralPath $script:Ext
        Invoke-EveryCommand -Spec $script:Spec
        (Get-Content -Raw -LiteralPath $script:Ext) | Should -BeExactly $before
    }

    It "preserves the operator's comments, key order and foreign entries (SC-012)" {
        [System.IO.File]::WriteAllText($script:Ext, $script:Seed, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-EveryCommand -Spec $script:Spec
        $text = Get-Content -Raw -LiteralPath $script:Ext
        $text | Should -Match 'Please keep the comments'
        $text | Should -Match ([regex]::Escape("the other extension's entry, and it stays put"))
        $text | Should -Match 'command: speckit\.git\.commit'
        # `installed` before `settings` before `hooks` — not the order our
        # serialiser would produce, so a re-serialisation would show up here.
        $order = ([regex]::Matches($text, '(?m)^(installed|settings|hooks):') | ForEach-Object { $_.Groups[1].Value }) -join ' '
        $order | Should -BeExactly 'installed settings hooks'
    }

    It 'CREATES no registry when it is absent (FR-022)' {
        Remove-Item -Force $script:Ext -ErrorAction SilentlyContinue
        Invoke-EveryCommand -Spec $script:Spec
        Test-Path -LiteralPath $script:Ext | Should -BeFalse
    }
}
