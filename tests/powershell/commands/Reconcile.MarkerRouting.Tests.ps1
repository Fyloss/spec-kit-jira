# T015 [Phase 3+4, US1/US2, 035] — mirror of
# tests/bash/commands/test_reconcile_marker_routing.bats. The command layer's
# use of the specification's own record
# (contracts/marker-routing.md C2.1, C3.1-C3.6).
#
# The defect this reproduces: at /speckit.specify the specification is unbound,
# rank 4 places it in the operator's team project, and its keys are recorded in
# spec.md. At /speckit.plan the same specification is bound, 033's guard fires
# BECAUSE the first run succeeded, and resolution falls to routing_default — a
# different project. Story recognition then classifies every bound story as NEW.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/engine/StoryMarker.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force

    $script:Cfg = '{"projects":[{"key":"ALPHA"},{"key":"BETA"}],"routing_default":"BETA","teams":[{"id":"alpha","project":"ALPHA","folder_prefix":"alpha-"},{"id":"beta","project":"BETA","folder_prefix":"beta-"}]}'

    # A specification whose parent and stories are recorded in ALPHA, in a
    # folder carrying no team-specific prefix — the observed shape exactly.
    $script:BoundSpec = @(
        '# Feature Specification: Test feature'
        ''
        '<!-- speckit-jira spec=0000000000000001 ticket=ALPHA-66 -->'
        ''
        '### User Story 1 - core story (Priority: P1)'
        ''
        '<!-- speckit-jira story=1111111111111111 ticket=ALPHA-67 -->'
        ''
        '- **Given** a signed-in user'
    ) -join "`n"
}

Describe 'reconcile: routing follows the specification''s own record' {
    It 'C2.1 a bound specification routes to its own project, not routing_default' {
        $proj = @(Get-JiraMarkerBoundProjects -Content $script:BoundSpec)[0]
        $r = Resolve-JiraReconcileRouting -Folder '031-test-feature' -ConfigJson $script:Cfg -MarkerProject $proj
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.1 it routes to its own project whichever team the operator selected' {
        $proj = @(Get-JiraMarkerBoundProjects -Content $script:BoundSpec)[0]
        $r = Resolve-JiraReconcileRouting -Folder '031-test-feature' -ConfigJson $script:Cfg -SelectedTeamId 'beta' -MarkerProject $proj
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.5 an unbound specification is routed exactly as it is today' {
        # The regression that matters most: every existing repository untouched.
        $r = Resolve-JiraReconcileRouting -Folder '031-test-feature' -ConfigJson $script:Cfg
        $r.ProjectKey | Should -Be 'BETA'
    }
}

Describe 'reconcile: the two mismatch refusals' {
    It 'C3.1 markers naming two projects: the refusal names the spec and EVERY project' {
        $out = Get-JiraReconcileMarkersSplitRefusal -SpecFile 'specs/031-test-feature/spec.md' -Projects @('ALPHA', 'BETA')
        $out | Should -BeLike '*specs/031-test-feature/spec.md*'
        $out | Should -BeLike '*ALPHA*'
        $out | Should -BeLike '*BETA*'
        $out | Should -BeLike '*zero writes*'
    }

    It 'C3.6 the split refusal tells the operator what to do next' {
        $out = Get-JiraReconcileMarkersSplitRefusal -SpecFile 'specs/031-test-feature/spec.md' -Projects @('ALPHA', 'BETA')
        $out | Should -BeLike '*ticket=*'
    }

    It 'C3.2 the mismatch refusal names recorded, routed, and the override as source' {
        $out = Get-JiraReconcileProjectMismatchRefusal -SpecFile 'specs/031-test-feature/spec.md' -Recorded 'ALPHA' -Routed 'BETA' -Source 'override'
        $out | Should -BeLike '*specs/031-test-feature/spec.md*'
        $out | Should -BeLike '*ALPHA*'
        $out | Should -BeLike '*BETA*'
        $out | Should -BeLike '*SPEC_KIT_JIRA_PROJECT_KEY*'
        $out | Should -BeLike '*zero writes*'
    }

    It 'C3.2 the mismatch refusal names the committed configuration when that is the source' {
        $out = Get-JiraReconcileProjectMismatchRefusal -SpecFile 'specs/031-test-feature/spec.md' -Recorded 'ALPHA' -Routed 'BETA' -Source 'config'
        $out | Should -BeLike '*config.yml*'
        $out | Should -Not -BeLike '*SPEC_KIT_JIRA_PROJECT_KEY*'
    }

    It 'C3.2 the mismatch refusal says the bridge does not move a bound spec on its own' {
        $out = Get-JiraReconcileProjectMismatchRefusal -SpecFile 'specs/031-test-feature/spec.md' -Recorded 'ALPHA' -Routed 'BETA' -Source 'config'
        $out | Should -BeLike '*does not move*'
    }

    It 'FR-007 an undeclared project coming from the markers says so' {
        # The existing unknown-project refusal blames a routing rule, a teams[]
        # entry or routing_default. None of those placed it when the record did,
        # and sending the operator to edit config.yml's routing would be advice
        # for a file that is already correct.
        $out = Get-JiraReconcileUnknownProjectRefusal -Key 'GHOST' -ConfigDir '.specify/jira' -Source 'marker' -SpecFile 'specs/031-test-feature/spec.md'
        $out | Should -BeLike '*GHOST*'
        $out | Should -BeLike '*markers*'
        $out | Should -BeLike '*zero writes*'
    }

    It 'FR-007 an undeclared project coming from routing keeps today''s wording' {
        $out = Get-JiraReconcileUnknownProjectRefusal -Key 'GHOST' -ConfigDir '.specify/jira' -Source 'routing'
        $out | Should -BeLike '*GHOST*'
        $out | Should -BeLike '*routing rule*'
        $out | Should -Not -BeLike '*markers*'
    }
}
