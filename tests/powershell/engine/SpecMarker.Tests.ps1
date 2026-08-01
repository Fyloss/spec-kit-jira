# T049/T050/T051 [Phase 5, US2] — The parent marker, PowerShell side. Mirror
# of tests/bash/engine/test_spec_marker.bats. Cross-port parity is proven in
# bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    $StoryMarkerModule = Join-Path $EngineDir 'StoryMarker.psm1'
    $SpecMarkerModule = Join-Path $EngineDir 'SpecMarker.psm1'
    $MarkerSpliceModule = Join-Path $EngineDir 'MarkerSplice.psm1'
}

Describe 'ConvertTo-JiraSpecMarkerInfo — grammar' {
    BeforeEach {
        # SpecMarker.psm1 nested-imports StoryMarker.psm1 itself (without
        # -Global); importing it a SECOND time here, -Force -Global, AFTER
        # SpecMarker.psm1, is what keeps ConvertTo-JiraStoryMarkerInfo
        # visible to this scope — see StoryMarker's own note in
        # Hierarchy.Tests.ps1 for the general rule.
        Import-Module $SpecMarkerModule -Force
        Import-Module $StoryMarkerModule -Force -Global
    }

    It 'valid form: spec= alone' {
        $r = ConvertTo-JiraSpecMarkerInfo -Line '<!-- speckit-jira spec=3f2a91c04b7e6d18 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.state | Should -Be 'assigned'
        $r.id | Should -Be '3f2a91c04b7e6d18'
    }

    It 'valid form: spec= + creating' {
        $r = ConvertTo-JiraSpecMarkerInfo -Line '<!-- speckit-jira spec=3f2a91c04b7e6d18 creating -->' | ConvertFrom-Json
        $r.state | Should -Be 'creating'
    }

    It 'valid form: spec= + ticket=' {
        $r = ConvertTo-JiraSpecMarkerInfo -Line '<!-- speckit-jira spec=3f2a91c04b7e6d18 ticket=COMP-412 -->' | ConvertFrom-Json
        $r.state | Should -Be 'bound'
        $r.ticket | Should -Be 'COMP-412'
    }

    It 'ignored: a story= body is not a spec marker' {
        $r = ConvertTo-JiraSpecMarkerInfo -Line '<!-- speckit-jira story=3f2a91c04b7e6d18 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }

    It 'malformed: a spec= body with an unrecognisable tail' {
        $r = ConvertTo-JiraSpecMarkerInfo -Line '<!-- speckit-jira spec=3f2a91c04b7e6d18 bogus -->' | ConvertFrom-Json
        $r.kind | Should -Be 'malformed'
        $r.id | Should -Be '3f2a91c04b7e6d18'
    }

    It 'story marker parser returns none for a spec= body (non-collision)' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira spec=3f2a91c04b7e6d18 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }

    It 'spec marker parser returns none for a story= body (non-collision)' {
        $r = ConvertTo-JiraSpecMarkerInfo -Line '<!-- speckit-jira story=3f2a91c04b7e6d18 ticket=COMP-1 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }
}

Describe 'Get-JiraSpecMarkerDocumentInfo' {
    BeforeEach { Import-Module $SpecMarkerModule -Force }

    It 'absent when no spec= line exists' {
        $doc = "# Title`n`nBody.`n"
        $r = Get-JiraSpecMarkerDocumentInfo -Content $doc | ConvertFrom-Json
        $r.state | Should -Be 'absent'
    }

    It 'assigned for a single bare marker' {
        $doc = "# Title`n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->`n`nBody.`n"
        $r = Get-JiraSpecMarkerDocumentInfo -Content $doc | ConvertFrom-Json
        $r.state | Should -Be 'assigned'
        $r.id | Should -Be '3f2a91c04b7e6d18'
        $r.lines[0] | Should -Be 2
    }

    It 'duplicate for two spec= lines anywhere in the file' {
        $doc = "# Title`n<!-- speckit-jira spec=1111111111111111 -->`n`nBody.`n`n<!-- speckit-jira spec=2222222222222222 -->`n"
        $r = Get-JiraSpecMarkerDocumentInfo -Content $doc | ConvertFrom-Json
        $r.state | Should -Be 'duplicate'
        @($r.lines).Count | Should -Be 2
    }
}

Describe 'Set-JiraSpecMarkerAssign — splice' {
    BeforeEach {
        # SpecMarker.psm1 nested-imports StoryMarker.psm1 itself (without
        # -Global); importing it a SECOND time here, -Force -Global, AFTER
        # SpecMarker.psm1, is what keeps ConvertTo-JiraStoryMarkerInfo
        # visible to this scope — see StoryMarker's own note in
        # Hierarchy.Tests.ps1 for the general rule.
        Import-Module $SpecMarkerModule -Force
        Import-Module $StoryMarkerModule -Force -Global
    }
    AfterEach { Remove-Item Env:\SPEC_KIT_JIRA_ID_SOURCE -ErrorAction SilentlyContinue }

    It 'inserts the marker line immediately after the H1' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '3f2a91c04b7e6d18'
        $doc = "# Feature Specification: X`n`nSome text.`n"
        $out = Set-JiraSpecMarkerAssign -Text $doc
        $out | Should -Be "# Feature Specification: X`n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->`n`nSome text.`n"
    }

    It 'inserts as line 1 when there is no H1' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '3f2a91c04b7e6d18'
        $doc = "Some text with no heading.`n"
        $out = Set-JiraSpecMarkerAssign -Text $doc
        $out | Should -Be "<!-- speckit-jira spec=3f2a91c04b7e6d18 -->`nSome text with no heading.`n"
    }

    It 'is idempotent: a document already carrying spec= is unchanged' {
        $doc = "# Title`n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->`n`nBody.`n"
        $out = Set-JiraSpecMarkerAssign -Text $doc
        $out | Should -Be $doc
    }

    It 'adopts CRLF when the file is dominantly CRLF' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '3f2a91c04b7e6d18'
        $doc = "# Title`r`n`r`nBody.`r`n"
        $out = Set-JiraSpecMarkerAssign -Text $doc
        $out | Should -BeLike "*<!-- speckit-jira spec=3f2a91c04b7e6d18 -->`r`n*"
    }
}

Describe 'State transitions' {
    BeforeEach {
        # SpecMarker.psm1 nested-imports StoryMarker.psm1 itself (without
        # -Global); importing it a SECOND time here, -Force -Global, AFTER
        # SpecMarker.psm1, is what keeps ConvertTo-JiraStoryMarkerInfo
        # visible to this scope — see StoryMarker's own note in
        # Hierarchy.Tests.ps1 for the general rule.
        Import-Module $SpecMarkerModule -Force
        Import-Module $StoryMarkerModule -Force -Global
    }

    It 'Set-JiraSpecMarkerMarkCreating replaces a bare assigned line with the creating state' {
        $doc = "# Title`n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->`n`nBody.`n"
        $out = Set-JiraSpecMarkerMarkCreating -Text $doc -Id '3f2a91c04b7e6d18'
        $out | Should -BeLike '*<!-- speckit-jira spec=3f2a91c04b7e6d18 creating -->*'
    }

    It 'Set-JiraSpecMarkerRecordTicket replaces a creating line with the bound state' {
        $doc = "# Title`n<!-- speckit-jira spec=3f2a91c04b7e6d18 creating -->`n`nBody.`n"
        $out = Set-JiraSpecMarkerRecordTicket -Text $doc -Id '3f2a91c04b7e6d18' -Key 'COMP-412'
        $out | Should -BeLike '*<!-- speckit-jira spec=3f2a91c04b7e6d18 ticket=COMP-412 -->*'
    }
}

Describe 'marker file write' {
    BeforeEach { Import-Module $MarkerSpliceModule -Force }

    It 'is not opened when nothing changes' {
        $f = Join-Path $TestDrive 'spec.md'
        [System.IO.File]::WriteAllText($f, 'unchanged content', [System.Text.UTF8Encoding]::new($false))
        $before = (Get-Item $f).LastWriteTimeUtc
        Start-Sleep -Milliseconds 1100
        (Write-JiraMarkerSpliceFile -Path $f -NewContent 'unchanged content') | Should -Be 'unchanged'
        (Get-Item $f).LastWriteTimeUtc | Should -Be $before
    }
}
