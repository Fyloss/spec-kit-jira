# T015 [US1] — The manifest's hook declaration, PowerShell port.
# Twin of tests/bash/ci/test_manifest_hooks.bats.
#
# This is the check that would have caught the reported defect at its source:
# `extension.yml` had no `hooks:` block at all, so `specify extension add`
# registered nothing and the extension was inert from install. Every property
# asserted here fails SILENTLY in production — a misplaced block still
# validates, an `optional: true` entry is merely printed rather than performed,
# and a `condition` makes the agent skip the hook without a word.
#
# The manifest is parsed with line matching rather than with the extension's own
# YAML reader: extension.yml uses `>-` folded block scalars, which that reader's
# restricted subset does not model.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:ManifestPath = Join-Path $script:Root 'extension.yml'
    $script:ManifestLines = (Get-Content -Raw -LiteralPath $script:ManifestPath) -split "`r?`n"
    Import-Module (Join-Path $script:Root 'scripts/powershell/lib/Config.psm1') -Force

    function Get-ManifestBlock {
        # The lines of a top-level block, excluding its header. A block runs
        # until the next line that starts in column 0.
        param([Parameter(Mandatory)] [string] $Key)
        $out = [System.Collections.Generic.List[string]]::new()
        $inBlock = $false
        foreach ($line in $script:ManifestLines) {
            if ($line -match "^$Key`:\s*$") { $inBlock = $true; continue }
            if ($inBlock -and $line -match '^[^\s#]') { $inBlock = $false }
            if ($inBlock) { $out.Add($line) }
        }
        return $out.ToArray()
    }

    function Get-HookEvents {
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-ManifestBlock -Key 'hooks')) {
            if ($line -match '^  ([A-Za-z_]+):\s*$') { $out.Add($Matches[1]) }
        }
        return $out.ToArray()
    }

    function Get-HookCommandFor {
        param([Parameter(Mandatory)] [string] $LifecycleEvent)
        $inEvent = $false
        foreach ($line in (Get-ManifestBlock -Key 'hooks')) {
            if ($line -match "^  $LifecycleEvent`:\s*$") { $inEvent = $true; continue }
            if ($inEvent -and $line -match '^  [A-Za-z_]+:') { $inEvent = $false }
            if ($inEvent -and $line -match '^\s+command:\s*(\S+)\s*$') { return $Matches[1] }
        }
        return $null
    }
}

Describe 'Placement (research R1)' {
    It 'declares hooks: as a TOP-LEVEL key' {
        @($script:ManifestLines | Where-Object { $_ -match '^hooks:\s*$' }).Count | Should -Be 1
    }

    It 'does NOT nest hooks: under provides: — a nested block validates and registers nothing' {
        $inProvides = $false
        $nested = $false
        foreach ($line in $script:ManifestLines) {
            if ($line -match '^provides:') { $inProvides = $true; continue }
            if ($inProvides -and $line -match '^[^\s#]') { $inProvides = $false }
            if ($inProvides -and $line -match '^\s+hooks:') { $nested = $true }
        }
        $nested | Should -BeFalse
    }
}

Describe 'Coverage (research R9)' {
    It 'declares exactly the seven events, no more and no fewer' {
        ((Get-HookEvents) | Sort-Object) -join ' ' |
            Should -BeExactly 'after_analyze after_clarify after_implement after_plan after_specify after_tasks before_specify'
    }

    It 'fires the feature command from before_specify and reconcile from every after_*' {
        Get-HookCommandFor -LifecycleEvent 'before_specify' | Should -BeExactly 'speckit.jira-mirror.feature'
        foreach ($e in @('after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_implement', 'after_analyze')) {
            Get-HookCommandFor -LifecycleEvent $e | Should -BeExactly 'speckit.jira-mirror.reconcile'
        }
    }

    It 'agrees with the PORT declaration (034 FR-009)' {
        # An event added to one and forgotten in the other ships half-wired. The
        # consequence changed with 034 but the check did not lose its point: it
        # used to guard the hook-registry reader's classified set, which is
        # deleted. It now guards $script:JiraHookEventNames in lib/Config.psm1 —
        # the surviving declaration, whose six after-events are the closed key
        # set phase_status_map is validated against (023,
        # contracts/role-lifecycle-config.md §2). A manifest event missing from
        # that array would be registered by the host and then rejected by our
        # own schema.
        ((Get-HookEvents) | Sort-Object) -join ' ' |
            Should -BeExactly (((Get-JiraHookEventNameList) | Sort-Object) -join ' ')
    }
}

Describe 'Dispatch and condition (research R4, R8)' {
    It 'declares optional: false on every entry' {
        $block = Get-ManifestBlock -Key 'hooks'
        @($block | Where-Object { $_ -match '^\s+optional:\s*false\s*$' }).Count | Should -Be (Get-HookEvents).Count
        @($block | Where-Object { $_ -match '^\s+optional:\s*true' }).Count | Should -Be 0
    }

    It 'declares no condition — it would suppress agent dispatch' {
        @((Get-ManifestBlock -Key 'hooks') | Where-Object { $_ -match '^\s+condition:' }).Count | Should -Be 0
    }

    It 'declares no priority or prompt — the host writes its defaults' {
        @((Get-ManifestBlock -Key 'hooks') | Where-Object { $_ -match '^\s+(priority|prompt):' }).Count | Should -Be 0
    }

    It 'carries a human-readable description on every entry (Principle XVI)' {
        @((Get-ManifestBlock -Key 'hooks') | Where-Object { $_ -match '^\s+description:\s*\S' }).Count |
            Should -Be (Get-HookEvents).Count
    }
}
