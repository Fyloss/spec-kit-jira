# T082/T083/T086/T087 [US5] — mirror of tests/bash/sink/test_plan_lifecycle_tasks.bats.
# Get-JiraTaskLifecyclePlan is the task tier's own completion pass (contract
# §6): a binary done/not-done model, never routed through Get-JiraLifecyclePlan.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    function Invoke-TaskLifecycle([string] $Cc, [string] $Content = '[]') {
        return (Get-JiraTaskLifecyclePlan -ContentActionsJson $Content -CompletionContextJson $Cc | ConvertFrom-Json)
    }
}

Describe 'Get-JiraTaskLifecyclePlan' {
    It 'plans a transition for a newly checked task with exactly one done-category destination (FR-029)' {
        $cc = '{"base_url":"http://h","tasks":{"t1":{"key":"K-2","forward":{"transition_id":"31","candidates":[{"id":"31","name":"Terminé"}],"withheld_field":null}}}}'
        $r = Invoke-TaskLifecycle $cc
        @($r.actions).Count | Should -Be 1
        $r.actions[0].url | Should -Be 'http://h/rest/api/3/issue/K-2/transitions'
        $r.actions[0].body.transition.id | Should -Be '31'
    }

    It 'plans nothing and issues no read for a sub-task already done-category (FR-031)' {
        $cc = '{"base_url":"http://h","tasks":{}}'
        $r = Invoke-TaskLifecycle $cc
        @($r.actions).Count | Should -Be 0
        @($r.warnings).Count | Should -Be 0
    }

    It 'keeps both the content PUT and the transition POST for a task checked and reworded in the same run' {
        $content = '[{"method":"PUT","url":"http://h/rest/api/3/issue/K-2","body":{"fields":{"summary":"New"}},"role":"task"}]'
        $cc = '{"base_url":"http://h","tasks":{"t1":{"key":"K-2","forward":{"transition_id":"31","candidates":[{"id":"31","name":"Done"}],"withheld_field":null}}}}'
        $r = Invoke-TaskLifecycle $cc $content
        @($r.actions | Where-Object { $_.method -eq 'PUT' }).Count | Should -Be 1
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/transitions') }).Count | Should -Be 1
    }

    It 'plans no transition and names the issue when there is no done-category destination (FR-030)' {
        $cc = '{"base_url":"http://h","tasks":{"t1":{"key":"K-3","forward":{"transition_id":null,"candidates":[],"withheld_field":null}}}}'
        $r = Invoke-TaskLifecycle $cc
        @($r.actions).Count | Should -Be 0
        @($r.warnings).Count | Should -Be 1
        $r.warnings[0] | Should -BeLike '*K-3*'
    }

    It 'plans no transition and names the candidates when two or more are done-category' {
        $cc = '{"base_url":"http://h","tasks":{"t1":{"key":"K-4","forward":{"transition_id":null,"candidates":[{"id":"31","name":"Fait"},{"id":"51","name":"Annulé"}],"withheld_field":null}}}}'
        $r = Invoke-TaskLifecycle $cc
        @($r.actions).Count | Should -Be 0
        $r.warnings[0] | Should -BeLike '*K-4*'
        $r.warnings[0] | Should -BeLike '*Fait*'
        $r.warnings[0] | Should -BeLike '*Annulé*'
    }

    It 'withholds and names a transition gated behind a required field, no recorded default sent (FR-041)' {
        $cc = '{"base_url":"http://h","tasks":{"t1":{"key":"K-5","forward":{"transition_id":null,"candidates":[{"id":"41","name":"Fermer"}],"withheld_field":{"logical_name":"Résolution","field_id":"resolution"}}}}}'
        $r = Invoke-TaskLifecycle $cc
        @($r.actions).Count | Should -Be 0
        $r.warnings[0] | Should -BeLike '*K-5*'
        $r.warnings[0] | Should -BeLike '*Résolution*'
        @($r.actions | Where-Object { $_.url -eq 'http://h/rest/api/3/issue/K-5/transitions' }).Count | Should -Be 0
    }

    It 'reports a sub-task completed in Jira while its task is unchecked, by key (FR-032)' {
        $cc = '{"base_url":"http://h","tasks":{"t1":{"key":"K-6","already_done_diverged":true}}}'
        $r = Invoke-TaskLifecycle $cc
        @($r.actions).Count | Should -Be 0
        @($r.warnings).Count | Should -Be 1
        $r.warnings[0] | Should -BeLike '*K-6*'
    }

    It 'moves the sub-task back under operator authorisation and still reports the divergence (FR-032)' {
        $cc = '{"base_url":"http://h","tasks":{"t1":{"key":"K-7","already_done_diverged":true,"backward":{"transition_id":"21","candidates":[{"id":"21","name":"En cours"}],"withheld_field":null}}}}'
        $r = Invoke-TaskLifecycle $cc
        @($r.actions).Count | Should -Be 1
        $r.actions[0].body.transition.id | Should -Be '21'
        @($r.warnings).Count | Should -Be 1
        $r.warnings[0] | Should -BeLike '*K-7*'
    }

    It 'never moves the sub-task back without authorisation, only reports the divergence' {
        $cc = '{"base_url":"http://h","tasks":{"t1":{"key":"K-8","already_done_diverged":true,"backward":null}}}'
        $r = Invoke-TaskLifecycle $cc
        @($r.actions).Count | Should -Be 0
        @($r.warnings).Count | Should -Be 1
    }
}
