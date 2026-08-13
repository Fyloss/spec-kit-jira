# T046-T050 [Phase 6, US4] — recognition feeds the safety rules, PowerShell
# side. Mirror of tests/bash/commands/test_reconcile_lifecycle.bats.
# Cross-port parity is proven in bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Config.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    # 023: the parent shares the SAME lifecycle-context tickets map as
    # stories now (role "specification", keyed by local_id) — a 3-item
    # source wraps and hands the epic the same local_id as the first story,
    # silently overwriting its zero-churn/lifecycle snapshot. A 4th distinct
    # id keeps every local_id unique.
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    # Relies on config.yml-based routing (folder prefix "001-" -> COMP); clear
    # any override an earlier suite in the same Pester process left behind.
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    $script:ConfigYaml = @'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
    halted_statuses:
      - "Blocked"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@

    function Invoke-Captured {
        # Mirrors bats' `run`: stdout and stderr merged into one string, since
        # WARNING lines (FR-016) are written to stderr, not the --json summary.
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out
        $oe = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
        return $sw.ToString() + $se.ToString()
    }
}

Describe 'Invoke-JiraReconcile — the drift, halted, and Flagged rules engage against recognised state' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.yml') -Value $script:ConfigYaml
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It "a mapped ticket advanced beyond the event's phase raises a named drift warning, content still reconciles (FR-031)" {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}' | Out-Null

        $content = (Get-Content -Raw -LiteralPath $script:Spec) -replace 'export one invoice as a PDF', 'export one invoice as a PDF file'
        Set-Content -NoNewline -Path $script:Spec -Value $content

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @($r.warnings).Count | Should -BeGreaterOrEqual 1
        $r.warnings[0] | Should -BeLike '*In Progress*'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'PUT /rest/api/3/issue/COMP-2' }).Count | Should -Be 1
    }

    It 'a halted ticket has its content write suppressed and a named warning' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"Blocked","statusCategory":{"key":"indeterminate"}}}}' | Out-Null

        $content = (Get-Content -Raw -LiteralPath $script:Spec) -replace 'export one invoice as a PDF', 'export one invoice as a PDF file'
        Set-Content -NoNewline -Path $script:Spec -Value $content

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        $r.warnings[0] | Should -BeLike '*halted*'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'PUT /rest/api/3/issue/COMP-2' }).Count | Should -Be 0
    }

    It 'a Flagged ticket has its transition withheld, is surfaced, and no flag write is emitted' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-3" `
            -ContentType 'application/json' `
            -Body '{"fields":{"Flagged":[{"value":"Impediment"}]}}' | Out-Null

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        (@($r.warnings) -join ' ') | Should -BeLike '*Flagged*'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'Flagged' }).Count | Should -Be 0
    }

    It 'a project declaring no phase_status_map issues zero transition requests' {
        # T055: mirror of the bats fix at tests/bash/commands/test_reconcile_lifecycle.bats
        # "a project declaring no phase_status_map issues zero transition
        # requests" — the old pin here declared a phase_status_map (via
        # $script:ConfigYaml) yet asserted on a regex, `/transitions$`, that
        # never matches the real `?expand=...` query string, making it a
        # silent false-pass regardless of what the config declared. Rewritten
        # to assert what stays true: no mapping declared = zero requests.
        $noMapConfig = @'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.yml') -Value $noMapConfig

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'transitions' }).Count | Should -Be 0
    }

    It 'under SPEC_KIT_JIRA_HOOK_CONTEXT every recognition failure exits 0 with exactly one WARNING' {
        $faultsPath = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        '{"faults": {"issue/COMP-1": {"status": 401}}}' | Set-Content -NoNewline -Path $faultsPath
        $script:M = Start-JiraMock -ConfigPath $faultsPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        # Seed COMP-1 as already bound so the SECOND run's recognition read
        # actually hits the faulted path.
        try { $null = Invoke-Captured @('reconcile', $script:Spec, '--json') } catch {}

        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        try {
            $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue }
        $script:code | Should -Be 0
        @([regex]::Matches($out, 'WARNING:')).Count | Should -Be 1
    }

    It 'T085 [Phase 9] — a §6 role-mapping refusal (inverted ordering) exits 4 directly, and downgrades to one WARNING under a hook' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        $localf = Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml'
        $localJson = ConvertFrom-JiraConfigYaml -Path $localf
        $rolesPatch = '{"resolved_ids":{"COMP":{"roles":{
            "specification": {"logical_name":"Story","id":"10004","hierarchy_level":"0","subtask":false,"source":"declared"},
            "story": {"logical_name":"Epic","id":"10001","hierarchy_level":"1","subtask":false,"source":"declared"}
        }}}}'
        $merged = ($localJson | & jq -cS --argjson patch $rolesPatch '.resolved_ids.COMP.roles = $patch.resolved_ids.COMP.roles')
        $yaml = ConvertTo-JiraConfigYaml -Json $merged
        Set-Content -LiteralPath $localf -Value $yaml -NoNewline

        $r = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $script:code | Should -Be 4
        $r | Should -Match 'reconcile: project COMP: specification names'

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        try {
            $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue }
        $script:code | Should -Be 0
        @([regex]::Matches($out, 'WARNING: ')).Count | Should -Be 1
        $out | Should -Match 'is not above story'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -notlike 'GET *' }).Count | Should -Be 0
    }

    It 'T081 -- with story declared alone, stories advance and the parent is untouched, no warning about it' {
        $twoRoleFixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-two-role-workflows'
        $twork = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $twoRoleFixture $twork
        $tspec = Join-Path $twork 'specs/001-two-role-example/spec.md'

        # Per-role, but ONLY `story` declared -- no `specification` key at
        # all (distinct from T077/B2's role-blind case, and from T079's
        # both-roles case).
        $storyOnlyConfig = @'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      story:
        after_specify: "To Do"
        after_plan: "In Progress"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@
        Set-Content -NoNewline -Path (Join-Path $twork '.specify/jira/config.yml') -Value $storyOnlyConfig
        $env:JIRA_CONFIG_DIR = Join-Path $twork '.specify/jira'

        $m = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/comp-two-role-transitions.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $m.BaseUrl
            $null = Invoke-Captured @('reconcile', $tspec, '--json')

            # Put the parent somewhere a specification-role mapping WOULD
            # treat as advanced-beyond-target, if it were ever evaluated
            # at all.
            Invoke-RestMethod -Method Put -Uri "$($m.BaseUrl)/rest/api/3/issue/COMP-1" `
                -ContentType 'application/json' `
                -Body '{"fields":{"status":{"name":"Building","statusCategory":{"key":"indeterminate"}}}}' | Out-Null

            Clear-Content -LiteralPath $m.CallLog
            $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
            try {
                $r = Invoke-Captured @('reconcile', $tspec, '--json') | ConvertFrom-Json
            }
            finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }

            # Stories advance normally.
            $expected = @{ 'COMP-2' = '202'; 'COMP-3' = '203'; 'COMP-4' = '204' }
            foreach ($key in $expected.Keys) {
                $t = @($r.actions | Where-Object { ([string]$_.url).EndsWith("/rest/api/3/issue/$key/transitions") })
                $t.Count | Should -Be 1
                [string]$t[0].body.transition.id | Should -Be $expected[$key]
            }

            # The parent is never read for transitions, never moved, and
            # no warning ever names it.
            @(Get-JiraMockCallLog -Mock $m | Where-Object { $_ -match 'COMP-1/transitions' }).Count | Should -Be 0
            @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-1/transitions') }).Count | Should -Be 0
            (@($r.warnings) -join ' ') | Should -Not -Match 'COMP-1'
        }
        finally { Stop-JiraMock -Mock $m }
    }
}

# --- T160 [Phase 12, US10]: the dry-run twin, four outcomes (contract §7
# Z4). Mirror of test_reconcile_lifecycle.bats's T159.

Describe 'Invoke-JiraReconcile — the dry-run preview twin (US10, Z4)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.yml') -Value $script:ConfigYaml
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'the dry-run preview predicts move/ambiguous/gated outcomes identically to the real run, and writes nothing' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/comp-transitions.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        $preview = Invoke-Captured @('reconcile', $script:Spec, '--json', '--dry-run') | ConvertFrom-Json
        $preview.dry_run | Should -Be $true
        # Zero transition WRITES in the preview -- the availability READS
        # the decision needs still fire.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^POST .*/transitions$' }).Count | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^GET .*/transitions\?expand=' }).Count | Should -Be 3

        Clear-Content -LiteralPath $script:M.CallLog
        $real = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        $real.dry_run | Should -Be $false

        # Identical predicted vs. performed.
        [int]$preview.counts.transitioned | Should -Be ([int]$real.counts.transitioned)
        (ConvertTo-Json $preview.warnings -Compress) | Should -Be (ConvertTo-Json $real.warnings -Compress)
        $previewMove = @($preview.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-2/transitions') })[0]
        $realMove = @($real.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-2/transitions') })[0]
        [string]$previewMove.body.transition.id | Should -Be ([string]$realMove.body.transition.id)

        # The real run, unlike the preview, actually issues the one write.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^POST .*/transitions$' }).Count | Should -Be 1
    }

    It 'the dry-run preview predicts an unreachable outcome identically to the real run (all three wordings), and writes nothing' {
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"transitions":{"COMP-2":[{"id":"201","name":"Review","to":{"name":"Under Review"},"fields":{}}],"COMP-3":[],"COMP-4":[{"id":"203","name":"Start","to":{"name":"in progress"},"fields":{}}]}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        $preview = Invoke-Captured @('reconcile', $script:Spec, '--json', '--dry-run') | ConvertFrom-Json
        $preview.dry_run | Should -Be $true
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^POST .*/transitions$' }).Count | Should -Be 0

        Clear-Content -LiteralPath $script:M.CallLog
        $real = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        $real.dry_run | Should -Be $false

        (ConvertTo-Json $preview.warnings -Compress) | Should -Be (ConvertTo-Json $real.warnings -Compress)
        # Never forces an intermediate move, in either mode.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^POST .*/transitions$' }).Count | Should -Be 0
    }
}
