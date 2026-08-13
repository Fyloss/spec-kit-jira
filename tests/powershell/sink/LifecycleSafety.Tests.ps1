# T069 [US6] — Jira-side lifecycle safety, PowerShell side. Mirror of
# tests/bash/sink/test_lifecycle_safety.bats (FR-035, FR-036, FR-037). Cross-port
# byte agreement is proven in bats; here we assert the fold semantics.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    $script:Doc = '{"stories":[{"local_id":"s1"}]}'
    $script:Actions = '[{"method":"PUT","url":"http://h/rest/api/3/issue/K-1","body":{"fields":{"summary":"New"}}}]'
    function Invoke-Lifecycle([string] $Lc) {
        return (Get-JiraLifecyclePlan -ContentActionsJson $script:Actions -NeutralDocJson $script:Doc -LifecycleContextJson $Lc | ConvertFrom-Json)
    }
}

Describe 'Get-JiraLifecyclePlan' {
    It 'withholds a post-scope regression by default, content still reconciles (FR-035)' {
        $lc = '{"order":{"story":["To Do","In Progress","Done"]},"base_url":"http://h","tickets":{"s1":{"key":"K-1","status":"Done","category":"post-scope","target":"To Do","transition_id":"11"}}}'
        $r = Invoke-Lifecycle $lc
        (@($r.actions | Where-Object { $_.method -eq 'PUT' }).Count) | Should -Be 1
        (@($r.actions | Where-Object { ([string]$_.url).EndsWith('/transitions') }).Count) | Should -Be 0
        $r.warnings[0] | Should -BeLike '*--on-drift=proceed*'
    }

    It 'pulls a regressed post-scope ticket backward with --on-drift=proceed (FR-035)' {
        $lc = '{"order":{"story":["To Do","In Progress","Done"]},"base_url":"http://h","on_drift":"proceed","tickets":{"s1":{"key":"K-1","status":"Done","category":"post-scope","target":"To Do","transition_id":"11"}}}'
        $r = Invoke-Lifecycle $lc
        (@($r.actions | Where-Object { ([string]$_.url).EndsWith('/transitions') }).Count) | Should -Be 1
    }

    It 'withholds a Flagged ticket transition, surfaces the flag, never mutates it (FR-036)' {
        $lc = '{"order":{"story":["To Do","In Progress","Done"]},"base_url":"http://h","tickets":{"s1":{"key":"K-1","status":"In Progress","category":"mapped","target":"Done","transition_id":"31","flagged":true}}}'
        $r = Invoke-Lifecycle $lc
        (@($r.actions | Where-Object { ([string]$_.url).EndsWith('/transitions') }).Count) | Should -Be 0
        $r.warnings[0] | Should -BeLike '*Flagged*'
        (@($r.actions | Where-Object { ([string]$_.url) -match 'flag' }).Count) | Should -Be 0
    }

    It 'never mutates human links; a transition past open blockers adds an info note (FR-037)' {
        $lc = '{"order":{"story":["To Do","In Progress","Done"]},"base_url":"http://h","tickets":{"s1":{"key":"K-1","status":"To Do","category":"mapped","target":"In Progress","transition_id":"21","blockers":["K-9","K-10"]}}}'
        $r = Invoke-Lifecycle $lc
        (@($r.actions | Where-Object { ([string]$_.url).EndsWith('/transitions') }).Count) | Should -Be 1
        (@($r.actions | Where-Object { $_.method -eq 'DELETE' -or ([string]$_.url) -match 'issueLink' }).Count) | Should -Be 0
        $r.notes[0] | Should -BeLike '*K-9*'
        $r.notes[0] | Should -BeLike '*K-10*'
    }

    It 'T106 -- an unclassified status withholds the move while content still mirrors (U1)' {
        $lc = '{"order":{"story":["To Do","In Progress","Done"]},"base_url":"http://h","tickets":{"s1":{"key":"K-1","status":"Weird Status","category":"unknown","target":"In Progress","transition_id":"21"}}}'
        $r = Invoke-Lifecycle $lc
        (@($r.actions | Where-Object { $_.method -eq 'PUT' }).Count) | Should -Be 1
        (@($r.actions | Where-Object { ([string]$_.url).EndsWith('/transitions') }).Count) | Should -Be 0
        $r.warnings[0] | Should -BeLike '*unclassified*'
    }

    It 'T108 -- a parent in a halted situation produces the SAME warning wording as a story (U8)' {
        $doc2 = '{"stories":[{"local_id":"s1"}]}'
        $actions2 = '[{"method":"PUT","url":"http://h/rest/api/3/issue/K-1","body":{"fields":{"summary":"New"}}}]'
        $parentAction2 = '{"method":"PUT","url":"http://h/rest/api/3/issue/K-1","body":{"fields":{"summary":"New"}}}'

        $lcStory = '{"order":{"story":["To Do","In Progress","Done"]},"base_url":"http://h","tickets":{"s1":{"key":"K-1","status":"Blocked","category":"halted","target":"In Progress","transition_id":"21"}}}'
        $lcParent = '{"order":{"specification":["To Do","In Progress","Done"]},"base_url":"http://h","parent_local_id":"s1","tickets":{"s1":{"key":"K-1","status":"Blocked","category":"halted","target":"In Progress","transition_id":"21","role":"specification"}}}'

        $storyOut = Get-JiraLifecyclePlan -ContentActionsJson $actions2 -NeutralDocJson $doc2 -LifecycleContextJson $lcStory | ConvertFrom-Json
        $parentOut = Get-JiraLifecyclePlan -ContentActionsJson '[]' -NeutralDocJson '{"stories":[]}' -LifecycleContextJson $lcParent -ParentActionJson $parentAction2 | ConvertFrom-Json

        $storyOut.warnings[0] | Should -Be $parentOut.warnings[0]
        $storyOut.warnings[0] | Should -BeLike '*halted*'
    }
}
