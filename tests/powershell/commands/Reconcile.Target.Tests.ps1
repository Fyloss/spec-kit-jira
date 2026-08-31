# T007 [US1] — The target guard. Pester twin of
# tests/bash/commands/test_reconcile_target.bats. Carries one case the Bash
# twin cannot: the native `specs\001-x\spec.md` separator spelling passes
# (research R3).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out; $oe = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($se)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'Target guard (US1)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-target'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10004","parent_type_id":"10101"}'
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue

        New-Item -ItemType Directory -Path (Join-Path $script:Work 'specs/001-test-page') -Force | Out-Null
        $script:SpecPath = Join-Path $script:Work 'specs/001-test-page/spec.md'
        @(
            '# Feature Specification: Target Guard', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a signed-in user', '- **When** they open the board', '- **Then** the widgets load'
        ) -join "`n" | Set-Content -LiteralPath $script:SpecPath -NoNewline
        $script:PlanPath = Join-Path $script:Work 'specs/001-test-page/plan.md'
        'Some plan content.' | Set-Content -LiteralPath $script:PlanPath -NoNewline

        $script:M = Start-JiraMock -ConfigPath (New-Item -ItemType File -Path (Join-Path $script:Work 'mock.json') -Value '{}' -Force).FullName
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'refuses plan.md before any request, exit 1, plan.md untouched (§5 T1, T2)' {
        $before = Get-Content -Raw -LiteralPath $script:PlanPath
        $r = Invoke-Captured @('reconcile', '--json', $script:PlanPath)
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'is not a feature specification'
        ($r.Out + $r.Err) | Should -Match ([regex]::Escape("the target for this folder is `"$script:SpecPath`""))
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
        (Get-Content -Raw -LiteralPath $script:PlanPath) | Should -Be $before
    }

    It 'names the sibling in the caller''s own separator, never renormalised (§3, FR-027)' {
        # The provider's path primitives rewrite every separator to the host's
        # native one, so a target spelled with the other separator came back
        # with a mixed <sibling> — on Windows that is the very forward-slash
        # spelling every scenario and every caller above uses, which is why the
        # §5 T1 case above was red there and green everywhere else.
        Push-Location $script:Work
        try {
            $r = Invoke-Captured @('reconcile', '--json', 'specs\001-test-page\plan.md')
            $r.ExitCode | Should -Be 1
            ($r.Out + $r.Err) | Should -Match ([regex]::Escape('the target for this folder is "specs\001-test-page\spec.md"'))
        }
        finally { Pop-Location }
    }

    It 'refuses every non-spec.md sibling artifact (§5 T3)' {
        foreach ($name in @('tasks.md', 'research.md', 'data-model.md', 'quickstart.md', 'spec.md.bak', 'my-spec.md')) {
            $p = Join-Path $script:Work "specs/001-test-page/$name"
            'content' | Set-Content -LiteralPath $p -NoNewline
            $r = Invoke-Captured @('reconcile', '--json', $p)
            $r.ExitCode | Should -Be 1
            ($r.Out + $r.Err) | Should -Match 'is not a feature specification'
        }
    }

    It 'refuses contracts/api.md — no spec.md in that folder (§5 T3)' {
        New-Item -ItemType Directory -Path (Join-Path $script:Work 'specs/001-test-page/contracts') -Force | Out-Null
        $p = Join-Path $script:Work 'specs/001-test-page/contracts/api.md'
        'content' | Set-Content -LiteralPath $p -NoNewline
        $r = Invoke-Captured @('reconcile', '--json', $p)
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'no spec.md exists in that folder'
    }

    It 'refuses SPEC.MD — the comparison is case-sensitive (§5 T4)' {
        $p = Join-Path $script:Work 'specs/001-test-page/SPEC.MD'
        'content' | Set-Content -LiteralPath $p -NoNewline
        $r = Invoke-Captured @('reconcile', '--json', $p)
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'is not a feature specification'
    }

    It 'under each of the six lifecycle events the refusal returns 0, wrapped (§5 T5, SC-001)' {
        foreach ($evt in @('after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_analyze', 'after_implement')) {
            $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
            $env:SPEC_KIT_JIRA_HOOK_EVENT = $evt
            $r = Invoke-Captured @('reconcile', '--json', $script:PlanPath)
            $r.ExitCode | Should -Be 0
            ($r.Out + $r.Err) | Should -Match '^WARNING: .*is not a feature specification.*This spec-kit command completed normally\.'
            @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
        }
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
    }


    It 'a valid spec.md run behaves exactly as before this feature (§5 T7)' {
        $r = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecPath)
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json -Depth 100
        $obj.actions[0].role | Should -Be 'parent'
        ($obj.PSObject.Properties.Name -contains 'warnings') | Should -Be $false
    }

    It 'stray markers in plan.md produce one warning and plan.md stays untouched (§5 T9)' {
        @('Some plan content.', '<!-- speckit-jira spec=0123456789abcdef ticket=COMP-1 -->') -join "`n" | Set-Content -LiteralPath $script:PlanPath -NoNewline
        $before = Get-Content -Raw -LiteralPath $script:PlanPath
        $r = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecPath)
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json -Depth 100
        @($obj.warnings).Count | Should -BeGreaterOrEqual 1
        (($obj.warnings) -join ',') | Should -Match 'plan.md'
        (Get-Content -Raw -LiteralPath $script:PlanPath) | Should -Be $before
    }

    It 'refuses identically under --dry-run (§5 T10)' {
        $r = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:PlanPath)
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'is not a feature specification'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'keeps today''s readability message for a directory target (§5 T11)' {
        $r = Invoke-Captured @('reconcile', '--json', (Join-Path $script:Work 'specs/001-test-page'))
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'a readable spec file argument is required'
        ($r.Out + $r.Err) | Should -Not -Match 'is not a feature specification'
    }

    It 'keeps today''s readability message for a non-existent path (§5 T11)' {
        $r = Invoke-Captured @('reconcile', '--json', (Join-Path $script:Work 'specs/001-test-page/nope.md'))
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'a readable spec file argument is required'
    }

    It 'refuses a symlink not named spec.md even though it resolves to spec.md (§5 T11)' {
        $link = Join-Path $script:Work 'specs/001-test-page/renamed-link.md'
        New-Item -ItemType SymbolicLink -Path $link -Target $script:SpecPath -ErrorAction Stop | Out-Null
        $r = Invoke-Captured @('reconcile', '--json', $link)
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'is not a feature specification'
    }

    It 'refuses a path carrying trailing whitespace (§5 T11)' {
        $p = Join-Path $script:Work 'specs/001-test-page/spec.md '
        'content' | Set-Content -LiteralPath $p -NoNewline
        $r = Invoke-Captured @('reconcile', '--json', $p)
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'is not a feature specification'
    }

    It 'passes a symlink named spec.md (§5 T12)' {
        New-Item -ItemType Directory -Path (Join-Path $script:Work 'other') -Force | Out-Null
        $link = Join-Path $script:Work 'other/spec.md'
        New-Item -ItemType SymbolicLink -Path $link -Target $script:SpecPath -ErrorAction Stop | Out-Null
        $r = Invoke-Captured @('reconcile', '--dry-run', '--json', $link)
        $r.ExitCode | Should -Be 0
        ($r.Out + $r.Err) | Should -Not -Match 'is not a feature specification'
    }

    It 'passes the relative spelling ./specs/001-test-page/spec.md (§5 T12)' {
        Push-Location $script:Work
        try {
            $r = Invoke-Captured @('reconcile', '--dry-run', '--json', './specs/001-test-page/spec.md')
            $r.ExitCode | Should -Be 0
            ($r.Out + $r.Err) | Should -Not -Match 'is not a feature specification'
        }
        finally { Pop-Location }
    }

    It 'passes the native separator spelling specs\001-test-page\spec.md (research R3, pwsh-only)' {
        Push-Location $script:Work
        try {
            $native = 'specs\001-test-page\spec.md'
            $r = Invoke-Captured @('reconcile', '--dry-run', '--json', $native)
            $r.ExitCode | Should -Be 0
            ($r.Out + $r.Err) | Should -Not -Match 'is not a feature specification'
        }
        finally { Pop-Location }
    }

    It 'refuses the native separator spelling specs\001-test-page\plan.md (research R3, pwsh-only)' {
        Push-Location $script:Work
        try {
            $native = 'specs\001-test-page\plan.md'
            $r = Invoke-Captured @('reconcile', '--json', $native)
            $r.ExitCode | Should -Be 1
            ($r.Out + $r.Err) | Should -Match 'is not a feature specification'
        }
        finally { Pop-Location }
    }

    # PLACED LAST DELIBERATELY. This file has an order dependency that predates
    # 034: 'a valid spec.md run behaves exactly as before this feature' passes
    # only in a full run and fails in isolation — verified against the
    # pre-change tree, so it is not this feature's doing. Reconcile.psm1 carries
    # $script:-scoped state between Its (Pester runs them in one process) and a
    # per-test -Force re-import does NOT reset it, so the real fix is a separate
    # piece of work.
    #
    # The test below runs a real reconcile, which perturbs that state; the test
    # it replaced threw on a missing cmdlet before doing any work and perturbed
    # nothing. Running it last preserves the existing order exactly.
    It '034 T032 — a dispatched event now reaches the target guard instead of exiting silently' {
        # THE CHANGED BRANCH. Twin of the bats test of the same name. This
        # replaces 'a disabled event silences even the rejected-target refusal',
        # which asserted the opposite: that an event recorded as disabled made
        # reconcile return 0 with no output at all, before the target guard ran.
        #
        # 034 removed that dispatch hold along with the record it consulted.
        # What must still hold is everything downstream: the target guard still
        # refuses a non-spec.md target, and hook context still keeps the host
        # command at exit 0 (FR-007). The unchanged branch is covered by
        # tests/powershell/hooks/HookResilience.Tests.ps1.
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        $r = Invoke-Captured @('reconcile', '--json', $script:PlanPath)
        $r.ExitCode | Should -Be 0
        ($r.Out + $r.Err) | Should -Match 'is not a feature specification'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ }).Count | Should -Be 0
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }
}
