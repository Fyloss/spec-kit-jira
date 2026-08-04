# T057/T060 [Phase 5, US2] — plan_writes returns {parent, stories}, PowerShell
# side. Mirror of tests/bash/sink/test_plan_apply_parent.bats. Cross-port
# byte-parity is proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    # -Global, and LAST: PlanApply.psm1 nested-imports Output.psm1 itself
    # (without -Global), which loads it into PlanApply.psm1's own module
    # scope rather than the session — see StoryMarker's note in
    # Hierarchy.Tests.ps1 for the general rule.
    Import-Module (Join-Path $SinkDir '../../lib/Output.psm1') -Force -Global

    $script:Doc = @'
{
  "routing": {"project_key":"COMP"},
  "epic": {"title":"The Epic Title", "local_id":"3f2a91c04b7e6d18",
           "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
           "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},
  "stories": [
    {"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","spans":[{"text":"need","marks":[]}]}]},
     "priority_logical":"P2"}
  ]
}
'@

    $script:CtxNewParent = @'
{
  "base_url":"https://mock",
  "story_type_id":"10002",
  "parent_type_id":"10101",
  "parent_local_id":"3f2a91c04b7e6d18",
  "priority_ids":{"P1":"1","P2":"2","P3":"3"},
  "tickets":{}
}
'@

    # 018, T027: the parent now carries the boundary too, so a fixture meant
    # to be "unchanged" must already sit inside it — otherwise the first
    # touch of a legacy (marker-less) description also migrates, which is
    # its own, separately-tested behaviour (contract §3).
    $script:CtxBoundUnchanged = @'
{
  "base_url":"https://mock",
  "story_type_id":"10002",
  "parent_type_id":"10101",
  "parent_key":"COMP-412",
  "parent_current":{"summary":"The Epic Title","description":{"type":"doc","version":1,"content":[
    {"type":"paragraph","content":[{"type":"text","text":"Synced from spec-kit — do not edit below this line","marks":[{"type":"strong"}]}]},
    {"type":"paragraph","content":[{"type":"text","text":"Overview."}]}
  ]}},
  "priority_ids":{"P1":"1","P2":"2","P3":"3"},
  "tickets":{}
}
'@

    $script:CtxBoundChanged = @'
{
  "base_url":"https://mock",
  "story_type_id":"10002",
  "parent_type_id":"10101",
  "parent_key":"COMP-412",
  "parent_current":{"summary":"An old title","description":{"type":"doc","version":1,"content":[]}},
  "priority_ids":{"P1":"1","P2":"2","P3":"3"},
  "tickets":{}
}
'@
}

Describe 'Get-JiraPlanWriteSet — the return shape (data-model.md §6)' {
    It 'returns an object with parent and stories properties' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxNewParent | ConvertFrom-Json
        ($r.PSObject.Properties.Name -contains 'parent') | Should -BeTrue
        ($r.PSObject.Properties.Name -contains 'stories') | Should -BeTrue
    }

    It 'a specification with no recognised parent plans a POST for the parent, carrying its local_id and role' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxNewParent | ConvertFrom-Json
        $r.parent.method | Should -Be 'POST'
        $r.parent.url | Should -Be 'https://mock/rest/api/3/issue'
        $r.parent.body.fields.issuetype.id | Should -Be '10101'
        $r.parent.body.fields.summary | Should -Be 'The Epic Title'
        $r.parent.local_id | Should -Be '3f2a91c04b7e6d18'
        $r.parent.role | Should -Be 'parent'
    }

    It 'every story creation carries the parent-key placeholder, resolved at apply time' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxNewParent | ConvertFrom-Json
        $r.stories[0].body.fields.parent.key | Should -Be '<resolved at apply time>'
    }

    It 'story actions still carry role:story and their own local_id' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxNewParent | ConvertFrom-Json
        $r.stories[0].role | Should -Be 'story'
        $r.stories[0].local_id | Should -Be 's1'
    }

    It 'a recognised parent with unchanged bridge-owned content plans parent: null' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxBoundUnchanged | ConvertFrom-Json
        $r.parent | Should -Be $null
    }

    It 'a recognised parent whose content differs plans a PUT, no local_id (never re-created)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxBoundChanged | ConvertFrom-Json
        $r.parent.method | Should -Be 'PUT'
        $r.parent.url | Should -Be 'https://mock/rest/api/3/issue/COMP-412'
        $r.parent.body.fields.summary | Should -Be 'The Epic Title'
        ($r.parent.PSObject.Properties.Name -contains 'local_id') | Should -BeFalse
    }

    It 'cardinality invariant (FR-004): parent is never a list, across every configuration' {
        foreach ($ctx in @($script:CtxNewParent, $script:CtxBoundUnchanged, $script:CtxBoundChanged)) {
            $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json
            ($null -eq $r.parent -or $r.parent -is [System.Management.Automation.PSCustomObject]) | Should -BeTrue
        }
    }
}

Describe 'Get-JiraPlanWriteSet — T060 zero churn + human-managed-section comparison' {
    It 'an unchanged parent is not written to (parent: null)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxBoundUnchanged | ConvertFrom-Json
        $r.parent | Should -Be $null
    }

    It 'a human-edited parent description is compared on its managed section alone' {
        $marker = 'Synced from spec-kit — do not edit below this line'
        $humanCurrent = @{
            summary     = 'The Epic Title'
            description = @{
                type    = 'doc'; version = 1
                content = @(
                    @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'A human wrote this prose first.' }) },
                    @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $marker; marks = @(@{ type = 'strong' }) }) },
                    @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'Overview.' }) }
                )
            }
        }
        $ctx = $script:CtxBoundUnchanged | ConvertFrom-Json
        $ctx | Add-Member -MemberType NoteProperty -Name 'parent_current' -Value $humanCurrent -Force
        $ctx | Add-Member -MemberType NoteProperty -Name 'parent_origin' -Value 'human' -Force
        $ctxJson = ConvertTo-JiraJsonValue $ctx
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctxJson | ConvertFrom-Json
        $r.parent | Should -Be $null
    }
}

Describe 'Get-JiraPlanWriteSet — T090 the plan section is replaced in place' {
    BeforeAll {
        $script:DocWithPlan = @'
{
  "routing": {"project_key":"COMP"},
  "epic": {"title":"The Epic Title", "local_id":"3f2a91c04b7e6d18",
           "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
           "description":{"blocks":[
             {"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]},
             {"type":"heading","level":3,"spans":[{"text":"Implementation Plan","marks":[]}]},
             {"type":"paragraph","spans":[{"text":"The original plan summary.","marks":[]}]}
           ]}},
  "stories": []
}
'@
        $script:DocWithChangedPlan = @'
{
  "routing": {"project_key":"COMP"},
  "epic": {"title":"The Epic Title", "local_id":"3f2a91c04b7e6d18",
           "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
           "description":{"blocks":[
             {"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]},
             {"type":"heading","level":3,"spans":[{"text":"Implementation Plan","marks":[]}]},
             {"type":"paragraph","spans":[{"text":"A revised plan summary.","marks":[]}]}
           ]}},
  "stories": []
}
'@
        $script:CurrentWithPlan = '{"summary":"The Epic Title","description":{"type":"doc","version":1,"content":[' +
        '{"type":"paragraph","content":[{"type":"text","text":"Synced from spec-kit — do not edit below this line","marks":[{"type":"strong"}]}]},' +
        '{"type":"paragraph","content":[{"type":"text","text":"Overview."}]},' +
        '{"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"Implementation Plan"}]},' +
        '{"type":"paragraph","content":[{"type":"text","text":"The original plan summary."}]}' +
        ']}}'
    }

    It 'a new parent''s creation body carries the Implementation Plan section' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithPlan -PlanContextJson $script:CtxNewParent | ConvertFrom-Json
        $body = ConvertTo-JiraJsonValue $r.parent.body.fields.description
        $body | Should -Match 'Implementation Plan'
        $body | Should -Match 'The original plan summary\.'
    }

    It 'the Implementation Plan heading appears exactly once' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithPlan -PlanContextJson $script:CtxNewParent | ConvertFrom-Json
        $body = ConvertTo-JiraJsonValue $r.parent.body.fields.description
        ([regex]::Matches($body, 'Implementation Plan')).Count | Should -Be 1
    }

    It 'an unchanged plan issues no write to the parent' {
        $ctx = $script:CtxNewParent | ConvertFrom-Json
        $ctx | Add-Member -MemberType NoteProperty -Name 'parent_key' -Value 'COMP-412' -Force
        $ctx | Add-Member -MemberType NoteProperty -Name 'parent_current' -Value ($script:CurrentWithPlan | ConvertFrom-Json) -Force
        $ctx.PSObject.Properties.Remove('parent_local_id')
        $ctxJson = ConvertTo-JiraJsonValue $ctx
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithPlan -PlanContextJson $ctxJson | ConvertFrom-Json
        $r.parent | Should -Be $null
    }

    It 'a changed plan replaces the section in place — the old summary is gone, not appended alongside the new one' {
        $ctx = $script:CtxNewParent | ConvertFrom-Json
        $ctx | Add-Member -MemberType NoteProperty -Name 'parent_key' -Value 'COMP-412' -Force
        $ctx | Add-Member -MemberType NoteProperty -Name 'parent_current' -Value ($script:CurrentWithPlan | ConvertFrom-Json) -Force
        $ctx.PSObject.Properties.Remove('parent_local_id')
        $ctxJson = ConvertTo-JiraJsonValue $ctx
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithChangedPlan -PlanContextJson $ctxJson | ConvertFrom-Json
        $r.parent.method | Should -Be 'PUT'
        $body = ConvertTo-JiraJsonValue $r.parent.body.fields.description
        $body | Should -Match 'A revised plan summary\.'
        $body | Should -Not -Match 'The original plan summary\.'
        ([regex]::Matches($body, 'Implementation Plan')).Count | Should -Be 1
    }
}
