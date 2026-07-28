# T044 [US1] — The privacy guard applies to adoption with NO exemption,
# PowerShell side. Mirror of tests/bash/sink/test_adoption_privacy.bats
# (003 FR-028, FR-030, Principle IX).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/PlanApply.psm1') -Force
    # Adoption is imported LAST so its exports are not re-scoped by the nested
    # -Force import inside PlanApply (the nested-import re-scope trap).
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Adoption.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $script:Bindings = @'
[{"spec_folder":"003-a","level":"feature","story_ordinal":null,"issue_key":"ADO-1",
  "reason":"label-match","overrode_key":null,"status":"adopt"},
 {"spec_folder":"003-a","level":"story","story_ordinal":1,"issue_key":"ADO-2",
  "reason":"label-match","overrode_key":null,"status":"adopt"}]
'@
    # Pester 5 resolves helper functions from the BeforeAll scope, not from a
    # definition inside Describe.
    function Get-PutCount {
        return @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count
    }
}

Describe 'The stamp set cannot bypass the pre-write guard' {
    BeforeEach {
        $script:Mock = Start-JiraMock -ConfigJson '{"projects":{"ADO":"company"}}'
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item env:SPEC_KIT_JIRA_ALLOWLIST -ErrorAction SilentlyContinue
    }

    It 'writes a clean stamp set (control)' {
        $actions = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/app'
        (Invoke-JiraApplyWriteSet -ActionsJson $actions) | Should -Be 0
        Get-PutCount | Should -Be 2
    }

    It 'blocks a Cloud host in the payload with exit 9 and ZERO writes' {
        $actions = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/mirror-of-acme.atlassian.net'
        (Invoke-JiraApplyWriteSet -ActionsJson $actions) | Should -Be 9
        Get-PutCount | Should -Be 0
    }

    It 'blocks a token shape in the payload with exit 9 and ZERO writes' {
        $actions = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/ATATT3xFfGF0leaked'
        (Invoke-JiraApplyWriteSet -ActionsJson $actions) | Should -Be 9
        Get-PutCount | Should -Be 0
    }

    It 'blocks a known coordinate in the payload with exit 9 and ZERO writes' {
        $actions = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/ops-known-coordinate'
        (Invoke-JiraApplyWriteSet -ActionsJson $actions -ExtraKnownCoordinatesJson '["ops-known-coordinate"]') | Should -Be 9
        Get-PutCount | Should -Be 0
    }

    It 'gates the WHOLE set: one bad payload blocks the clean ones too' {
        $mixed = @'
[{"spec_folder":"003-clean","level":"feature","story_ordinal":null,"issue_key":"ADO-1",
  "reason":"label-match","overrode_key":null,"status":"adopt"},
 {"spec_folder":"acme.atlassian.net","level":"feature","story_ordinal":null,"issue_key":"ADO-2",
  "reason":"label-match","overrode_key":null,"status":"adopt"}]
'@
        $actions = Get-JiraAdoptionStampAction -BindingsJson $mixed -Repo 'acme/app'
        (Invoke-JiraApplyWriteSet -ActionsJson $actions) | Should -Be 9
        Get-PutCount | Should -Be 0
    }

    It 'applies the SHARED allowlist — adoption adds no weaker path (FR-053)' {
        $env:SPEC_KIT_JIRA_ALLOWLIST = '["docs.atlassian.net"]'
        $actions = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/docs.atlassian.net'
        (Invoke-JiraApplyWriteSet -ActionsJson $actions) | Should -Be 0
    }

    It 'cannot neutralise a DIFFERENT host through an allowlist entry (fail-closed)' {
        $env:SPEC_KIT_JIRA_ALLOWLIST = '["docs.atlassian.net"]'
        $actions = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/mirror-of-docs.atlassian.net'
        (Invoke-JiraApplyWriteSet -ActionsJson $actions) | Should -Be 9
    }
}
