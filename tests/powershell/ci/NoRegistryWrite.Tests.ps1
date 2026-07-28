# T058 [US6] — No code path in the PowerShell port can open the hook registry for
# writing (FR-022, SC-011). Twin of tests/bash/ci/test_no_registry_write.bats.
#
# This is the mechanical enforcement of the feature's load-bearing constraint.
# The behavioural test (RegistryNeverWritten.Tests.ps1) proves the registry is
# byte-identical after every documented state; this one proves something the
# behavioural test cannot, because no suite enumerates every future state: that
# the CAPABILITY to write it does not exist in the source at all.
#
# It exists because the guarantee has to survive people. A later feature adding
# "just one small write" in good faith — to repair a missing entry, to realign a
# field, to migrate a leftover — would pass every behavioural test that does not
# happen to exercise its trigger. This check fails the build the moment the
# construct appears, whether or not anything calls it.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Files = Get-ChildItem -LiteralPath (Join-Path $script:Root 'scripts/powershell') -Recurse -Include '*.psm1', '*.ps1' -File

    # Everything that could denote the registry: the literal path, the environment
    # override, and the local names the code uses for it.
    $script:RegistryToken = 'extensions\.yml|SPEC_KIT_JIRA_EXTENSIONS_YML|\$extPath|\$RegistryPath'

    # The PowerShell write verbs, plus redirection and the .NET writers.
    $script:WriteVerb = 'Set-Content|Out-File|Add-Content|Move-Item|Remove-Item|Clear-Content|New-Item|WriteAllText|WriteAllLines|AppendAllText|\]::Create\('

    function Select-CodeLine {
        # Every non-comment line of every port module, with its origin.
        foreach ($f in $script:Files) {
            $n = 0
            foreach ($line in ((Get-Content -Raw -LiteralPath $f.FullName) -split "`r?`n")) {
                $n++
                if ($line -match '^\s*#') { continue }
                [pscustomobject]@{ File = $f.FullName; Line = $n; Text = $line }
            }
        }
    }
}

Describe 'The hook registry is never opened for writing (FR-022, SC-011)' {
    It 'has no write verb on any line that names the registry' {
        foreach ($row in (Select-CodeLine)) {
            if (($row.Text -match $script:RegistryToken) -and ($row.Text -match $script:WriteVerb)) {
                throw "write construct targeting the hook registry at $($row.File):$($row.Line): $($row.Text.Trim())"
            }
        }
    }

    It 'has no redirection into the registry' {
        foreach ($row in (Select-CodeLine)) {
            if ($row.Text -match ">>?\s*[`"']?\`$?(env:)?(SPEC_KIT_JIRA_EXTENSIONS_YML|extPath|RegistryPath)") {
                throw "redirection into the hook registry at $($row.File):$($row.Line): $($row.Text.Trim())"
            }
        }
    }

    It 'never passes the registry path to the config-file writer' {
        # ConvertTo-JiraConfigYaml is the serialiser every file this extension DOES
        # own goes through. Reaching it with the registry path is the exact shape
        # of the write this feature removed, and the one a later feature would most
        # plausibly reintroduce.
        foreach ($row in (Select-CodeLine)) {
            if (($row.Text -match 'ConvertTo-JiraConfigYaml') -and ($row.Text -match $script:RegistryToken)) {
                throw "registry path reaching the config serialiser at $($row.File):$($row.Line)"
            }
        }
    }

    It 'has not brought the deleted writer back under any name' {
        foreach ($row in (Select-CodeLine)) {
            $row.Text | Should -Not -Match 'Set-JiraHookRegistration|Get-JiraHookMerged|Get-JiraHookEntry\b'
        }
    }

    It 'names no write construct at all in the read-only hooks module' {
        # Belt and braces on the one module that handles the registry path: it must
        # contain no file-mutating verb whatsoever, for any file. The module's whole
        # job is to read and classify, so there is nothing it could be writing.
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'scripts/powershell/hooks/RegisterHooks.psm1')
        foreach ($line in ($src -split "`r?`n")) {
            if ($line -match '^\s*#') { continue }
            $line | Should -Not -Match $script:WriteVerb
        }
    }
}
