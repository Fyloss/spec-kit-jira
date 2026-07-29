# T040 [US4] — Per-project priority availability. Pester twin of
# tests/bash/sink/test_discovery_priorities.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Discovery.psm1') -Force
    $Fix = Join-Path $Root 'tests/conformance/mock-jira/fixtures'
    $script:Catalogue = @(
        [pscustomobject]@{ id = '1'; name = 'Critical' },
        [pscustomobject]@{ id = '2'; name = 'High' },
        [pscustomobject]@{ id = '3'; name = 'Medium' },
        [pscustomobject]@{ id = '4'; name = 'Low' }
    )

    function Get-FieldsFrom([string]$Name) {
        return @((Get-Content -Raw -LiteralPath (Join-Path $Fix "$Name.json") | ConvertFrom-Json).fields)
    }
}

Describe 'Per-project priority availability (US4)' {
    It 'branch 1 — priority field absent from create metadata yields empty' {
        $fields = Get-FieldsFrom 'createmeta-fields-team'
        $result = Get-JiraDiscoveryPrioritiesForProject -Fields $fields -Catalogue $script:Catalogue
        @($result).Count | Should -Be 0
    }

    It 'branch 2 — priority field WITH allowedValues yields only those, resolved against the catalogue' {
        $fields = Get-FieldsFrom 'createmeta-fields-company-allowed'
        $result = @(Get-JiraDiscoveryPrioritiesForProject -Fields $fields -Catalogue $script:Catalogue | Sort-Object id)
        $result.Count | Should -Be 2
        $result[0].logical_name | Should -Be 'Critical'
        $result[0].id | Should -Be '1'
        $result[1].logical_name | Should -Be 'Medium'
        $result[1].id | Should -Be '3'
    }

    It "branch 3 — priority field WITHOUT allowedValues yields the site-wide catalogue (today's behaviour)" {
        $fields = Get-FieldsFrom 'createmeta-fields-company'
        $result = @(Get-JiraDiscoveryPrioritiesForProject -Fields $fields -Catalogue $script:Catalogue | Sort-Object id)
        $result.Count | Should -Be 4
        ($result | ForEach-Object { $_.logical_name }) -join ',' | Should -Be 'Critical,High,Medium,Low'
    }
}
