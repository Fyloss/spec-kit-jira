# T032 [US3] — Every registered hook resolves to a real command, PowerShell port.
# Twin of tests/bash/ci/test_hook_command_resolution.bats.
#
# The second half of the reported defect. `extension.yml` declared two commands;
# the registrar registered `speckit.jira-mirror.reconcile` under all six after_* events.
# That command had NO file, NO manifest entry, and was not installed — so even a
# correctly registered, correctly dispatched hook resolved to nothing.
#
# Three sets must agree, and nothing at runtime checks that they do: the
# `command` of every hook entry, the `name` of every declared command, and the
# files in `commands/`.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:ManifestLines = (Get-Content -Raw -LiteralPath (Join-Path $script:Root 'extension.yml')) -split "`r?`n"

    function Get-DeclaredCommands {
        $out = [System.Collections.Generic.List[string]]::new()
        $inProvides = $false
        foreach ($line in $script:ManifestLines) {
            if ($line -match '^provides:') { $inProvides = $true; continue }
            if ($inProvides -and $line -match '^[^\s#]') { $inProvides = $false }
            if ($inProvides -and $line -match '^\s+- name:\s*(\S+)\s*$') { $out.Add($Matches[1]) }
        }
        return $out.ToArray()
    }

    function Get-DeclaredCommandFiles {
        $out = [System.Collections.Generic.List[string]]::new()
        $inProvides = $false
        foreach ($line in $script:ManifestLines) {
            if ($line -match '^provides:') { $inProvides = $true; continue }
            if ($inProvides -and $line -match '^[^\s#]') { $inProvides = $false }
            if ($inProvides -and $line -match '^\s+file:\s*(\S+)\s*$') { $out.Add($Matches[1]) }
        }
        return $out.ToArray()
    }

    function Get-HookCommands {
        $out = [System.Collections.Generic.List[string]]::new()
        $inHooks = $false
        foreach ($line in $script:ManifestLines) {
            if ($line -match '^hooks:') { $inHooks = $true; continue }
            if ($inHooks -and $line -match '^[^\s#]') { $inHooks = $false }
            if ($inHooks -and $line -match '^\s+command:\s*(\S+)\s*$') { $out.Add($Matches[1]) }
        }
        return $out.ToArray()
    }
}

Describe 'Hook command resolution (SC-002)' {
    It 'matches every hooks[].command to a provides.commands[].name exactly' {
        $declared = Get-DeclaredCommands
        $declared.Count | Should -BeGreaterThan 0
        foreach ($cmd in (Get-HookCommands)) {
            $declared | Should -Contain $cmd
        }
    }

    It "finds every declared command's file on disk (research R7)" {
        foreach ($f in (Get-DeclaredCommandFiles)) {
            Test-Path -LiteralPath (Join-Path $script:Root $f) | Should -BeTrue
        }
    }

    It 'matches every document front-matter name to its manifest declaration' {
        # A document whose front matter disagrees with the manifest is registered
        # under one name and answers to another — the same class of unresolvable
        # reference, one level down.
        $names = Get-DeclaredCommands
        $files = Get-DeclaredCommandFiles
        $names.Count | Should -Be $files.Count
        for ($i = 0; $i -lt $names.Count; $i++) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $script:Root $files[$i])
            $text | Should -Match ('(?m)^name:\s*"' + [regex]::Escape($names[$i]) + '"\s*$')
        }
    }

    It 'declares, files and references speckit.jira-mirror.reconcile (FR-010, FR-011)' {
        # The command that did not exist. Named explicitly because it is THE
        # finding of research R7 and the co-requisite of the manifest hook block.
        (Get-DeclaredCommands) | Should -Contain 'speckit.jira-mirror.reconcile'
        Test-Path -LiteralPath (Join-Path $script:Root 'commands/speckit.jira-mirror.reconcile.md') | Should -BeTrue
        (Get-HookCommands) | Should -Contain 'speckit.jira-mirror.reconcile'
    }

    It 'uses the canonical speckit.<ext>.<name> form, never the auto-lifted short form' {
        foreach ($cmd in (Get-HookCommands)) {
            $cmd | Should -BeLike 'speckit.jira-mirror.*'
        }
    }

    It 'declares every file in commands/ — nothing ships unregistered' {
        $declared = Get-DeclaredCommandFiles
        foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $script:Root 'commands') -Filter '*.md')) {
            $declared | Should -Contain "commands/$($f.Name)"
        }
    }
}
