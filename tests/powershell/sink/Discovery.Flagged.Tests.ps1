# Flagged/impediment field discovery, PowerShell side (FR-036 lifecycle safety
# input). Mirror of tests/bash/sink/test_discovery_flagged.bats: the English name
# is only a first-chance match — a localized/renamed site resolves by SHAPE, and
# only an unambiguous single shape candidate is accepted.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Sink = Join-Path $Root '.specify/extensions/jira/scripts/powershell/sink/jira'
    Import-Module (Join-Path $Sink 'Discovery.psm1') -Force

    $script:English = '[{"fieldId":"customfield_20044","name":"Impediment","schema":{"type":"array","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"}},{"fieldId":"customfield_20011","name":"T-Shirt Estimate","schema":{"type":"number"}}]'
    $script:Localized = '[{"fieldId":"customfield_40077","name":"Kennzeichnung","schema":{"type":"array","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"}},{"fieldId":"customfield_30044","name":"Aufwand","schema":{"type":"number"}}]'
    $script:Ambiguous = '[{"fieldId":"customfield_1","name":"Kennzeichnung","schema":{"type":"array","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"}},{"fieldId":"customfield_2","name":"Kategorien","schema":{"type":"array","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"}}]'
}

Describe 'Get-JiraDiscoveryFlaggedField' {
    It 'resolves by NAME on an English site' {
        $f = Get-JiraDiscoveryFlaggedField -FieldsJson $script:English
        $f.id | Should -Be 'customfield_20044'
    }

    It 'resolves by SHAPE on a localized site — FR-036 safety stays active' {
        $f = Get-JiraDiscoveryFlaggedField -FieldsJson $script:Localized
        $f.id | Should -Be 'customfield_40077'
        $f.logical_name | Should -Be 'Kennzeichnung'
    }

    It 'resolves an ambiguous shape with no name match to null (precision over recall)' {
        Get-JiraDiscoveryFlaggedField -FieldsJson $script:Ambiguous | Should -Be $null
    }

    It 'resolves to null when no candidate exists at all' {
        Get-JiraDiscoveryFlaggedField -FieldsJson '[{"fieldId":"summary","name":"Summary","schema":{"type":"string"}}]' | Should -Be $null
    }
}
