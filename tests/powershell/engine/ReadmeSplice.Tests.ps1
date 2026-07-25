# T060 [US5] — Managed-section byte-splice (engine, neutral).
# Mirror of tests/bash/engine/test_readme_splice.bats. Marker tokens are
# parameters, so neutral placeholder tokens are used — no Jira/README vocabulary
# in the engine layer. Asserts CRLF-safe splice, LF for new files, and byte-parity.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Engine = Join-Path $Root 'scripts/powershell/engine'
    Import-Module (Join-Path $Engine 'ManagedSection.psm1') -Force
    $script:Begin = '<!-- x:begin'
    $script:End = '<!-- x:end'
    $script:Block = "<!-- x:begin v1 -->`nMANAGED LINE A`nMANAGED LINE B`n<!-- x:end v1 -->"
}

Describe 'Managed-section splice' {
    It 'replaces only the content between markers, preserving bytes outside (LF)' {
        $hostText = "header line`n<!-- x:begin v0 -->`nOLD`n<!-- x:end v0 -->`nfooter line`n"
        $r = Invoke-JiraManagedSectionSplice -Text $hostText -BeginToken $Begin -EndToken $End -NewBlock $Block
        $exp = "header line`n<!-- x:begin v1 -->`nMANAGED LINE A`nMANAGED LINE B`n<!-- x:end v1 -->`nfooter line`n"
        $r.ExitCode | Should -Be 0
        [System.String]::Equals($r.Content, $exp, [System.StringComparison]::Ordinal) | Should -BeTrue
    }

    It 'adopts the host CRLF line ending and preserves the outer CRLF bytes' {
        $hostText = "header`r`n<!-- x:begin v0 -->`r`nOLD`r`n<!-- x:end v0 -->`r`nfooter`r`n"
        $r = Invoke-JiraManagedSectionSplice -Text $hostText -BeginToken $Begin -EndToken $End -NewBlock $Block
        $exp = "header`r`n<!-- x:begin v1 -->`r`nMANAGED LINE A`r`nMANAGED LINE B`r`n<!-- x:end v1 -->`r`nfooter`r`n"
        [System.String]::Equals($r.Content, $exp, [System.StringComparison]::Ordinal) | Should -BeTrue
    }

    It 'detects CRLF for a predominantly CRLF host' {
        Get-JiraManagedSectionLineEnding -Text "a`r`nb`r`nc`n" | Should -Be 'CRLF'
    }

    It 'detects LF for an LF host' {
        Get-JiraManagedSectionLineEnding -Text "a`nb`nc`n" | Should -Be 'LF'
    }

    It 'creates a new block terminated with LF for an empty host' {
        $r = Invoke-JiraManagedSectionSplice -Text '' -BeginToken $Begin -EndToken $End -NewBlock $Block
        $exp = "<!-- x:begin v1 -->`nMANAGED LINE A`nMANAGED LINE B`n<!-- x:end v1 -->`n"
        [System.String]::Equals($r.Content, $exp, [System.StringComparison]::Ordinal) | Should -BeTrue
        $r.Content.Contains("`r") | Should -BeFalse
    }
}
