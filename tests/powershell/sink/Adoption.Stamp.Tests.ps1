# T042 [US1] — The adoption stamp action set, PowerShell side. Mirror of
# tests/bash/sink/test_adoption_stamp.bats (003 FR-007, FR-027, research §7).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Adoption.psm1') -Force
    # Identity is imported LAST so its exports are not re-scoped by the nested
    # -Force import inside Adoption.psm1 (the nested-import re-scope trap).
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Identity.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force
    $env:SPEC_KIT_JIRA_BASE_URL = 'http://jira.invalid'
    $script:Bindings = @'
[{"spec_folder":"003-a","level":"feature","story_ordinal":null,"issue_key":"ADO-1",
  "reason":"label-match","overrode_key":null,"status":"adopt"},
 {"spec_folder":"003-a","level":"story","story_ordinal":1,"issue_key":"ADO-2",
  "reason":"label-match","overrode_key":null,"status":"adopt"}]
'@
}

AfterAll {
    Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
}

Describe 'Get-JiraAdoptionStampAction' {
    It 'emits one identity-property PUT per adopted binding and nothing else' {
        $a = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/app' | ConvertFrom-Json
        @($a).Count | Should -Be 2
        @($a | Where-Object { $_.method -ne 'PUT' }).Count | Should -Be 0
        @($a)[0].url | Should -Be 'http://jira.invalid/rest/api/3/issue/ADO-1/properties/spec-kit-jira'
        @($a)[1].url | Should -Be 'http://jira.invalid/rest/api/3/issue/ADO-2/properties/spec-kit-jira'
    }

    It 'emits no create, transition, comment, link, relabel or content write (FR-007)' {
        $json = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/app'
        $a = $json | ConvertFrom-Json
        @($a | Where-Object { -not $_.url.EndsWith('/properties/spec-kit-jira') }).Count | Should -Be 0
        @($a | Where-Object { $_.body.PSObject.Properties.Name -contains 'fields' }).Count | Should -Be 0
        $json | Should -Not -BeLike '*transitions*'
        $json | Should -Not -BeLike '*comment*'
    }

    It 'carries origin human and the spec ref, with no new marker field (FR-016)' {
        $a = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/app' | ConvertFrom-Json
        @($a)[0].body.origin | Should -Be 'human'
        @($a)[0].body.repo | Should -Be 'acme/app'
        @($a)[0].body.spec_slug | Should -Be '003-a'
        ((@($a)[0].body.PSObject.Properties.Name) -join ',') | Should -Be 'origin,repo,spec_slug'
    }

    It 'builds the payload with the same marker builder the mention path uses' {
        $json = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/app'
        $expected = Get-JiraIdentityMarker -SpecRefJson '{"repo":"acme/app","spec_slug":"003-a"}' -Origin 'human'
        $actual = ConvertTo-JiraJsonValue ((@($json | ConvertFrom-Json))[0].body)
        $actual | Should -Be $expected
    }

    It 'emits NO action for an already-adopted binding (FR-027)' {
        $b = '[{"spec_folder":"003-a","level":"feature","story_ordinal":null,"issue_key":"ADO-1","reason":"label-match","overrode_key":null,"status":"already-adopted"}]'
        Get-JiraAdoptionStampAction -BindingsJson $b -Repo 'acme/app' | Should -Be '[]'
    }

    It 'follows the binding order so the plan and the run agree' {
        $a = Get-JiraAdoptionStampAction -BindingsJson $Bindings -Repo 'acme/app' | ConvertFrom-Json
        (@($a | ForEach-Object { $_.url.Split('/')[7] }) -join ',') | Should -Be 'ADO-1,ADO-2'
    }

    It 'emits no actions for no bindings' {
        Get-JiraAdoptionStampAction -BindingsJson '[]' -Repo 'acme/app' | Should -Be '[]'
    }
}
