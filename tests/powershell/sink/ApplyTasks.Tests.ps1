# T033/T034 [US1] — Invoke-JiraApplyWriteSetWithRecognition, the task tier.
# Mirror of tests/bash/sink/test_apply_tasks.bats. Cross-port parity is
# proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:JIRA_MAX_ATTEMPTS = '1'
    $script:SpecRef = '{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
    $script:DefaultConfig = Join-Path $Mock 'configs/default.json'
}

Describe 'Invoke-JiraApplyWriteSetWithRecognition — the task tier' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'order within one run: epic, then stories, then tasks' {
        $script:M = Start-JiraMock -ConfigPath $script:DefaultConfig
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $plan = "{`"parent`":{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"The Epic`"}},`"local_id`":`"aaaaaaaaaaaaaaaa`",`"role`":`"parent`"},`"stories`":[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"A story`",`"parent`":{`"key`":`"<resolved at apply time>`"}}},`"local_id`":`"1111111111111111`",`"role`":`"story`"}]}"
        $tasks = "[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"A task`",`"parent`":{`"key`":`"<resolved at apply time>`"}}},`"local_id`":`"2222222222222222`",`"parent_local_id`":`"1111111111111111`",`"role`":`"task`"}]"
        $specFile = Join-Path $TestDrive 'spec.md'
        $tasksFile = Join-Path $TestDrive 'tasks.md'
        Set-Content -NoNewline -Path $specFile -Value "# Title`n"
        Set-Content -NoNewline -Path $tasksFile -Value "- [ ] T001 A task`n"
        $rc = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $script:SpecRef -SpecFile $specFile -TasksActionsJson $tasks -TasksFile $tasksFile
        $rc | Should -Be 0
        $calls = (Get-JiraMockCallLog -Mock $script:M) -split "`n" | Where-Object { $_ -eq 'POST /rest/api/3/issue' }
        @($calls).Count | Should -Be 3
    }

    It "a task's parent key resolves from the story created in the SAME run" {
        $script:M = Start-JiraMock -ConfigPath $script:DefaultConfig
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $plan = "{`"parent`":null,`"stories`":[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"A story`"}},`"local_id`":`"1111111111111111`",`"role`":`"story`"}]}"
        $tasks = "[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"A task`",`"parent`":{`"key`":`"<resolved at apply time>`"}}},`"local_id`":`"2222222222222222`",`"parent_local_id`":`"1111111111111111`",`"role`":`"task`"}]"
        $specFile = Join-Path $TestDrive 'spec.md'
        $tasksFile = Join-Path $TestDrive 'tasks.md'
        Set-Content -NoNewline -Path $specFile -Value "# Title`n"
        Set-Content -NoNewline -Path $tasksFile -Value "- [ ] T001 A task`n"
        $rc = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $script:SpecRef -SpecFile $specFile -TasksActionsJson $tasks -TasksFile $tasksFile
        $rc | Should -Be 0
        (Get-JiraMockIssueField -Mock $script:M -Key 'COMP-2' -Path 'fields.parent.key') | Should -Be 'COMP-1'
    }

    It 'a task attributed to a story with no key anywhere is skipped, not blocking others' {
        $script:M = Start-JiraMock -ConfigPath $script:DefaultConfig
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $plan = '{"parent":null,"stories":[]}'
        $tasks = "[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"Orphaned`",`"parent`":{`"key`":`"<resolved at apply time>`"}}},`"local_id`":`"3333333333333333`",`"parent_local_id`":`"deadbeefdeadbeef`",`"role`":`"task`"},{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"Real`",`"parent`":{`"key`":`"<resolved at apply time>`"}}},`"local_id`":`"4444444444444444`",`"parent_local_id`":`"1111111111111111`",`"role`":`"task`"}]"
        $knownKeys = '{"1111111111111111":"COMP-9"}'
        $specFile = Join-Path $TestDrive 'spec.md'
        $tasksFile = Join-Path $TestDrive 'tasks.md'
        Set-Content -NoNewline -Path $specFile -Value "# Title`n"
        Set-Content -NoNewline -Path $tasksFile -Value "- [ ] T001 A`n- [ ] T002 B`n"
        $rc = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $script:SpecRef -SpecFile $specFile -TasksActionsJson $tasks -TasksFile $tasksFile -KnownStoryKeysJson $knownKeys
        $rc | Should -Be 0
        $calls = (Get-JiraMockCallLog -Mock $script:M) -split "`n" | Where-Object { $_ -eq 'POST /rest/api/3/issue' }
        @($calls).Count | Should -Be 1
    }

    It "a created sub-task's key is recorded into TasksFile immediately" {
        $script:M = Start-JiraMock -ConfigPath $script:DefaultConfig
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $plan = '{"parent":null,"stories":[]}'
        $tasks = "[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"A task`"}},`"local_id`":`"5555555555555555`",`"role`":`"task`"}]"
        $specFile = Join-Path $TestDrive 'spec.md'
        $tasksFile = Join-Path $TestDrive 'tasks.md'
        Set-Content -NoNewline -Path $specFile -Value "# Title`n"
        Set-Content -NoNewline -Path $tasksFile -Value "- [ ] T001 A task`n<!-- speckit-jira task=5555555555555555 creating -->`n"
        $rc = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $script:SpecRef -SpecFile $specFile -TasksActionsJson $tasks -TasksFile $tasksFile
        $rc | Should -Be 0
        (Get-Content -Raw $tasksFile) | Should -BeLike '*task=5555555555555555 ticket=COMP-1*'
    }

    It 'no TasksActionsJson and no TasksFile leaves existing zero-task behaviour unaffected (regression)' {
        $script:M = Start-JiraMock -ConfigPath $script:DefaultConfig
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $plan = "{`"parent`":{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"The Epic`"}},`"local_id`":`"aaaaaaaaaaaaaaaa`",`"role`":`"parent`"},`"stories`":[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"Add billing`",`"parent`":{`"key`":`"<resolved at apply time>`"}}},`"local_id`":`"1111111111111111`",`"role`":`"story`"}]}"
        $specFile = Join-Path $TestDrive 'spec2.md'
        Set-Content -NoNewline -Path $specFile -Value "# Title`n"
        $rc = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $script:SpecRef -SpecFile $specFile
        $rc | Should -Be 0
        $calls = (Get-JiraMockCallLog -Mock $script:M) -split "`n" | Where-Object { $_ -eq 'POST /rest/api/3/issue' }
        @($calls).Count | Should -Be 2
    }

    It 'a blocked task body produces zero writes for the whole run' {
        $script:M = Start-JiraMock -ConfigPath $script:DefaultConfig
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $plan = "{`"parent`":null,`"stories`":[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"project`":{`"key`":`"COMP`"},`"summary`":`"Add billing`"}},`"local_id`":`"1111111111111111`",`"role`":`"story`"}]}"
        $tasks = "[{`"method`":`"POST`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue`",`"body`":{`"fields`":{`"description`":`"token ATATT3xFfGF0abcdefghijklmnopqrstuvwxyz1234567890`"}},`"local_id`":`"2222222222222222`",`"parent_local_id`":`"1111111111111111`",`"role`":`"task`"}]"
        $specFile = Join-Path $TestDrive 'spec.md'
        $tasksFile = Join-Path $TestDrive 'tasks.md'
        Set-Content -NoNewline -Path $specFile -Value "# Title`n"
        Set-Content -NoNewline -Path $tasksFile -Value "- [ ] T001 A task`n"
        $rc = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $script:SpecRef -SpecFile $specFile -TasksActionsJson $tasks -TasksFile $tasksFile
        $rc | Should -Be 9
        (Get-JiraMockCallLog -Mock $script:M) | Should -BeNullOrEmpty
    }
}
