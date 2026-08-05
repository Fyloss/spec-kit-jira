# T012 [US1] — plan_writes declares the resolved project. Pester twin of
# tests/bash/sink/test_plan_apply_project.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/PlanApply.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Ticket.psm1') -Force

    function New-Doc {
        param([string] $Project)
        $doc = [ordered]@{
            schema_version = '1.0'
            spec_ref       = [ordered]@{ repo = 'acme/app'; spec_slug = '001-x'; folder = '/tmp/001-x' }
            routing        = [ordered]@{ project_key = $Project }
            epic           = [ordered]@{ local_id = '3f2a91c04b7e6d18'; title = 'E'; description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'e'; marks = @() }) }) } }
            stories        = @([ordered]@{ local_id = 's1'; title = 'Story One'; priority_logical = 'P2'; description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'd'; marks = @() }) }) } })
        }
        return ($doc | ConvertTo-Json -Compress -Depth 10)
    }
}

Describe 'plan_writes declares the resolved project (US1)' {
    It 'every POST body carries a non-empty fields.project.key equal to routing.project_key (FR-022, FR-023)' {
        $doc = New-Doc -Project 'COMP'
        $ctx = '{"base_url":"https://mock","story_type_id":"10004","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18"}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json
        $r.stories[0].method | Should -Be 'POST'
        $r.stories[0].body.fields.project.key | Should -Be 'COMP'
    }

    It 'assembly refuses to emit a creation with an empty project (FR-024)' {
        $doc = New-Doc -Project ''
        $ctx = '{"base_url":"https://mock","story_type_id":"10004","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18"}'
        { Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx -ErrorAction Stop } | Should -Throw
    }

    It 'assembly refuses to emit a creation with an empty issue type (FR-024)' {
        $doc = New-Doc -Project 'COMP'
        $ctx = '{"base_url":"https://mock","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18"}'
        { Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx -ErrorAction Stop } | Should -Throw
    }

    It 'an UPDATE is unaffected by the assembly guard (no issuetype required)' {
        $doc = New-Doc -Project 'COMP'
        $ctx = '{"base_url":"https://mock","tickets":{"s1":"COMP-9"},"parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18"}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json
        $r.stories[0].method | Should -Be 'PUT'
    }

    It 'the base fields come from Get-JiraCreateFieldsBase, unchanged (FR-025, SC-010)' {
        $doc = New-Doc -Project 'COMP'
        $ctx = '{"base_url":"https://mock","story_type_id":"10004","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18"}'
        $base = Get-JiraCreateFieldsBase -ProjectKey 'COMP' -Summary 'Story One' -IssueTypeId '10004' | ConvertFrom-Json
        $r = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json
        $r.stories[0].body.fields.project | ConvertTo-Json -Compress | Should -Be ($base.project | ConvertTo-Json -Compress)
        $r.stories[0].body.fields.issuetype | ConvertTo-Json -Compress | Should -Be ($base.issuetype | ConvertTo-Json -Compress)
        $r.stories[0].body.fields.summary | Should -Be $base.summary
    }
}
