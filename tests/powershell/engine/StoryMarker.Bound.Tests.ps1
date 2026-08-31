# T004 [Phase 2, 035] — the bound project set, PowerShell port
# (035 contracts/marker-routing.md C1.1-C1.7; data-model.md §1).
#
# Twin of tests/bash/engine/test_story_marker_bound.bats. Supersedes the
# boolean predicate this file used to cover (Test-JiraStoryMarkerAnyBound,
# 033 C3.3/C3.4): routing needs WHICH project the markers record, not merely
# whether one exists.

BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $root 'scripts/powershell/engine/StoryMarker.psm1') -Force
}

Describe 'Get-JiraMarkerBoundProjects' {
    It 'C1.1 yields the project of a ticket-bearing story marker' {
        $doc = "# Spec`n<!-- speckit-jira story=0123456789abcdef ticket=ALPHA-88 -->`nbody"
        @(Get-JiraMarkerBoundProjects -Content $doc) | Should -Be @('ALPHA')
    }

    It 'C1.3 yields the project of a bound PARENT alone' {
        # The deliberate widening over 033 C3.3, which read the story grammar
        # only. A bound parent pins the project exactly as a bound story does.
        $doc = '<!-- speckit-jira spec=0123456789abcdef ticket=ALPHA-1 -->'
        @(Get-JiraMarkerBoundProjects -Content $doc) | Should -Be @('ALPHA')
    }

    It 'C1.3 yields the project of a bound task marker' {
        $doc = '<!-- speckit-jira task=0123456789abcdef ticket=TASKP-9 -->'
        @(Get-JiraMarkerBoundProjects -Content $doc) | Should -Be @('TASKP')
    }

    It 'C1.2 an in-flight (creating) marker contributes nothing' {
        @(Get-JiraMarkerBoundProjects -Content '<!-- speckit-jira story=0123456789abcdef creating -->').Count | Should -Be 0
    }

    It 'C1.2 a bare assigned marker contributes nothing' {
        @(Get-JiraMarkerBoundProjects -Content '<!-- speckit-jira story=0123456789abcdef -->').Count | Should -Be 0
    }

    It 'C1.2 a document with no marker at all yields the empty set' {
        @(Get-JiraMarkerBoundProjects -Content "# Spec`n`nJust prose, no markers anywhere.").Count | Should -Be 0
    }

    It 'C1.2 empty input yields the empty set' {
        @(Get-JiraMarkerBoundProjects -Content '').Count | Should -Be 0
    }

    It 'C1.2 a malformed marker id contributes nothing' {
        @(Get-JiraMarkerBoundProjects -Content '<!-- speckit-jira story=NOTHEX ticket=ALPHA-88 -->').Count | Should -Be 0
    }

    It 'C1.4 a key not matching the issue-key grammar contributes nothing' {
        @(Get-JiraMarkerBoundProjects -Content '<!-- speckit-jira story=0123456789abcdef ticket=lower-1 -->').Count | Should -Be 0
    }

    It 'C1.1 one bound story among unbound ones yields one element' {
        $doc = @(
            '<!-- speckit-jira story=1111111111111111 -->'
            '<!-- speckit-jira story=2222222222222222 creating -->'
            '<!-- speckit-jira story=3333333333333333 ticket=BETA-7 -->'
        ) -join "`n"
        @(Get-JiraMarkerBoundProjects -Content $doc) | Should -Be @('BETA')
    }

    It 'C1.1 repeated markers in one project yield ONE element' {
        $doc = @(
            '<!-- speckit-jira spec=0000000000000001 ticket=ALPHA-1 -->'
            '<!-- speckit-jira story=1111111111111111 ticket=ALPHA-2 -->'
            '<!-- speckit-jira story=2222222222222222 ticket=ALPHA-3 -->'
        ) -join "`n"
        @(Get-JiraMarkerBoundProjects -Content $doc) | Should -Be @('ALPHA')
    }

    It 'C1.1 markers naming two projects yield both, sorted' {
        $doc = @(
            '<!-- speckit-jira story=1111111111111111 ticket=ZULU-9 -->'
            '<!-- speckit-jira story=2222222222222222 ticket=ALPHA-2 -->'
        ) -join "`n"
        @(Get-JiraMarkerBoundProjects -Content $doc) | Should -Be @('ALPHA', 'ZULU')
    }

    It 'C1.1 a parent and its stories disagreeing yields both' {
        # The state an interrupted re-route leaves behind, and the one C3.1
        # refuses.
        $doc = @(
            '<!-- speckit-jira spec=0000000000000001 ticket=ALPHA-1 -->'
            '<!-- speckit-jira story=1111111111111111 ticket=BETA-2 -->'
        ) -join "`n"
        @(Get-JiraMarkerBoundProjects -Content $doc) | Should -Be @('ALPHA', 'BETA')
    }

    It 'C1.7 a CRLF document yields the same set as an LF one' {
        $doc = "# Spec`r`n<!-- speckit-jira story=0123456789abcdef ticket=ALPHA-88 -->`r`nbody`r`n"
        @(Get-JiraMarkerBoundProjects -Content $doc) | Should -Be @('ALPHA')
    }

    It 'C1.7 a CRLF document with only unbound markers yields the empty set' {
        $doc = "<!-- speckit-jira story=0123456789abcdef creating -->`r`n"
        @(Get-JiraMarkerBoundProjects -Content $doc).Count | Should -Be 0
    }
}
