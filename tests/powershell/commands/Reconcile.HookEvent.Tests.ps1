# T022, T024, T026 [Phase 3, US2] — the event that fired actually reaches
# the mirror, PowerShell port. Mirror of
# tests/bash/commands/test_reconcile_hook_event.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
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
      after_clarify: "Clarified"
      after_plan: "Planned"
      after_tasks: "Tasked"
      after_implement: "Implemented"
      after_analyze: "Analyzed"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@

    function Invoke-Captured {
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

    # COMP-2's own "advanced Jira-side" drift warning, isolated from the
    # fixture's unrelated noise (COMP-3/COMP-4's own unreachable-transition
    # warnings, and a stray "markers found" note the fixture always raises).
    function Get-Comp2DriftWarning {
        param($Warnings)
        (@($Warnings) | Where-Object { $_ -like 'ticket advanced*' }) -join ' '
    }

    function Get-LifecycleWarningCount {
        param($Warnings)
        (@($Warnings) | Where-Object { $_ -like 'ticket*' -or $_ -like 'Story ticket*' -or $_ -like '*was not moved*' }).Count
    }
}

Describe 'Invoke-JiraReconcile — the event that fired actually reaches the mirror' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.yml') -Value $script:ConfigYaml
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        # COMP-2 stands at "Analyzed" — after_analyze's own declared step
        # and the LAST in canonical order, so it is "ahead" of every other
        # event's target and only even with its own.
        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"Analyzed","statusCategory":{"key":"indeterminate"}}}}' | Out-Null
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T022 -- each of the six after-events resolves its own declared step, six distinct outcomes' {
        $target = [ordered]@{
            after_specify   = 'To Do'
            after_clarify   = 'Clarified'
            after_plan      = 'Planned'
            after_tasks     = 'Tasked'
            after_implement = 'Implemented'
            after_analyze   = 'Analyzed'
        }
        foreach ($event in $target.Keys) {
            $env:SPEC_KIT_JIRA_HOOK_EVENT = $event
            try {
                $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
            }
            finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
            $warn = Get-Comp2DriftWarning -Warnings $r.warnings
            if ($event -eq 'after_analyze') {
                $warn | Should -BeNullOrEmpty
            }
            else {
                $warn | Should -Match ([regex]::Escape('"' + $target[$event] + '"'))
                foreach ($other in $target.Keys) {
                    if ($other -eq $event -or $other -eq 'after_analyze') { continue }
                    $warn | Should -Not -Match ([regex]::Escape('"' + $target[$other] + '"'))
                }
            }
        }
    }

    It 'T024 -- with no event set, no drift rule is evaluated and nothing is asked of the tracker' {
        Clear-Content -LiteralPath $script:M.CallLog
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        (Get-LifecycleWarningCount -Warnings $r.warnings) | Should -Be 0
        $r.counts.PSObject.Properties.Name | Should -Not -Contain 'transitioned'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'transitions' }).Count | Should -Be 0
    }

    It 'T026 -- an unrecognised event value behaves as no event: zero reads, zero warnings, never a config refusal' {
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_launch_party'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        (Get-LifecycleWarningCount -Warnings $r.warnings) | Should -Be 0
        $r.counts.PSObject.Properties.Name | Should -Not -Contain 'transitioned'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'transitions' }).Count | Should -Be 0
    }
}
