# 018, T071 [US2] — mirror of tests/bash/sink/test_suppressed_no_boundary.bats
# (FR-023, contract managed-description §4, summary-record §2).
#
# Clarified (spec.md, "Clarifications", session 2026-08-05): of the three
# causes FR-023 names, only `halted` actually suppresses content today —
# a flagged ticket or an unresolved-drift ticket keep reconciling their
# content, including the boundary, exactly as before this feature (FR-035,
# FR-036, feature 015/016) — only their transition is withheld.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    $script:Marker = Get-JiraManagedMarker
    $script:Doc = '{"stories":[{"local_id":"s1"}]}'
    $script:CurrentDesc = '{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"stale"}]}]}'

    $boundaryDesc = [ordered]@{
        type = 'doc'; version = 1
        content = @(
            @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) },
            @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'Story body.' }) }
        )
    }
    $boundaryDescJson = ConvertTo-Json -InputObject $boundaryDesc -Depth 100 -Compress
    $script:Actions = "[{`"method`":`"PUT`",`"url`":`"http://h/rest/api/3/issue/K-1`",`"body`":{`"fields`":{`"summary`":`"Story One`",`"description`":$boundaryDescJson}}}]"

    function Invoke-Lifecycle([string] $Lc) {
        return (Get-JiraLifecyclePlan -ContentActionsJson $script:Actions -NeutralDocJson $script:Doc -LifecycleContextJson $Lc | ConvertFrom-Json -Depth 100)
    }
}

Describe 'T071 (FR-023) — suppressed tickets and the boundary' {
    It 'a halted ticket acquires no boundary on this run' {
        $lc = "{`"order`":[`"To Do`",`"In Progress`",`"Done`"],`"base_url`":`"http://h`",`"tickets`":{`"s1`":{`"key`":`"K-1`",`"status`":`"Blocked`",`"category`":`"halted`",`"target`":`"In Progress`",`"transition_id`":`"11`",`"current`":{`"summary`":`"Story One`",`"description`":$script:CurrentDesc}}}}"
        $r = Invoke-Lifecycle $lc
        @($r.actions).Count | Should -Be 0
        $r.warnings[0] | Should -BeLike '*halted*'
    }

    It 'the SAME ticket acquires the boundary on the first run it is allowed to write' {
        $lc = "{`"order`":[`"To Do`",`"In Progress`",`"Done`"],`"base_url`":`"http://h`",`"tickets`":{`"s1`":{`"key`":`"K-1`",`"status`":`"In Progress`",`"category`":`"mapped`",`"target`":`"In Progress`",`"current`":{`"summary`":`"Story One`",`"description`":$script:CurrentDesc}}}}"
        $r = Invoke-Lifecycle $lc
        @($r.actions).Count | Should -Be 1
        (ConvertTo-Json -InputObject $r.actions[0].body.fields.description -Depth 100 -Compress) | Should -BeLike "*$script:Marker*"
    }

    It "a flagged ticket's boundary still reconciles; only its transition is withheld (FR-036 unaffected)" {
        $lc = "{`"order`":[`"To Do`",`"In Progress`",`"Done`"],`"base_url`":`"http://h`",`"tickets`":{`"s1`":{`"key`":`"K-1`",`"status`":`"In Progress`",`"category`":`"mapped`",`"target`":`"Done`",`"transition_id`":`"31`",`"flagged`":true,`"current`":{`"summary`":`"Story One`",`"description`":$script:CurrentDesc}}}}"
        $r = Invoke-Lifecycle $lc
        (@($r.actions | Where-Object { $_.method -eq 'PUT' }).Count) | Should -Be 1
        (ConvertTo-Json -InputObject $r.actions[0].body.fields.description -Depth 100 -Compress) | Should -BeLike "*$script:Marker*"
        (@($r.actions | Where-Object { ([string]$_.url).EndsWith('/transitions') }).Count) | Should -Be 0
    }

    It "an unresolved-drift ticket's boundary still reconciles; only its transition is withheld (FR-035 unaffected)" {
        $lc = "{`"order`":[`"To Do`",`"In Progress`",`"Done`"],`"base_url`":`"http://h`",`"tickets`":{`"s1`":{`"key`":`"K-1`",`"status`":`"Done`",`"category`":`"post-scope`",`"target`":`"To Do`",`"transition_id`":`"11`",`"current`":{`"summary`":`"Story One`",`"description`":$script:CurrentDesc}}}}"
        $r = Invoke-Lifecycle $lc
        (@($r.actions | Where-Object { $_.method -eq 'PUT' }).Count) | Should -Be 1
        (ConvertTo-Json -InputObject $r.actions[0].body.fields.description -Depth 100 -Compress) | Should -BeLike "*$script:Marker*"
        (@($r.actions | Where-Object { ([string]$_.url).EndsWith('/transitions') }).Count) | Should -Be 0
        $r.warnings[0] | Should -BeLike '*--on-drift=proceed*'
    }
}
