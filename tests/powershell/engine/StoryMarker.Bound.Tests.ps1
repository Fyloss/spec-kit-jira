# T007 [Phase 3, US1] — mirror of tests/bash/engine/test_story_marker_bound.bats.
# The boundness predicate (contracts/routing-resolution.md C3.3; spec FR-004).
#
# Routing rank 3 applies ONLY to a specification none of whose stories is
# already bound. Only the ticket-bearing marker form counts: `creating` is a run
# in flight and a bare marker is assigned-but-not-created, and neither pins a
# project.
#
# The C3.4 spawn assertion has no twin here: the counting harness is bash-only
# (tests/bash/helpers/spawn_count.bash), which is a deliberate asymmetry
# recorded in tasks.md T014.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $EngineDir = Join-Path $Root 'scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'StoryMarker.psm1') -Force
}

Describe 'Test-JiraStoryMarkerAnyBound' {

    It 'C3.3 a ticket-bearing marker counts as bound' {
        $doc = "# Spec`n<!-- speckit-jira story=0123456789abcdef ticket=ALPHA-88 -->`nbody"
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeTrue
    }

    It 'C3.3 an in-flight (creating) marker does NOT count as bound' {
        $doc = "# Spec`n<!-- speckit-jira story=0123456789abcdef creating -->`nbody"
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeFalse
    }

    It 'C3.3 a bare assigned marker does NOT count as bound' {
        $doc = "# Spec`n<!-- speckit-jira story=0123456789abcdef -->`nbody"
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeFalse
    }

    It 'C3.3 a specification with no marker at all is not bound' {
        Test-JiraStoryMarkerAnyBound -Content "# Spec`n`nJust prose." | Should -BeFalse
    }

    It 'C3.3 empty input is not bound' {
        Test-JiraStoryMarkerAnyBound -Content '' | Should -BeFalse
    }

    It 'C3.3 one bound story among several unbound ones counts as bound' {
        $doc = "<!-- speckit-jira story=1111111111111111 -->`n" +
               "<!-- speckit-jira story=2222222222222222 creating -->`n" +
               "<!-- speckit-jira story=3333333333333333 ticket=BETA-7 -->"
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeTrue
    }

    It 'C3.3 a spec marker (not a story marker) does not count' {
        $doc = '<!-- speckit-jira spec=0123456789abcdef ticket=ALPHA-1 -->'
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeFalse
    }

    It 'C3.3 a malformed story id is not a marker and does not count' {
        $doc = '<!-- speckit-jira story=NOTHEX ticket=ALPHA-88 -->'
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeFalse
    }

    It 'C3.3 a malformed ticket key does not count as bound' {
        $doc = '<!-- speckit-jira story=0123456789abcdef ticket=lower-1 -->'
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeFalse
    }

    It 'C7.3 a CRLF document is recognised identically' {
        $doc = "# Spec`r`n<!-- speckit-jira story=0123456789abcdef ticket=ALPHA-88 -->`r`nbody`r`n"
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeTrue
    }

    It 'C7.3 a CRLF document with only unbound markers is not bound' {
        $doc = "<!-- speckit-jira story=0123456789abcdef creating -->`r`n"
        Test-JiraStoryMarkerAnyBound -Content $doc | Should -BeFalse
    }
}
