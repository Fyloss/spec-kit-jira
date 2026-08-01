# T008/T010/T012 [Phase 2] — The durable story identifier, PowerShell side.
# Mirror of tests/bash/engine/test_story_marker.bats. Cross-port parity is
# proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    $StoryMarkerModule = Join-Path $EngineDir 'StoryMarker.psm1'
    $MarkerSpliceModule = Join-Path $EngineDir 'MarkerSplice.psm1'
}

# Bats gives every @test a fresh process; Pester runs all Its in one. The
# SPEC_KIT_JIRA_ID_SOURCE seam is consumed via a module-scoped counter
# (New-JiraStoryMarkerId), so every Describe below re-imports -Force before
# each test to reset it to index 0 — otherwise a test's expected sequence
# would depend on how many ids earlier tests already drew.

Describe 'New-JiraStoryMarkerId' {
    BeforeEach { Import-Module $StoryMarkerModule -Force }

    It 'has the shape ^[0-9a-f]{16}$' {
        (New-JiraStoryMarkerId) | Should -Match '^[0-9a-f]{16}$'
    }

    It 'is unique across calls' {
        $a = New-JiraStoryMarkerId
        $b = New-JiraStoryMarkerId
        $a | Should -Not -Be $b
    }

    It 'yields a fixed, cycling sequence under SPEC_KIT_JIRA_ID_SOURCE' {
        $old = $env:SPEC_KIT_JIRA_ID_SOURCE
        try {
            $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222'
            New-JiraStoryMarkerId | Should -Be '1111111111111111'
            New-JiraStoryMarkerId | Should -Be '2222222222222222'
            New-JiraStoryMarkerId | Should -Be '1111111111111111'
        }
        finally { $env:SPEC_KIT_JIRA_ID_SOURCE = $old }
    }
}

Describe 'ConvertTo-JiraStoryMarkerInfo — grammar' {
    BeforeEach { Import-Module $StoryMarkerModule -Force }

    It 'valid form: story= alone' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira story=7f3a9c1e40b2d85a -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.state | Should -Be 'assigned'
        $r.id | Should -Be '7f3a9c1e40b2d85a'
    }

    It 'valid form: story= + ticket=' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.state | Should -Be 'bound'
        $r.ticket | Should -Be 'PROJ-142'
    }

    It 'valid form: story= + creating' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira story=7f3a9c1e40b2d85a creating -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.state | Should -Be 'creating'
    }

    It 'ignored: identifier fails the shape' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira story=NOTHEX -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }

    It 'ignored: wrong prefix' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit_jira story=7f3a9c1e40b2d85a -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }

    It 'ignored: no identifier to bind' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira ticket=PROJ-142 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }

    It 'malformed: ticket key fails the shape (lowercase)' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=proj-142 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'malformed'
        $r.id | Should -Be '7f3a9c1e40b2d85a'
    }

    It 'malformed: ticket key fails the shape (leading zero)' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-0 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'malformed'
    }

    It 'tolerates extra whitespace' {
        $r = ConvertTo-JiraStoryMarkerInfo -Line '<!--   speckit-jira   story=7f3a9c1e40b2d85a   ticket=PROJ-142   -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.ticket | Should -Be 'PROJ-142'
    }
}

Describe 'Set-JiraStoryMarkerAssign — splice' {
    BeforeEach {
        Import-Module $StoryMarkerModule -Force
        $script:oldSeam = $env:SPEC_KIT_JIRA_ID_SOURCE
    }
    AfterEach {
        $env:SPEC_KIT_JIRA_ID_SOURCE = $script:oldSeam
    }

    It 'inserts a marker line immediately after each story heading' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222'
        $doc = "# Feature Specification: X`n`nSome text.`n`n### User Story 1 - First (Priority: P1)`n`nBody one.`n`n### User Story 2 - Second (Priority: P2)`n`nBody two.`n"
        $out = Set-JiraStoryMarkerAssign -Text $doc
        $out | Should -BeLike "*### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=1111111111111111 -->`n`nBody one.*"
        $out | Should -BeLike "*### User Story 2 - Second (Priority: P2)`n<!-- speckit-jira story=2222222222222222 -->`n`nBody two.*"
    }

    It 'inserts after the H1 for the implicit single story' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '3333333333333333'
        $doc = "# Only A Title`n`nSome prose.`n"
        $out = Set-JiraStoryMarkerAssign -Text $doc
        $out | Should -Be "# Only A Title`n<!-- speckit-jira story=3333333333333333 -->`n`nSome prose.`n"
    }

    It 'is idempotent: a fully-marked document is returned byte-identical' {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=1111111111111111 -->`n`nBody.`n"
        (Set-JiraStoryMarkerAssign -Text $doc) | Should -Be $doc
    }

    It 'never disturbs a byte outside the inserted lines' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111'
        $doc = "### User Story 1 - Weird   spacing (Priority: P1)`n`n  Indented body.`n`ttab body.`n"
        $out = Set-JiraStoryMarkerAssign -Text $doc
        $out | Should -BeLike "*  Indented body.`n`ttab body.*"
    }

    It 'adopts CRLF when the file is dominantly CRLF' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111'
        $doc = "### User Story 1 - First (Priority: P1)`r`n`r`nBody.`r`n"
        $out = Set-JiraStoryMarkerAssign -Text $doc
        $out | Should -BeLike "*<!-- speckit-jira story=1111111111111111 -->`r`n*"
    }

    It 'leaves a section with two marker attempts untouched (blocked upstream, not silently fixed)' {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=1111111111111111 -->`n<!-- speckit-jira story=2222222222222222 -->`n`nBody.`n"
        (Set-JiraStoryMarkerAssign -Text $doc) | Should -Be $doc
    }
}

Describe 'State transitions' {
    BeforeEach { Import-Module $StoryMarkerModule -Force }

    It 'Set-JiraStoryMarkerMarkCreating replaces a bare assigned line with the creating state' {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=1111111111111111 -->`n`nBody.`n"
        $out = Set-JiraStoryMarkerMarkCreating -Text $doc -IdsJson '["1111111111111111"]'
        $out | Should -BeLike '*<!-- speckit-jira story=1111111111111111 creating -->*'
        $out | Should -Not -BeLike '*<!-- speckit-jira story=1111111111111111 -->*'
    }

    It 'Set-JiraStoryMarkerRecordTicket replaces a creating line with the bound state' {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=1111111111111111 creating -->`n`nBody.`n"
        $out = Set-JiraStoryMarkerRecordTicket -Text $doc -Id '1111111111111111' -Key 'PROJ-142'
        $out | Should -BeLike '*<!-- speckit-jira story=1111111111111111 ticket=PROJ-142 -->*'
    }

    It 'Set-JiraStoryMarkerRecordTicket preserves the retitled and reordered story surrounding bytes' {
        $doc = "### User Story 2 - Retitled (Priority: P1)`n<!-- speckit-jira story=2222222222222222 creating -->`n`nMoved body.`n`n### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=1111111111111111 -->`n`nBody.`n"
        $out = Set-JiraStoryMarkerRecordTicket -Text $doc -Id '2222222222222222' -Key 'PROJ-9'
        $out | Should -BeLike "*### User Story 2 - Retitled (Priority: P1)`n<!-- speckit-jira story=2222222222222222 ticket=PROJ-9 -->*"
        $out | Should -BeLike "*### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=1111111111111111 -->*"
    }
}

Describe 'Write-JiraMarkerSpliceFile — idempotence and atomicity' {
    BeforeEach { Import-Module $MarkerSpliceModule -Force }

    It 'does not touch the file when content is unchanged' {
        $f = Join-Path $TestDrive 'spec.md'
        [System.IO.File]::WriteAllText($f, 'unchanged content', [System.Text.UTF8Encoding]::new($false))
        $before = (Get-Item $f).LastWriteTimeUtc
        Start-Sleep -Milliseconds 1100
        (Write-JiraMarkerSpliceFile -Path $f -NewContent 'unchanged content') | Should -Be 'unchanged'
        (Get-Item $f).LastWriteTimeUtc | Should -Be $before
    }

    It 'writes changed content' {
        $f = Join-Path $TestDrive 'spec2.md'
        [System.IO.File]::WriteAllText($f, 'old', [System.Text.UTF8Encoding]::new($false))
        (Write-JiraMarkerSpliceFile -Path $f -NewContent 'new') | Should -Be 'written'
        (Get-Content -Raw -LiteralPath $f) | Should -Be 'new'
    }
}
