# T014 [Phase 2] — the story marker line excluded from every content
# extraction, PowerShell side. Mirror of tests/bash/engine/test_parse_marker.bats.
# Cross-port parity is proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Parse.psm1') -Force

    function Invoke-ParseWrapper([string] $Doc) {
        (Get-JiraParsedSpec -Text $Doc -FolderSlug '001-x') | ConvertFrom-Json -Depth 100
    }
}

Describe 'Get-JiraParsedSpec — marker exclusion' {
    It "local_id is the marker's identifier when present" {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->`n`nBody.`n"
        $r = Invoke-ParseWrapper $doc
        $r.stories[0].local_id | Should -Be '7f3a9c1e40b2d85a'
    }

    It 'local_id is empty when the story has no marker at all' {
        $doc = "### User Story 1 - First (Priority: P1)`n`nBody.`n"
        $r = Invoke-ParseWrapper $doc
        [string]$r.stories[0].local_id | Should -Be ''
        $r.stories[0].marker.state | Should -Be 'absent'
    }

    It 'the marker line never lands in the title, description, or acceptance criteria' {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->`n`nAs a user I want X.`n`n- **Given** a thing`n- **When** it happens`n- **Then** it works`n"
        $out = Get-JiraParsedSpec -Text $doc -FolderSlug '001-x'
        $out | Should -Not -BeLike '*speckit-jira*'
    }

    It 'the marker line never lands in the design section' {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=7f3a9c1e40b2d85a -->`n`nBody.`n`n#### Design`n`nSome guidance here.`n"
        $r = Invoke-ParseWrapper $doc
        (ConvertTo-Json $r.stories[0].design -Compress) | Should -Be '[{"kind":"guidance","value":"Some guidance here."}]'
    }

    It 'the marker line never lands in priority or estimation extraction' {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=7f3a9c1e40b2d85a -->`n`nEstimation: 5`n"
        $r = Invoke-ParseWrapper $doc
        $r.stories[0].priority_logical | Should -Be 'P1'
        [string]$r.stories[0].estimation | Should -Be '5'
    }

    It "a malformed marker still carries its own identifier as local_id and is marked malformed" {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=proj-142 -->`n`nBody.`n"
        $r = Invoke-ParseWrapper $doc
        $r.stories[0].local_id | Should -Be '7f3a9c1e40b2d85a'
        $r.stories[0].marker.state | Should -Be 'malformed'
    }

    It 'two marker lines in one story section: local_id is a fresh generated id, marker.state is duplicate, both line numbers recorded' {
        $doc = "### User Story 1 - First (Priority: P1)`n<!-- speckit-jira story=1111111111111111 -->`n<!-- speckit-jira story=2222222222222222 -->`n`nBody.`n"
        $r = Invoke-ParseWrapper $doc
        $r.stories[0].marker.state | Should -Be 'duplicate'
        [string]$r.stories[0].local_id | Should -Not -BeNullOrEmpty
        (ConvertTo-Json $r.stories[0].marker.lines -Compress) | Should -Be '[2,3]'
    }

    It 'the implicit single story (no headings) reads its marker after the H1' {
        $doc = "# Only A Title`n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-9 -->`n`nSome prose.`n"
        $r = Invoke-ParseWrapper $doc
        @($r.stories).Count | Should -Be 1
        $r.stories[0].local_id | Should -Be '7f3a9c1e40b2d85a'
        (Get-JiraParsedSpec -Text $doc -FolderSlug '001-x') | Should -Not -BeLike '*speckit-jira*'
    }

    It 'reordering and retitling stories keeps each ticket bound to the same local_id' {
        $doc = "### User Story 2 - Second (Priority: P2)`n<!-- speckit-jira story=2222222222222222 ticket=PROJ-2 -->`n`nSecond body.`n`n### User Story 1 - First Renamed (Priority: P1)`n<!-- speckit-jira story=1111111111111111 ticket=PROJ-1 -->`n`nFirst body.`n"
        $r = Invoke-ParseWrapper $doc
        $r.stories[0].local_id | Should -Be '2222222222222222'
        $r.stories[0].title | Should -Be 'Second'
        $r.stories[1].local_id | Should -Be '1111111111111111'
        $r.stories[1].title | Should -Be 'First Renamed'
    }
}
