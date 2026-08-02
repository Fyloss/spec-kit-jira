# T072 [Phase 9] CRITICAL — mirror of tests/bash/sink/test_role_mapping.bats.
# The resolver's own unit-test file (010, contracts/role-mapping.md).
# `Get-JiraRoleCandidates`, `Resolve-JiraRoleMapping` and
# `Test-JiraRoleMapping` in scripts/powershell/sink/jira/Hierarchy.psm1
# shipped with no unit test at all until now. Every test here calls the
# resolver directly — a pure computation over an in-memory issue-type list —
# so every case has zero Jira writes by construction; the end-to-end "zero
# writes" claim is asserted separately in the commands/ test suites.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $SinkDir = Join-Path $Root 'scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Hierarchy.psm1') -Force

    # The consumer instance (research R11): Epic/Service Category at level 1;
    # thirteen types at level 0 (here trimmed to three); Sous-tâche and Sub
    # Test Execution at level -1, both sub-task.
    $script:ConsumerItypes = @(
        [pscustomobject]@{ logical_name = 'Epic'; id = '10701'; hierarchy_level = 1; subtask = $false },
        [pscustomobject]@{ logical_name = 'Service Category'; id = '10702'; hierarchy_level = 1; subtask = $false },
        [pscustomobject]@{ logical_name = 'Tâche'; id = '10703'; hierarchy_level = 0; subtask = $false },
        [pscustomobject]@{ logical_name = 'Story'; id = '10704'; hierarchy_level = 0; subtask = $false },
        [pscustomobject]@{ logical_name = 'Defect'; id = '10705'; hierarchy_level = 0; subtask = $false },
        [pscustomobject]@{ logical_name = 'Sous-tâche'; id = '10716'; hierarchy_level = -1; subtask = $true },
        [pscustomobject]@{ logical_name = 'Sub Test Execution'; id = '10717'; hierarchy_level = -1; subtask = $true }
    )

    # An unambiguous project — Epic 2 / Feature 1 / Story 0 / Sub-task -1.
    $script:SafeItypes = @(
        [pscustomobject]@{ logical_name = 'Epic'; id = '10401'; hierarchy_level = 2; subtask = $false },
        [pscustomobject]@{ logical_name = 'Feature'; id = '10402'; hierarchy_level = 1; subtask = $false },
        [pscustomobject]@{ logical_name = 'Story'; id = '10403'; hierarchy_level = 0; subtask = $false },
        [pscustomobject]@{ logical_name = 'Sub-task'; id = '10404'; hierarchy_level = -1; subtask = $true }
    )
}

Describe 'Get-JiraRoleCandidates (contract §3.3)' {
    It 'specification and story share the non-sub-task set, in discovered order' {
        $names = (Get-JiraRoleCandidates -IssueTypes $script:ConsumerItypes -Role 'specification' | ForEach-Object { $_.logical_name }) -join ','
        $names | Should -Be 'Epic,Service Category,Tâche,Story,Defect'
        $names2 = (Get-JiraRoleCandidates -IssueTypes $script:ConsumerItypes -Role 'story' | ForEach-Object { $_.logical_name }) -join ','
        $names2 | Should -Be 'Epic,Service Category,Tâche,Story,Defect'
    }

    It "task's candidates are the sub-task types, in discovered order" {
        $names = (Get-JiraRoleCandidates -IssueTypes $script:ConsumerItypes -Role 'task' | ForEach-Object { $_.logical_name }) -join ','
        $names | Should -Be 'Sous-tâche,Sub Test Execution'
    }

    It 'an empty set when the project offers no sub-task type' {
        $flat = @([pscustomobject]@{ logical_name = 'Story'; id = '1'; hierarchy_level = 0; subtask = $false })
        @(Get-JiraRoleCandidates -IssueTypes $flat -Role 'task').Count | Should -Be 0
    }
}

Describe 'Resolve-JiraRoleMapping — precedence steps 1-3 (contract §3)' {
    It 'step 1: a declared name resolves an ambiguous level, source: declared' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{specification = 'Epic'; story = 'Story' } -Operator @{}
        $r.Roles.specification.logical_name | Should -Be 'Epic'
        $r.Roles.specification.source | Should -Be 'declared'
        $r.Roles.story.logical_name | Should -Be 'Story'
        $r.Roles.story.source | Should -Be 'declared'
        $r.Unresolved.Count | Should -Be 0
    }

    It 'step 2: an operator answer resolves without a declaration, source: operator' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{} -Operator @{specification = 'Epic'; story = 'Story' }
        $r.Roles.specification.source | Should -Be 'operator'
        $r.Roles.story.source | Should -Be 'operator'
    }

    It 'step 3: an unambiguous level with nothing declared or answered still derives, source: derived' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'SAFE' -IssueTypes $script:SafeItypes -Declared @{} -Operator @{}
        $r.Roles.story.logical_name | Should -Be 'Story'
        $r.Roles.story.source | Should -Be 'derived'
        $r.Roles.specification.logical_name | Should -Be 'Feature'
        $r.Roles.specification.source | Should -Be 'derived'
    }

    It 'a declared value outranks a conflicting operator answer unconditionally (step 1 > step 2)' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes `
            -Declared @{specification = 'Epic' } -Operator @{specification = 'Service Category'; story = 'Story' }
        $r.Roles.specification.logical_name | Should -Be 'Epic'
        $r.Roles.specification.source | Should -Be 'declared'
    }

    It 'one pass, all roles: BOTH ambiguous tiers are reported in a single call (§3.2, the ordering trap)' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{} -Operator @{}
        $r.Unresolved.Count | Should -Be 2
        $r.Unresolved[0].role | Should -Be 'specification'
        $r.Unresolved[1].role | Should -Be 'story'
        @($r.Unresolved[0].candidates).Count | Should -Be 2
        @($r.Unresolved[1].candidates).Count | Should -Be 3
    }

    It 'task is NEVER derived: a project with exactly one sub-task type still leaves task ABSENT' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'SAFE' -IssueTypes $script:SafeItypes -Declared @{} -Operator @{}
        $r.Roles.Contains('task') | Should -Be $false
        @($r.Unresolved | Where-Object { $_.role -eq 'task' }).Count | Should -Be 0
    }

    It 'an undeclared, unanswered task is ABSENT, not unresolved (§3.4): no roles.task, no unresolved entry' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{specification = 'Epic'; story = 'Story' } -Operator @{}
        $r.Roles.Contains('task') | Should -Be $false
        @($r.Unresolved | Where-Object { $_.role -eq 'task' }).Count | Should -Be 0
    }

    It 'a declared task resolves against the sub-task candidate set, source: declared' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{task = 'Sous-tâche' } -Operator @{}
        $r.Roles.task.logical_name | Should -Be 'Sous-tâche'
        $r.Roles.task.source | Should -Be 'declared'
        $r.Roles.task.subtask | Should -Be $true
    }
}

Describe 'Byte-equal matching — no case folding, trimming, Unicode normalisation, or prefix match (contract §3.3)' {
    It 'no case folding: a lower-cased declaration does not match' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{specification = 'epic' } -Operator @{}
        $r.Unknown[0].name | Should -Be 'epic'
        $r.Roles.Contains('specification') | Should -Be $false
    }

    It 'no trimming beyond YAML scalar rules: a padded declaration does not match' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{specification = ' Epic ' } -Operator @{}
        $r.Unknown[0].name | Should -Be ' Epic '
    }

    It "no Unicode normalisation: NFD (combining accent) does not match the project's NFC name" {
        # Tâche's 'â' as NFC (U+00E2) in the fixture; declare the NFD
        # decomposition (a U+0061 + combining circumflex U+0302) — visually
        # identical, byte-different.
        $nfd = "Ta$([char]0x0302)che"
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{story = $nfd } -Operator @{}
        $r.Roles.Contains('story') | Should -Be $false
        $r.Unknown.Count | Should -Be 1
    }

    It 'no prefix match: a declared name that is a strict prefix of a real type does not match' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{story = 'Sto' } -Operator @{}
        $r.Unknown[0].name | Should -Be 'Sto'
        $r.Roles.Contains('story') | Should -Be $false
    }
}

Describe '§6.2 — unresolved role, the closed question' {
    It 'Get-JiraRoleUnresolvedMessage names the level, every candidate, the declaration path and the flag' {
        $cands = @([pscustomobject]@{ logical_name = 'Epic'; id = '10701' }, [pscustomobject]@{ logical_name = 'Service Category'; id = '10702' })
        $msg = Get-JiraRoleUnresolvedMessage -ProjectKey 'CONSUMER' -Role 'specification' -Level '1' -Candidates $cands
        $msg | Should -Match 'project CONSUMER: the specification level \(1\) holds more than one issue type: Epic, Service Category'
        $msg | Should -Match 'projects\[\].hierarchy.specification'
        $msg | Should -Match '--issue-type CONSUMER=specification=<one of them>'
    }

    It 'ConvertTo-JiraRoleUnresolvedJson emits the structured block, sole option list' {
        $result = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{} -Operator @{}
        $out = ConvertTo-JiraRoleUnresolvedJson -Result $result -ProjectKey 'CONSUMER'
        $out.Count | Should -Be 2
        $out[0].project | Should -Be 'CONSUMER'
        $out[0].role | Should -Be 'specification'
        $out[0].declaration | Should -Be 'projects[].hierarchy.specification'
        $out[0].flag | Should -Be '--issue-type CONSUMER=specification=<name>'
        @($out[0].candidates).Count | Should -Be 2
    }

    It 'an undeclared task role never appears in the unresolved block: absent, not unresolved' {
        $result = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{specification = 'Epic'; story = 'Story' } -Operator @{}
        $out = ConvertTo-JiraRoleUnresolvedJson -Result $result -ProjectKey 'CONSUMER'
        $out.Count | Should -Be 0
    }
}

Describe '§6.3 — unknown type' {
    It 'Resolve-JiraRoleMapping records the unknown-type problem, naming the declared value and the candidate set' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{specification = 'NoSuchType' } -Operator @{}
        $r.Unknown[0].role | Should -Be 'specification'
        $r.Unknown[0].name | Should -Be 'NoSuchType'
        @($r.Unknown[0].candidates).Count | Should -Be 5
    }

    It "Get-JiraRoleUnknownTypeMessage names the tier's offered candidates, never an id" {
        $cands = @([pscustomobject]@{ logical_name = 'Epic'; id = '10701' }, [pscustomobject]@{ logical_name = 'Service Category'; id = '10702' })
        $msg = Get-JiraRoleUnknownTypeMessage -ProjectKey 'CONSUMER' -Role 'specification' -Name 'NoSuchType' -Candidates $cands
        $msg | Should -Match 'specification names issue type "NoSuchType", which this project does not offer at that tier'
        $msg | Should -Match 'It offers: Epic, Service Category \(zero writes\)'
        $msg | Should -Not -Match '10701'
    }

    It 'a name that exists in the project but in the OTHER candidate set is unknown, not a cross-tier match' {
        # Sous-tâche exists (as a sub-task type) but is declared for
        # specification — this is subtask misuse (§6.5), never an unrelated
        # §6.3 with the wrong candidate list.
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{specification = 'Sous-tâche' } -Operator @{}
        $r.Unknown.Count | Should -Be 0
        $r.SubtaskMisuse[0].name | Should -Be 'Sous-tâche'
    }
}

Describe '§6.4 — duplicate name at a level' {
    BeforeAll {
        $script:DuplicateItypes = @(
            [pscustomobject]@{ logical_name = 'Epic'; id = '10701'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Epic'; id = '10799'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Story'; id = '10704'; hierarchy_level = 0; subtask = $false }
        )
    }

    It 'Resolve-JiraRoleMapping records the duplicate problem, naming the level' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'DUP' -IssueTypes $script:DuplicateItypes -Declared @{specification = 'Epic' } -Operator @{}
        $r.Duplicate[0].role | Should -Be 'specification'
        $r.Duplicate[0].name | Should -Be 'Epic'
        $r.Duplicate[0].level | Should -Be '1'
        $r.Roles.Contains('specification') | Should -Be $false
    }

    It 'Get-JiraRoleDuplicateMessage states the bridge will not choose one for you' {
        $msg = Get-JiraRoleDuplicateMessage -ProjectKey 'DUP' -Role 'specification' -Name 'Epic' -Level '1'
        $msg | Should -Match 'specification names "Epic", which matches more than one issue type at level 1'
        $msg | Should -Match 'The bridge will not choose one for you \(zero writes\)'
    }
}

Describe '§6.5 — sub-task type for a non-sub-task role' {
    It 'a sub-task type declared for specification is subtask misuse, in both directions of the role list' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{specification = 'Sous-tâche' } -Operator @{}
        $r.SubtaskMisuse[0].role | Should -Be 'specification'
        $r.SubtaskMisuse[0].name | Should -Be 'Sous-tâche'

        $r2 = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{story = 'Sous-tâche' } -Operator @{}
        $r2.SubtaskMisuse[0].role | Should -Be 'story'
    }

    It 'a sub-task type reported at level 0 is caught by the subtask FLAG, never by its level (§4.1)' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'Story'; id = '1'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Odd Sub-task'; id = '2'; hierarchy_level = 0; subtask = $true }
        )
        $r = Resolve-JiraRoleMapping -ProjectKey 'X' -IssueTypes $itypes -Declared @{story = 'Odd Sub-task' } -Operator @{}
        $r.SubtaskMisuse[0].name | Should -Be 'Odd Sub-task'
    }

    It 'Get-JiraRoleSubtaskMisuseMessage names the role and the type' {
        $msg = Get-JiraRoleSubtaskMisuseMessage -ProjectKey 'CONSUMER' -Role 'specification' -Name 'Sous-tâche'
        $msg | Should -Match 'specification names "Sous-tâche", which is a sub-task type in this project'
        $msg | Should -Match 'A specification cannot be a sub-task \(zero writes\)'
    }
}

Describe '§6.6 — non-sub-task type for the task role' {
    It 'a non-sub-task type declared for task is task misuse, naming its sub-task candidates' {
        $r = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{task = 'Story' } -Operator @{}
        $r.TaskMisuse[0].name | Should -Be 'Story'
        @($r.TaskMisuse[0].candidates).Count | Should -Be 2
    }

    It 'Get-JiraRoleTaskMisuseMessage renders an empty candidate list as the explicit words, never an empty string' {
        $msg = Get-JiraRoleTaskMisuseMessage -ProjectKey 'X' -Name 'Story' -Candidates @()
        $msg | Should -Match 'Its sub-task types are: none — this project offers no sub-task type \(zero writes\)'
    }

    It 'Get-JiraRoleTaskMisuseMessage names the offered sub-task candidates when they exist' {
        $cands = @([pscustomobject]@{ logical_name = 'Sous-tâche'; id = '10716' }, [pscustomobject]@{ logical_name = 'Sub Test Execution'; id = '10717' })
        $msg = Get-JiraRoleTaskMisuseMessage -ProjectKey 'CONSUMER' -Name 'Story' -Candidates $cands
        $msg | Should -Match 'task names "Story", which is not a sub-task type in this project'
        $msg | Should -Match 'Its sub-task types are: Sous-tâche, Sub Test Execution \(zero writes\)'
    }
}

Describe '§6.7 — ordering' {
    It 'Test-JiraRoleMapping refuses when specification does not sit strictly above story' {
        $roles = @{ specification = @{ logical_name = 'Story'; hierarchy_level = '0' }; story = @{ logical_name = 'Epic'; hierarchy_level = '1' } }
        $msg = $null
        $ok = Test-JiraRoleMapping -ProjectKey 'CONSUMER' -Roles $roles -Message ([ref]$msg)
        $ok | Should -Be $false
        $msg | Should -Match 'specification names "Story" at level 0, which is not above story "Epic" at level 1'
        $msg | Should -Match 'A specification must sit above its stories \(zero writes\)'
    }

    It 'equal levels refuse too (not strictly above is not the same as below)' {
        $roles = @{ specification = @{ logical_name = 'Epic'; hierarchy_level = '0' }; story = @{ logical_name = 'Story'; hierarchy_level = '0' } }
        $msg = $null
        (Test-JiraRoleMapping -ProjectKey 'CONSUMER' -Roles $roles -Message ([ref]$msg)) | Should -Be $false
    }

    It 'a gap greater than one level is ACCEPTED (FR-012): no adjacency requirement' {
        $roles = @{ specification = @{ logical_name = 'Initiative'; hierarchy_level = '3' }; story = @{ logical_name = 'Story'; hierarchy_level = '0' } }
        $msg = $null
        (Test-JiraRoleMapping -ProjectKey 'CONSUMER' -Roles $roles -Message ([ref]$msg)) | Should -Be $true
        $msg | Should -BeNullOrEmpty
    }

    It 'levels compare NUMERICALLY: a lexical comparison must not wrongly refuse a negative level above a smaller positive one' {
        $roles = @{ specification = @{ logical_name = 'Epic'; hierarchy_level = '2' }; story = @{ logical_name = 'Sub-task-ish'; hierarchy_level = '-1' } }
        $msg = $null
        (Test-JiraRoleMapping -ProjectKey 'CONSUMER' -Roles $roles -Message ([ref]$msg)) | Should -Be $true
    }
}

Describe 'Test-JiraRoleMappingHasProblems' {
    It 'is false on a fully-resolved result, true when any problem array is non-empty' {
        $ok = Resolve-JiraRoleMapping -ProjectKey 'SAFE' -IssueTypes $script:SafeItypes -Declared @{} -Operator @{}
        (Test-JiraRoleMappingHasProblems -Result $ok) | Should -Be $false

        $bad = Resolve-JiraRoleMapping -ProjectKey 'CONSUMER' -IssueTypes $script:ConsumerItypes -Declared @{} -Operator @{}
        (Test-JiraRoleMappingHasProblems -Result $bad) | Should -Be $true
    }
}
