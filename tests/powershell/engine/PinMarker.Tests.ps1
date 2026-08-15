# T038/T042/T044/T046 [027] — Pester twin of test_pin_marker.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Output.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/engine/PinMarker.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/engine/StoryMarker.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/engine/SpecMarker.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/engine/TaskMarker.psm1') -Force
}

Describe 'Format-JiraPinMarkerLine' {
    It 'produces the exact written form' {
        Format-JiraPinMarkerLine -Key 'PROJ-142' | Should -Be '<!-- speckit-jira pin=PROJ-142 -->'
    }
}

Describe 'P-1: non-collision, in both directions' {
    It 'pin= parses as none in the story parser' {
        (ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira pin=PROJ-1 -->' | ConvertFrom-Json).kind | Should -Be 'none'
    }
    It 'pin= parses as none in the spec parser' {
        (ConvertTo-JiraSpecMarkerInfo -Line '<!-- speckit-jira pin=PROJ-1 -->' | ConvertFrom-Json).kind | Should -Be 'none'
    }
    It 'pin= parses as none in the task parser' {
        (ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira pin=PROJ-1 -->' | ConvertFrom-Json).kind | Should -Be 'none'
    }
    It 'story= parses as none in the pin parser' {
        (ConvertTo-JiraPinMarkerInfo -Line '<!-- speckit-jira story=7f3a9c1e40b2d85a -->' | ConvertFrom-Json).kind | Should -Be 'none'
    }
    It 'spec= parses as none in the pin parser' {
        (ConvertTo-JiraPinMarkerInfo -Line '<!-- speckit-jira spec=COMP-1 -->' | ConvertFrom-Json).kind | Should -Be 'none'
    }
    It 'task= parses as none in the pin parser' {
        (ConvertTo-JiraPinMarkerInfo -Line '<!-- speckit-jira task=T001 ticket=COMP-1 -->' | ConvertFrom-Json).kind | Should -Be 'none'
    }
}

Describe 'ConvertTo-JiraPinMarkerInfo' {
    It 'accepts a well-formed pin= body' {
        $r = ConvertTo-JiraPinMarkerInfo -Line '<!-- speckit-jira pin=PROJ-142 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.key | Should -Be 'PROJ-142'
    }
    It 'rejects an empty pin= body as malformed' {
        (ConvertTo-JiraPinMarkerInfo -Line '<!-- speckit-jira pin= -->' | ConvertFrom-Json).kind | Should -Be 'malformed'
    }
    It 'rejects a pin= body with embedded whitespace as malformed' {
        (ConvertTo-JiraPinMarkerInfo -Line '<!-- speckit-jira pin=PROJ-1 extra -->' | ConvertFrom-Json).kind | Should -Be 'malformed'
    }
}

Describe 'P-2: placement' {
    It 'finds a ### heading' {
        $spec = "# Feature`n`n### User Story 1 - Thing (Priority: P1)`n`nBody`n"
        @(Get-JiraPinMarkerAnchors -Content $spec) | Should -Be @(3)
    }
    It 'finds ##, ###, #### mixed' {
        $spec = "# Feature`n`n## User Story 1 - A (Priority: P1)`n`nBody`n`n#### User Story 2 - B (Priority: P1)`n`nBody`n"
        @(Get-JiraPinMarkerAnchors -Content $spec) | Should -Be @(3, 7)
    }
    It 'falls back to the first H1 when no story heading exists' {
        $spec = "# Feature Title`n`nSome prose, no story headings.`n"
        @(Get-JiraPinMarkerAnchors -Content $spec) | Should -Be @(1)
    }
}

Describe 'P-3/P-4: the four properties' {
    BeforeAll {
        function New-TwoStorySpec([string] $Path) {
            @(
                '# Feature', '',
                '### User Story 1 - A (Priority: P1)',
                '<!-- speckit-jira pin=PROJ-11 -->', '',
                'Body A', '',
                '### User Story 2 - B (Priority: P1)',
                '<!-- speckit-jira pin=PROJ-12 -->', '',
                'Body B'
            ) -join "`n" | Set-Content -NoNewline -LiteralPath $Path
        }
    }

    It 'a clean file reports zero violations' {
        $f = Join-Path $TestDrive 'spec1.md'
        New-TwoStorySpec -Path $f
        $r = Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson '["PROJ-11","PROJ-12"]' | ConvertFrom-Json
        @($r).Count | Should -Be 0
    }

    It 'a dropped key is reported, naming the key' {
        $f = Join-Path $TestDrive 'spec2.md'
        @('# Feature', '', '### User Story 1 - A (Priority: P1)', '<!-- speckit-jira pin=PROJ-11 -->', '', 'Body') -join "`n" | Set-Content -NoNewline -LiteralPath $f
        $r = @(Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson '["PROJ-11","PROJ-12"]' | ConvertFrom-Json)
        ($r | Where-Object { $_.kind -eq 'missing' }).key | Should -Be 'PROJ-12'
    }

    It 'an orphan marker is reported, naming the key and line' {
        $f = Join-Path $TestDrive 'spec3.md'
        New-TwoStorySpec -Path $f
        $r = @(Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson '["PROJ-11"]' | ConvertFrom-Json)
        $orphan = $r | Where-Object { $_.kind -eq 'orphan' }
        $orphan.key | Should -Be 'PROJ-12'
        @($orphan.lines)[0] | Should -BeGreaterThan 0
    }

    It 'a split is reported, naming the key and both lines' {
        $f = Join-Path $TestDrive 'spec4.md'
        @(
            '# Feature', '',
            '### User Story 1 - A (Priority: P1)', '<!-- speckit-jira pin=PROJ-11 -->', '', 'Body A', '',
            '### User Story 2 - B (Priority: P1)', '<!-- speckit-jira pin=PROJ-11 -->', '', 'Body B'
        ) -join "`n" | Set-Content -NoNewline -LiteralPath $f
        $r = @(Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson '["PROJ-11"]' | ConvertFrom-Json)
        $split = $r | Where-Object { $_.kind -eq 'split' }
        $split.key | Should -Be 'PROJ-11'
        @($split.lines).Count | Should -Be 2
    }

    It 'a merge is reported' {
        $f = Join-Path $TestDrive 'spec5.md'
        @(
            '# Feature', '',
            '### User Story 1 - A (Priority: P1)',
            '<!-- speckit-jira pin=PROJ-11 -->',
            '<!-- speckit-jira pin=PROJ-12 -->', '', 'Body A'
        ) -join "`n" | Set-Content -NoNewline -LiteralPath $f
        $r = @(Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson '["PROJ-11","PROJ-12"]' | ConvertFrom-Json)
        @($r | Where-Object { $_.kind -eq 'merge' }).Count | Should -Be 1
    }

    It 'a reordered marker is reported' {
        $f = Join-Path $TestDrive 'spec6.md'
        @(
            '# Feature', '',
            '### User Story 1 - A (Priority: P1)', '<!-- speckit-jira pin=PROJ-12 -->', '', 'Body A', '',
            '### User Story 2 - B (Priority: P1)', '<!-- speckit-jira pin=PROJ-11 -->', '', 'Body B'
        ) -join "`n" | Set-Content -NoNewline -LiteralPath $f
        $r = @(Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson '["PROJ-11","PROJ-12"]' | ConvertFrom-Json)
        @($r | Where-Object { $_.kind -eq 'reorder' }).Count | Should -Be 1
    }

    It 'all four violation kinds at once are reported together' {
        $f = Join-Path $TestDrive 'spec7.md'
        @(
            '# Feature', '',
            '### User Story 1 - A (Priority: P1)', '<!-- speckit-jira pin=PROJ-99 -->', '', 'Body A', '',
            '### User Story 2 - B (Priority: P1)',
            '<!-- speckit-jira pin=PROJ-11 -->',
            '<!-- speckit-jira pin=PROJ-11 -->', '', 'Body B'
        ) -join "`n" | Set-Content -NoNewline -LiteralPath $f
        $r = @(Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson '["PROJ-11","PROJ-12"]' | ConvertFrom-Json)
        $kinds = @($r | ForEach-Object { $_.kind } | Sort-Object -Unique)
        $kinds | Should -Contain 'missing'
        $kinds | Should -Contain 'orphan'
        ($kinds -contains 'split' -or $kinds -contains 'merge') | Should -Be $true
    }
}

Describe 'P-5: a legitimate edit passes silently' {
    It 'prose rewrite, new scenario, renamed heading, and a new unpinned story all pass' {
        $f = Join-Path $TestDrive 'spec8.md'
        @(
            '# Feature — renamed', '',
            '### User Story 1 - A, rewritten (Priority: P1)', '<!-- speckit-jira pin=PROJ-11 -->', '',
            'Totally different prose.', '- **Given** x', '- **When** y', '- **Then** z', '',
            '### User Story 2 - B (Priority: P1)', '<!-- speckit-jira pin=PROJ-12 -->', '', 'Body B', '',
            '### User Story 3 - New, unpinned (Priority: P2)', '', 'Brand new story, no marker.'
        ) -join "`n" | Set-Content -NoNewline -LiteralPath $f
        $r = @(Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson '["PROJ-11","PROJ-12"]' | ConvertFrom-Json)
        $r.Count | Should -Be 0
    }
}

Describe 'P-9: 100 markers' {
    It 'validating succeeds and reports zero violations' {
        $f = Join-Path $TestDrive 'spec100.md'
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("# Feature`n`n")
        $keys = [System.Collections.Generic.List[string]]::new()
        for ($i = 1; $i -le 100; $i++) {
            [void]$sb.Append("### User Story $i - S$i (Priority: P1)`n<!-- speckit-jira pin=PROJ-$i -->`n`nBody $i`n`n")
            $keys.Add("PROJ-$i")
        }
        Set-Content -NoNewline -LiteralPath $f -Value $sb.ToString()
        $keysJson = '[' + (($keys | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
        $r = @(Test-JiraPinMarkerValidate -SpecPath $f -DesignatorsJson $keysJson | ConvertFrom-Json)
        $r.Count | Should -Be 0
    }
}

Describe 'P-7: consumption at binding' {
    It 'replaces the pin marker in place, preserving every other byte' {
        $content = "### User Story 1 - A (Priority: P1)`n<!-- speckit-jira pin=PROJ-142 -->`n`nBody, unchanged.`n"
        $new = ConvertTo-JiraPinMarkerConsumed -Content $content -Key 'PROJ-142' -ReplacementLine '<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->' -Nl "`n"
        $new | Should -Match 'story=7f3a9c1e40b2d85a ticket=PROJ-142'
        $new | Should -Not -Match 'pin=PROJ-142'
        $new | Should -Match 'Body, unchanged\.'
    }

    It 'preserves CRLF line endings' {
        $content = "### User Story 1 - A (Priority: P1)`r`n<!-- speckit-jira pin=PROJ-142 -->`r`n`r`nBody.`r`n"
        $new = ConvertTo-JiraPinMarkerConsumed -Content $content -Key 'PROJ-142' -ReplacementLine '<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->' -Nl "`r`n"
        $new | Should -Match "story=7f3a9c1e40b2d85a ticket=PROJ-142 -->`r`n"
    }
}
