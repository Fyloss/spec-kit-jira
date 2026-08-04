# T008/T010/T012 [Phase 2] — The durable task identifier, PowerShell side.
# Mirror of tests/bash/engine/test_task_marker.bats. Cross-port parity is
# proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    $TaskMarkerModule = Join-Path $EngineDir 'TaskMarker.psm1'
}

Describe 'ConvertTo-JiraTaskMarkerInfo — grammar' {
    BeforeEach { Import-Module $TaskMarkerModule -Force }

    It 'valid form: task= alone' {
        $r = ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira task=7f3a9c1e40b2d85a -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.state | Should -Be 'assigned'
        $r.id | Should -Be '7f3a9c1e40b2d85a'
    }

    It 'valid form: task= + ticket=' {
        $r = ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira task=7f3a9c1e40b2d85a ticket=PROJ-412 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.state | Should -Be 'bound'
        $r.ticket | Should -Be 'PROJ-412'
    }

    It 'valid form: task= + creating' {
        $r = ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira task=7f3a9c1e40b2d85a creating -->' | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.state | Should -Be 'creating'
    }

    It 'a story= body parses as none here (non-collision)' {
        $r = ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira story=7f3a9c1e40b2d85a -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }

    It 'a spec= body parses as none here (non-collision)' {
        $r = ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira spec=7f3a9c1e40b2d85a -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }

    It 'ignored: identifier fails the shape' {
        $r = ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira task=NOTHEX -->' | ConvertFrom-Json
        $r.kind | Should -Be 'none'
    }

    It 'malformed: ticket key fails the shape' {
        $r = ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira task=7f3a9c1e40b2d85a ticket=proj-412 -->' | ConvertFrom-Json
        $r.kind | Should -Be 'malformed'
        $r.id | Should -Be '7f3a9c1e40b2d85a'
    }

    It 'tolerates extra whitespace and a trailing CR' {
        $r = ConvertTo-JiraTaskMarkerInfo -Line "<!--   speckit-jira   task=7f3a9c1e40b2d85a   ticket=PROJ-412   -->`r" | ConvertFrom-Json
        $r.kind | Should -Be 'valid'
        $r.ticket | Should -Be 'PROJ-412'
    }
}

Describe 'Set-JiraTaskMarkerAssign — splice' {
    BeforeEach {
        Import-Module $TaskMarkerModule -Force
        $script:oldSeam = $env:SPEC_KIT_JIRA_ID_SOURCE
    }
    AfterEach { $env:SPEC_KIT_JIRA_ID_SOURCE = $script:oldSeam }

    It 'inserts a marker line immediately after each unmarked task line' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222'
        $doc = "- [ ] T001 [P] First task`n`n- [ ] T002 [P] Second task`n"
        $out = Set-JiraTaskMarkerAssign -Text $doc
        $out.Contains("- [ ] T001 [P] First task`n<!-- speckit-jira task=1111111111111111 -->") | Should -BeTrue
        $out.Contains("- [ ] T002 [P] Second task`n<!-- speckit-jira task=2222222222222222 -->") | Should -BeTrue
    }

    It 'a file with no recognisable task yields no anchors and is returned unchanged' {
        $doc = "# Tasks`n`nNothing to see here.`n"
        (Set-JiraTaskMarkerAssign -Text $doc) | Should -Be $doc
    }

    It 'is idempotent: a fully-marked document is returned byte-identical' {
        $doc = "- [ ] T001 First task`n<!-- speckit-jira task=1111111111111111 -->`n"
        (Set-JiraTaskMarkerAssign -Text $doc) | Should -Be $doc
    }

    It 'never disturbs a byte outside the inserted lines' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111'
        $doc = "- [ ] T001   Weird   spacing`n`n  Indented continuation.`n`ttab continuation.`n"
        $out = Set-JiraTaskMarkerAssign -Text $doc
        $out | Should -BeLike "*  Indented continuation.`n`ttab continuation.*"
    }

    It 'adopts CRLF when the file is dominantly CRLF' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111'
        $doc = "- [ ] T001 First task`r`n`r`nBody.`r`n"
        $out = Set-JiraTaskMarkerAssign -Text $doc
        $out | Should -BeLike "*<!-- speckit-jira task=1111111111111111 -->`r`n*"
    }

    It 'leaves a section with two marker attempts untouched (blocked upstream, not silently fixed)' {
        $doc = "- [ ] T001 First task`n<!-- speckit-jira task=1111111111111111 ticket=bad -->`n"
        (Set-JiraTaskMarkerAssign -Text $doc) | Should -Be $doc
    }

    It 'descending insertion order means an earlier anchors line number is never shifted' {
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
        $doc = "- [ ] T001 First`n- [ ] T002 Second`n- [ ] T003 Third`n"
        $out = Set-JiraTaskMarkerAssign -Text $doc
        $out.Contains("- [ ] T001 First`n<!-- speckit-jira task=1111111111111111 -->`n- [ ] T002 Second`n<!-- speckit-jira task=2222222222222222 -->`n- [ ] T003 Third`n<!-- speckit-jira task=3333333333333333 -->") | Should -BeTrue
    }
}

Describe 'State transitions' {
    BeforeEach { Import-Module $TaskMarkerModule -Force }

    It 'Set-JiraTaskMarkerMarkCreating replaces a bare assigned line with the creating state' {
        $doc = "- [ ] T001 First task`n<!-- speckit-jira task=1111111111111111 -->`n"
        $out = Set-JiraTaskMarkerMarkCreating -Text $doc -IdsJson '["1111111111111111"]'
        $out | Should -BeLike '*<!-- speckit-jira task=1111111111111111 creating -->*'
        $out | Should -Not -BeLike '*<!-- speckit-jira task=1111111111111111 -->*'
    }

    It 'Set-JiraTaskMarkerRecordTicket replaces a creating line with the bound state' {
        $doc = "- [ ] T001 First task`n<!-- speckit-jira task=1111111111111111 creating -->`n"
        $out = Set-JiraTaskMarkerRecordTicket -Text $doc -Id '1111111111111111' -Key 'PROJ-412'
        $out | Should -BeLike '*<!-- speckit-jira task=1111111111111111 ticket=PROJ-412 -->*'
    }

    It 'Set-JiraTaskMarkerRecordTicket is a no-op when the id has no marker line' {
        $doc = "- [ ] T001 First task`n"
        (Set-JiraTaskMarkerRecordTicket -Text $doc -Id '1111111111111111' -Key 'PROJ-412') | Should -Be $doc
    }
}

Describe 'Get-JiraTaskMarkerSectionInfo' {
    BeforeEach { Import-Module $TaskMarkerModule -Force }

    It 'reports duplicate when a tasks own span carries two marker attempts' {
        $doc = "- [ ] T001 First task`n<!-- speckit-jira task=1111111111111111 -->`n<!-- speckit-jira task=2222222222222222 -->`n"
        $info = Get-JiraTaskMarkerSectionInfo -Content $doc -Start 2 -End 3 | ConvertFrom-Json
        $info.state | Should -Be 'duplicate'
    }
}
