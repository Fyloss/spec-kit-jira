# T086 [US5] — The bridge-unavailable fallback block, verbatim. PowerShell port.
# Twin of tests/bash/ci/test_agent_fallback_block.bats (FR-030).
#
# This check exists because of a finding that changes what "check the messages"
# can mean. The reported error message — the one that named a machine-wide CLI
# that was never how this extension is delivered, and told the developer to run
# `/speckit-jira-conifg` — exists NOWHERE in this repository. Not in a script,
# not in a command document. The assistant composed it, after the procedure told
# it to run a bare `spec-kit-jira` that a consuming repository does not have.
#
# A scan of committed literals cannot see prose that is never committed. So the
# enforceable control is different in kind: for the one state the bridge cannot
# report on — because it never starts — pin the exact words in the document the
# assistant reads, instruct it to emit them rather than improvise, and check
# mechanically that the document still contains them.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Docs = Get-ChildItem -LiteralPath (Join-Path $script:Root 'commands') -Filter '*.md' -File | Sort-Object Name

    # The block, fixed in contracts/reconcile-command.md. Byte for byte, LF-joined
    # so it matches whatever line endings the checkout produced.
    $script:BlockLines = @(
        'Jira bridge not available: the entry point'
        '.specify/extensions/jira/scripts/bash/spec-kit-jira.sh (or, on Windows,'
        '.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1) was not found or'
        'is not executable. This spec-kit command completed normally and nothing was'
        'mirrored to Jira. To restore the bridge, reinstall the extension with'
        '`specify extension add --dev <path-to-spec-kit-jira> --force`.'
    )
    $script:Block = $script:BlockLines -join "`n"
}

Describe 'The fallback block (FR-030)' {
    It 'appears VERBATIM in each of the three command documents' {
        $script:Docs.Count | Should -Be 3
        foreach ($doc in $script:Docs) {
            $text = (Get-Content -Raw -LiteralPath $doc.FullName) -replace "`r`n", "`n"
            if (-not $text.Contains($script:Block)) {
                throw "$($doc.Name) does not contain the fallback block verbatim"
            }
        }
    }

    It 'is required to be emitted EXACTLY, not described' {
        # Without this instruction the block is just text the assistant may
        # summarise, and summarising is precisely how the reported message came
        # to exist.
        foreach ($doc in $script:Docs) {
            $text = Get-Content -Raw -LiteralPath $doc.FullName
            $text | Should -Match ([regex]::Escape('exactly as written'))
            $text | Should -Match '(?i)do not (paraphrase|compose)'
        }
    }

    It 'names the true cause — a missing file, not a missing CLI' {
        $script:Block | Should -Match ([regex]::Escape('was not found or'))
        $script:Block | Should -Match ([regex]::Escape('is not executable'))
        # The wording the reported message used, and which was never true of this
        # extension: it is not delivered as a machine-wide CLI at all.
        $script:Block | Should -Not -Match 'CLI not installed'
    }

    It 'states that the host command completed normally (FR-015)' {
        $script:Block | Should -Match ([regex]::Escape('This spec-kit command completed normally'))
    }

    It 'contains only literals that are runnable as written (FR-018)' {
        Test-Path -LiteralPath (Join-Path $script:Root 'scripts/bash/spec-kit-jira.sh') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1') | Should -BeTrue
        $script:Block | Should -Match ([regex]::Escape('specify extension add --dev <path-to-spec-kit-jira> --force'))
        # Nothing in the block names an assistant command, so there is nothing for
        # the assistant to misremember — the failure mode that produced
        # `/speckit-jira-conifg`.
        $script:Block | Should -Not -Match 'speckit[.-]jira'
    }
}
