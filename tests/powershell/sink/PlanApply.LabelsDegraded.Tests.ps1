# T024 [US2] — mirror of tests/bash/sink/test_plan_apply_labels_degraded.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/PlanApply.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Ticket.psm1') -Force

    function Get-JiraTestDocOneStory([string] $Slug) {
        # `epic` is present (Get-JiraPlanWriteSetParent always renders it,
        # unlike the bash port which tolerates its absence) but carries no
        # parent_type_id in these tests' ctx, so no parent action results.
        return (ConvertTo-Json -Depth 20 -Compress -InputObject ([ordered]@{
            spec_ref = [ordered]@{ spec_slug = $Slug }
            routing  = [ordered]@{ project_key = 'COMP' }
            epic     = [ordered]@{ local_id = 'E1'; title = 'Epic'; description = [ordered]@{ blocks = @() } }
            stories  = @([ordered]@{ local_id = 'S1'; title = 'New story'; priority_logical = $null; estimation = $null })
        }))
    }
}

Describe 'Get-JiraPlanWriteSet -- provenance label degradation (017, contract Section4)' {
    It 'T7 -- defaultable_fields_by_type records the type WITHOUT a labels entry: omitted, one warning, ticket still mirrored' {
        $doc = Get-JiraTestDocOneStory -Slug '001-test-page'
        $ctx = '{
            "base_url":"https://example.atlassian.net","story_type_id":"10102",
            "issue_types":[{"logical_name":"Story","id":"10102"}],
            "defaultable_fields_by_type": {"10102": [
              {"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]}
            ]}
        }'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $out.stories[0].method | Should -Be 'POST'
        ($out.stories[0].body.fields.PSObject.Properties.Name -contains 'labels') | Should -BeFalse
        @($out.warnings).Count | Should -Be 1
        $out.warnings[0] | Should -Match 'speckit-001-test-page'
        $out.warnings[0] | Should -Match 'could not be applied to Story in COMP'
    }

    It 'T7 -- no defaultable_fields_by_type entry recorded for the type AT ALL: the label sends' {
        $doc = Get-JiraTestDocOneStory -Slug '001-test-page'
        $ctx = '{"base_url":"https://example.atlassian.net","story_type_id":"10102","issue_types":[{"logical_name":"Story","id":"10102"}]}'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        ($out.stories[0].body.fields.labels -join ',') | Should -Be 'speckit-001-test-page'
        ($out.PSObject.Properties.Name -contains 'warnings') | Should -BeFalse
    }

    It 'T7 -- defaultable_fields_by_type records the type WITH a labels entry present: the label sends' {
        $doc = Get-JiraTestDocOneStory -Slug '001-test-page'
        $ctx = '{
            "base_url":"https://example.atlassian.net","story_type_id":"10102",
            "issue_types":[{"logical_name":"Story","id":"10102"}],
            "defaultable_fields_by_type": {"10102": [
              {"logical_name":"Labels","field_id":"labels","schema_type":"array","required":false,"defaultable":false,"allowed_values":[]}
            ]}
        }'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        ($out.stories[0].body.fields.labels -join ',') | Should -Be 'speckit-001-test-page'
        ($out.PSObject.Properties.Name -contains 'warnings') | Should -BeFalse
    }

    It 'T13 -- a slug pushing speckit-<slug> past JIRA_LABEL_MAX_LENGTH: absent from every payload, one warning, nothing truncated' {
        $longSlug = '001-' + ('a' * 252)
        $slugLen = $longSlug.Length
        $docObj = [ordered]@{
            spec_ref = [ordered]@{ spec_slug = $longSlug }
            routing  = [ordered]@{ project_key = 'COMP' }
            epic     = [ordered]@{ local_id = 'E1'; title = 'New epic'; description = [ordered]@{ blocks = @(@{ type = 'paragraph'; text = 'Overview.' }) } }
            stories  = @([ordered]@{ local_id = 'S1'; title = 'New story'; priority_logical = $null; estimation = $null })
        }
        $doc = ConvertTo-Json -Depth 20 -Compress -InputObject $docObj
        $ctx = '{
            "base_url":"https://example.atlassian.net","story_type_id":"10102","parent_type_id":"10101",
            "issue_types":[{"logical_name":"Story","id":"10102"},{"logical_name":"Epic","id":"10101"}]
        }'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        ($out.stories[0].body.fields.PSObject.Properties.Name -contains 'labels') | Should -BeFalse
        ($out.parent.body.fields.PSObject.Properties.Name -contains 'labels') | Should -BeFalse
        # One warning per TYPE this run touches (story and parent each decide
        # independently) -- both name the same over-long slug.
        @($out.warnings).Count | Should -Be 2
        $out.warnings[0] | Should -Match ([regex]::Escape("`"$longSlug`""))
        $out.warnings[0] | Should -Match "$($slugLen + 8) characters"
        $out.warnings[0] | Should -Match '255-character limit'
    }

    It 'T13 -- a slug within the limit is unaffected' {
        $doc = Get-JiraTestDocOneStory -Slug '001-a-normal-length-slug'
        $ctx = '{"base_url":"https://example.atlassian.net","story_type_id":"10102","issue_types":[{"logical_name":"Story","id":"10102"}]}'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        ($out.stories[0].body.fields.labels -join ',') | Should -Be 'speckit-001-a-normal-length-slug'
        ($out.PSObject.Properties.Name -contains 'warnings') | Should -BeFalse
    }

    It 'a ctx with no issue_types key at all does not throw (a binding that predates it) -- the label still sends' {
        $doc = Get-JiraTestDocOneStory -Slug '001-test-page'
        $ctx = '{"base_url":"https://example.atlassian.net","story_type_id":"10102"}'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        ($out.stories[0].body.fields.labels -join ',') | Should -Be 'speckit-001-test-page'
    }
}
