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
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $Root 'scripts/powershell/engine/StoryMarker.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    # A refusal travels on stderr; the bash twin's `run` merges both streams.
    function Invoke-CapturedBothStreams {
        param([string[]] $ArgList)
        $so = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($so)
        [Console]::SetError($se)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return ($so.ToString() + "`n" + $se.ToString())
    }

    # Sets $script:SpecPath rather than returning it: the JIRA_CONFIG_DIR this
    # sets must reach the caller, and a value captured through a pipeline would
    # leave the run using the repository's own .specify/jira instead of the
    # fixture's — the bash twin failed for exactly that reason first.
    function New-MirroredRepo {
        param([string[]] $MarkerLines)
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $script:SpecPath = Join-Path $work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        (@('# Feature Specification: Billing Invoices', '') + $MarkerLines + @(
            '', '### User Story 1 - Export an invoice (Priority: P1)', '',
            'As a customer, I want to export one invoice as a PDF.', '',
            '- **Given** a signed-in customer viewing an invoice',
            '- **When** they choose Export',
            '- **Then** a PDF download starts'
        )) -join "`n" | Set-Content -NoNewline -Path $script:SpecPath
    }

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

Describe 'reconcile: the properties a message builder cannot prove' {
    AfterEach {
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'C3.3 the split refusal issues ZERO Jira requests — not merely zero writes' {
        # "No POST" is the weaker claim. Both refusals are evaluated before the
        # gate phase, so the call log must be EMPTY: a read that happened would
        # mean the refusal sits downstream of a network call, and C3.3 would be
        # a coincidence of ordering rather than a property of the design.
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        New-MirroredRepo -MarkerLines @(
            '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->',
            '<!-- speckit-jira story=2222222222222222 ticket=LEGACY-9 -->')

        $out = Invoke-CapturedBothStreams @('reconcile', $script:SpecPath, '--dry-run', '--json')
        ([string]$out) | Should -BeLike '*bound to more than one Jira project*'
        ([string]$out) | Should -BeLike '*COMP*'
        ([string]$out) | Should -BeLike '*LEGACY*'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'C3.3 the mismatch refusal issues ZERO Jira requests' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'OTHER'
        New-MirroredRepo -MarkerLines @('<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->')

        $out = Invoke-CapturedBothStreams @('reconcile', $script:SpecPath, '--dry-run', '--json')
        ([string]$out) | Should -BeLike '*does not move a bound specification*'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'C3.5 both refusals downgrade to ONE warning under a hook' {
        # Constitution III: an after_* hook must never fail the host command.
        # This feature adds two refusals, so the CHANGED branch needs its own
        # case rather than inheriting the unchanged one's.
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'

        New-MirroredRepo -MarkerLines @(
            '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->',
            '<!-- speckit-jira story=2222222222222222 ticket=LEGACY-9 -->')
        $out = Invoke-CapturedBothStreams @('reconcile', $script:SpecPath, '--dry-run', '--json')
        ([string]$out) | Should -BeLike '*WARNING: *'
        ([string]$out) | Should -BeLike '*bound to more than one Jira project*'
        ([string]$out) | Should -BeLike '*This spec-kit command completed normally.*'

        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'OTHER'
        New-MirroredRepo -MarkerLines @('<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->')
        $out2 = Invoke-CapturedBothStreams @('reconcile', $script:SpecPath, '--dry-run', '--json')
        ([string]$out2) | Should -BeLike '*WARNING: *'
        ([string]$out2) | Should -BeLike '*does not move a bound specification*'
    }

    It 'C3.4 each refusal is byte-identical with and without --dry-run' {
        # The clause 035 exists to enforce: nothing reported in one mode and
        # withheld in the other. Compared as bytes, not as a substring.
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        New-MirroredRepo -MarkerLines @(
            '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->',
            '<!-- speckit-jira story=2222222222222222 ticket=LEGACY-9 -->')

        $dry = Invoke-CapturedBothStreams @('reconcile', $script:SpecPath, '--dry-run', '--json')
        $real = Invoke-CapturedBothStreams @('reconcile', $script:SpecPath, '--json')
        $real | Should -BeExactly $dry
    }

    It 'FR-009 no run produces an action set naming more than one project' {
        # The invariant the two refusals exist to protect, asserted over the
        # emitted actions rather than inferred from the refusals — so a future
        # path that splits a specification WITHOUT refusing is still caught.
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        New-MirroredRepo -MarkerLines @('<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->')

        $out = Invoke-CapturedBothStreams @('reconcile', $script:SpecPath, '--dry-run', '--json')
        $json = ($out -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1)
        $obj = $json | ConvertFrom-Json -Depth 100
        $projects = @(@($obj.actions) | ForEach-Object { $_.body.fields.project.key } | Where-Object { $_ } | Sort-Object -Unique)
        $projects.Count | Should -BeLessOrEqual 1
    }
}
