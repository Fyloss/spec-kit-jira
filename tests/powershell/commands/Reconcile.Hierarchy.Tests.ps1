# T009 [Phase 1, defect 1] — mirror of tests/bash/commands/test_reconcile_hierarchy.bats.
# A three-story specification must mirror as one parent plus three children,
# each carrying the parent's key. RED until Phase 5 (US2) lands.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    # Config.psm1 imported BEFORE Reconcile.psm1: a -Force reimport of a
    # shared dependency (e.g. Hierarchy.psm1) can tear its exports out of an
    # ALREADY-importing caller's scope and re-scope them to the LATER
    # importer instead (documented landmine — see the project memory on
    # nested -Force imports). Importing Reconcile.psm1 last keeps ITS
    # dependencies (Get-JiraHierarchyMandatoryGate, etc.) the ones this test
    # script actually calls through.
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Output.psm1') -Force

    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing-invoices'
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222 3333333333333333'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }

    function Invoke-CapturedWithCode {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out; $origErr = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($sw)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }
}

Describe 'Invoke-JiraReconcile — the parent hierarchy regression' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'creates one parent and three children' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        $calls = Get-JiraMockCallLog -Mock $script:M
        @($calls | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 4
        @($calls | Where-Object { $_ -match '^PUT /rest/api/3/issue/[^ ]+/properties/spec-kit-jira$' }).Count | Should -Be 4

        (Get-JiraMockIssueField -Mock $script:M -Key 'COMP-1' -Path 'fields.parent') | Should -BeNullOrEmpty
        (Get-JiraMockIssueField -Mock $script:M -Key 'COMP-2' -Path 'fields.parent.key') | Should -Be 'COMP-1'
        (Get-JiraMockIssueField -Mock $script:M -Key 'COMP-3' -Path 'fields.parent.key') | Should -Be 'COMP-1'
        (Get-JiraMockIssueField -Mock $script:M -Key 'COMP-4' -Path 'fields.parent.key') | Should -Be 'COMP-1'
    }

    It 'T113: a specification with no User Story headings mirrors as one parent and one child' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        Set-Content -LiteralPath $script:Spec -Value "# Feature Specification: Billing Invoices`n`nWe need to let customers export invoices.`n"

        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        $calls = Get-JiraMockCallLog -Mock $script:M
        @($calls | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 2

        (Get-JiraMockIssueField -Mock $script:M -Key 'COMP-1' -Path 'fields.parent') | Should -BeNullOrEmpty
        (Get-JiraMockIssueField -Mock $script:M -Key 'COMP-2' -Path 'fields.parent.key') | Should -Be 'COMP-1'
    }

    It 'the specification carries one spec= marker naming the parent, after the H1' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $content = Get-Content -Raw -LiteralPath $script:Spec
        @([regex]::Matches($content, 'speckit-jira spec=[0-9a-f]{16} ticket=COMP-1 -->')).Count | Should -Be 1
    }

    It 'T095: --dry-run predicts the parent''s creation and every child''s parent reference, with zero writes' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $out = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $out.dry_run | Should -Be $true
        $out.actions[0].role | Should -Be 'parent'
        $out.actions[0].method | Should -Be 'POST'
        $out.actions[0].body.fields.summary | Should -Be 'Billing Invoices'
        @($out.actions | Where-Object { $_.role -eq 'story' }).Count | Should -Be 3
        (@($out.actions | Where-Object { $_.role -eq 'story' }))[0].body.fields.parent.key | Should -Be '<resolved at apply time>'
        # The one read this run makes: the duplicate probe (017, US4)
        # predicting the parent's creation. Read-only — zero writes either way.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'search/jql' }).Count | Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' -and $_ -notmatch '/issue/bulkfetch' }).Count | Should -Be 0
    }

    It 'T095: --dry-run predicts a recognised, unchanged parent''s reuse — no parent action, matching the real zero-churn run' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json') # back-fills the provenance label once

        $out = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $out.dry_run | Should -Be $true
        @($out.actions).Count | Should -Be 0
        $out.counts.skipped | Should -Be 3

        $calls = Get-JiraMockCallLog -Mock $script:M
        @($calls | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 4
    }

    It 'T023 [US4] — a retired-key config refuses direct exit 4; under a hook, one WARNING and exit 0' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $lines = @('projects:', '  - key: COMP', '    style: company_managed', '    epic_strategy: per_repo', 'routing_default: COMP')
        Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -Value ($lines -join "`n")

        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        $origErrFirst = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($sw)
        $code = 0
        try { $code = Invoke-JiraReconcile -Arguments @('reconcile', $script:Spec, '--json') } finally { [Console]::SetOut($orig); [Console]::SetError($origErrFirst) }
        $code | Should -Be 4
        $sw.ToString() | Should -Match 'epic_strategy'

        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = 'after_specify'
        $origErr = [Console]::Error
        $sw2 = [System.IO.StringWriter]::new()
        [Console]::SetOut($sw2)
        [Console]::SetError($sw2)
        $code2 = 0
        try { $code2 = Invoke-JiraReconcile -Arguments @('reconcile', $script:Spec, '--json') } finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        $code2 | Should -Be 0
        @([regex]::Matches($sw2.ToString(), '(?m)^WARNING: ')).Count | Should -Be 1
        $sw2.ToString() | Should -Match 'epic_strategy'
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }

    # =========================================================================
    # T047/T052 [Phase 6, US4] — §8 re-validation against the PERSISTED binding
    # =========================================================================
    #
    # Every reconcile run above already exercises the FR-004 case implicitly:
    # the fixture binding carries no `roles` key at all, and reconcile mirrors
    # fine — an absent `roles` key stays non-fatal. These two tests cover the
    # case a stale or hand-edited binding DOES carry `roles`, and check 4
    # (ordering) is re-run against them with no re-read of the project's
    # metadata.

    It 'T047/T052 — an inverted roles ordering in the persisted binding refuses at reconcile, reconcile: prefixed, zero writes' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $localf = Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml'
        $obj = (ConvertFrom-JiraConfigYaml -Path $localf) | ConvertFrom-Json -Depth 100
        $obj.resolved_ids.COMP | Add-Member -NotePropertyName 'roles' -NotePropertyValue ([ordered]@{
                specification = [ordered]@{ logical_name = 'Story'; id = '10004'; hierarchy_level = '0'; subtask = $false; source = 'declared' }
                story         = [ordered]@{ logical_name = 'Epic'; id = '10001'; hierarchy_level = '1'; subtask = $false; source = 'declared' }
            }) -Force
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($localf, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'reconcile: project COMP: specification names'
        $r.Out | Should -Match 'is not above story'

        (Get-JiraMockCallLog -Mock $script:M).Count | Should -Be 0
    }

    It 'T047 — a binding with roles but no task entry mirrors normally (§3.4, absent roles.task is not an error)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $localf = Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml'
        $obj = (ConvertFrom-JiraConfigYaml -Path $localf) | ConvertFrom-Json -Depth 100
        $obj.resolved_ids.COMP | Add-Member -NotePropertyName 'roles' -NotePropertyValue ([ordered]@{
                specification = [ordered]@{ logical_name = 'Epic'; id = '10001'; hierarchy_level = '1'; subtask = $false; source = 'derived' }
                story         = [ordered]@{ logical_name = 'Story'; id = '10004'; hierarchy_level = '0'; subtask = $false; source = 'derived' }
            }) -Force
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($localf, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
    }

    It 'T080 [Phase 9] — reconcile mirrors into the DECLARED types: one parent (Epic), one child per story (Story), each naming the parent' {
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-declared-hierarchy') $work
        $spec = Join-Path $work 'specs/001-consumer-onboarding/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-consumer-onboarding'
        $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222'
        $m = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/consumer-hierarchy.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $m.BaseUrl
        try {
            $r = Invoke-CapturedWithCode @('reconcile', $spec, '--json')
            $r.ExitCode | Should -Be 0

            (Get-JiraMockIssueField -Mock $m -Key 'CONSUMER-1' -Path 'fields.issuetype.id') | Should -Be '10701'
            (Get-JiraMockIssueField -Mock $m -Key 'CONSUMER-1' -Path 'fields.parent') | Should -BeNullOrEmpty
            (Get-JiraMockIssueField -Mock $m -Key 'CONSUMER-2' -Path 'fields.issuetype.id') | Should -Be '10704'
            (Get-JiraMockIssueField -Mock $m -Key 'CONSUMER-2' -Path 'fields.parent.key') | Should -Be 'CONSUMER-1'
            (Get-JiraMockIssueField -Mock $m -Key 'CONSUMER-3' -Path 'fields.issuetype.id') | Should -Be '10704'
            (Get-JiraMockIssueField -Mock $m -Key 'CONSUMER-3' -Path 'fields.parent.key') | Should -Be 'CONSUMER-1'
        }
        finally {
            Stop-JiraMock -Mock $m
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-JiraReconcile — T095 dry-run parity for the mandatory-field refusal' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mandatory-field') $script:Work
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-reporting'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It '--dry-run predicts the mandatory-field refusal exactly as the real run — same exit code, same message, zero writes' {
        # 011, contract §3.10: a direct invocation not passing --accept-defaults is
        # assumed to have a reachable operator, so — unlike before Phase 4 — the
        # REAL run without it would stop for the consolidated question instead of
        # refusing outright (ask defaults to true, contract §3.3). This test's own
        # intent (refusal + dry-run/real agreement, §4.3/§3.6) is unrelated to that
        # question; --accept-defaults on both invocations preserves it, and is
        # itself the §3.10 shape of "a direct script invocation".
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $spec = Join-Path $script:Work 'specs/001-reporting/spec.md'

        $dry = Invoke-CapturedWithCode @('reconcile', $spec, '--dry-run', '--accept-defaults', '--json')
        $dry.ExitCode | Should -Be 4
        $dry.Out | Should -Match 'Deliverable'
        $dry.Out | Should -Match 'Business Owner'

        $real = Invoke-CapturedWithCode @('reconcile', $spec, '--accept-defaults', '--json')
        $real.ExitCode | Should -Be $dry.ExitCode
        $real.Out | Should -Be $dry.Out

        (Get-JiraMockCallLog -Mock $script:M).Count | Should -Be 0
    }
}

Describe 'Invoke-JiraReconcile — 011, contract §3.3 trigger 1' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mandatory-field') $script:Work
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-reporting'
        $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'once both required fields are recorded, reconcile asks to CONFIRM them before creating — it does not apply them silently' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $spec = Join-Path $script:Work 'specs/001-reporting/spec.md'

        # Config's own structural gate (pre-existing, unchanged by this
        # feature — plan.md's Summary) only lets the ceremony complete once
        # every required field of a bridge-written type is resolved —
        # recording BOTH here is what makes the project's binding
        # satisfiable at all (US1). `ask` defaults to true, so the NEXT
        # reconcile, with no --accept-defaults, hits trigger 1 (§3.3: "a
        # recorded default would be sent") and stops to confirm rather than
        # silently sending it.
        $cfgCode = Invoke-JiraConfig -Arguments @('config', 'PM', '--issue-type', 'PM=story=Story', `
                '--field-default', 'PM=Deliverable=Business Owner=Platform Team', `
                '--field-default', 'PM=Deliverable=Program Increment=PI-2026-Q3', '--json')
        $cfgCode | Should -Be 0

        $first = Invoke-CapturedWithCode @('reconcile', $spec, '--json')
        $first.ExitCode | Should -Be 0
        $firstObj = $first.Out | ConvertFrom-Json
        $firstObj.status | Should -Be 'confirmation-pending'
        $firstObj.creations_pending | Should -BeGreaterThan 0
        ($firstObj.fields | Where-Object { $_.label -eq 'Business Owner' }).recorded_value | Should -Be 'Platform Team'
        ($firstObj.fields | Where-Object { $_.label -eq 'Program Increment' }).recorded_value | Should -Be 'PI-2026-Q3'
        $firstObj.resume_with | Should -Match '--accept-defaults'
        (Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^POST /rest/api/3/issue$' }).Count | Should -Be 0
        (Get-Content -Raw -LiteralPath $spec) | Should -Not -Match 'speckit-jira'

        $second = Invoke-CapturedWithCode @('reconcile', $spec, '--accept-defaults', '--json')
        $second.ExitCode | Should -Be 0
        $secondObj = $second.Out | ConvertFrom-Json
        ($secondObj.PSObject.Properties.Match('status')).Count | Should -Be 0
        $parentAction = $secondObj.actions | Where-Object { $_.role -eq 'parent' }
        $parentAction.body.fields.customfield_40011 | Should -Be 'Platform Team'
        $parentAction.body.fields.customfield_40012 | Should -Be 'PI-2026-Q3'
    }
}
