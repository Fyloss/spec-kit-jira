# T010 [Phase 1, defect 2] / T033-T037 [Phase 4, US1] — mirror of
# tests/bash/sink/test_hierarchy.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $SinkDir = Join-Path $Root 'scripts/powershell/sink/jira'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Discovery.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    # -Global, and LAST: Config.psm1 imports Hierarchy.psm1 as a NESTED
    # dependency, which loads it into Config.psm1's own module scope rather
    # than the session. Importing it again here, after Config.psm1, with
    # -Global, is what actually exposes its functions to this Describe block.
    Import-Module (Join-Path $SinkDir 'Hierarchy.psm1') -Force -Global
    Import-Module (Join-Path $SinkDir 'Recognition.psm1') -Force -Global
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-french-project'

    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-checkout'
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile — child type resolution on a non-default Jira' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-checkout/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'resolves the child type on a French project' {
        # Phase 5 (US2): the parent (Épopée, 10301) is created first, then
        # every story at the resolved CHILD type (Récit, 10302).
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/french.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        (Get-JiraMockIssueField -Mock $script:M -Key 'FR-1' -Path 'fields.issuetype.id') | Should -Be '10301'
        (Get-JiraMockIssueField -Mock $script:M -Key 'FR-2' -Path 'fields.issuetype.id') | Should -Be '10302'
        (Get-JiraMockIssueField -Mock $script:M -Key 'FR-3' -Path 'fields.issuetype.id') | Should -Be '10302'
    }

    It 'T037 — a binding with no recorded child_type refuses child-type-unresolved' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/french.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $localf = Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml'
        $obj = ConvertFrom-JiraConfigYaml -Path $localf | ConvertFrom-Json -Depth 100
        $obj.resolved_ids.FR.PSObject.Properties.Remove('child_type')
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-Json -InputObject $obj -Depth 100 -Compress)
        Set-Content -LiteralPath $localf -Value $yaml -NoNewline

        $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $out | Should -Match 'no recorded issue type for user stories'
    }
}

Describe 'Get-JiraHierarchyDerivation' {
    It 'T033 — child level is the minimum hierarchy_level over non-subtask types' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'Epic'; id = '1'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Story'; id = '2'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Sub-task'; id = '3'; hierarchy_level = -1; subtask = $true }
        )
        Get-JiraHierarchyChildLevel -IssueTypes $itypes | Should -Be 0
    }

    It 'T034 — default Scrum: Epic 1 / Story 0 / Sub-task -1 -> parent Epic' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'Epic'; id = '1'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Story'; id = '2'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Sub-task'; id = '3'; hierarchy_level = -1; subtask = $true }
        )
        $r = Get-JiraHierarchyDerivation -ProjectKey 'COMP' -IssueTypes $itypes
        $r.Status | Should -Be 'ok'
        $r.Parent.logical_name | Should -Be 'Epic'
        $r.ChildLevel | Should -Be 0
        $r.ParentLevel | Should -Be 1
    }

    It 'T034 — company-managed fixture: parent Deliverable' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'Initiative'; id = '10100'; hierarchy_level = 2; subtask = $false },
            [pscustomobject]@{ logical_name = 'Deliverable'; id = '10101'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Story'; id = '10102'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Defect'; id = '10103'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Sub-task'; id = '10104'; hierarchy_level = -1; subtask = $true }
        )
        (Get-JiraHierarchyDerivation -ProjectKey 'COMP' -IssueTypes $itypes).Parent.logical_name | Should -Be 'Deliverable'
    }

    It 'T034 — SAFe: parent Feature' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'Epic'; id = '10401'; hierarchy_level = 2; subtask = $false },
            [pscustomobject]@{ logical_name = 'Feature'; id = '10402'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Story'; id = '10403'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Sub-task'; id = '10404'; hierarchy_level = -1; subtask = $true }
        )
        (Get-JiraHierarchyDerivation -ProjectKey 'SAFE' -IssueTypes $itypes).Parent.logical_name | Should -Be 'Feature'
    }

    It 'T034 — Latin-diacritic project: parent Épopée' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'Épopée'; id = '10301'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Récit'; id = '10302'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Tâche'; id = '10303'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Sous-tâche'; id = '10304'; hierarchy_level = -1; subtask = $true }
        )
        (Get-JiraHierarchyDerivation -ProjectKey 'FR' -IssueTypes $itypes).Parent.logical_name | Should -Be 'Épopée'
    }

    It 'T034 — non-Latin project: parent エピック' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'エピック'; id = '10501'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'ストーリー'; id = '10502'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Задача (QA)'; id = '10503'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'サブタスク'; id = '10504'; hierarchy_level = -1; subtask = $true }
        )
        (Get-JiraHierarchyDerivation -ProjectKey 'NL' -IssueTypes $itypes).Parent.logical_name | Should -Be 'エピック'
    }

    It 'T035 — a flat project (Story alone) refuses no-parent-level' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'Story'; id = '1'; hierarchy_level = 0; subtask = $false },
            [pscustomobject]@{ logical_name = 'Sub-task'; id = '2'; hierarchy_level = -1; subtask = $true }
        )
        $r = Get-JiraHierarchyDerivation -ProjectKey 'FLAT' -IssueTypes $itypes
        $r.Status | Should -Be 'no-parent-level'
        $r.Message | Should -Match 'FLAT'
        $r.Message | Should -Match 'Story'
    }

    It 'T036 — two candidates at the parent tier refuses, naming every candidate' {
        $itypes = @(
            [pscustomobject]@{ logical_name = 'Capability'; id = '1'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Feature'; id = '2'; hierarchy_level = 1; subtask = $false },
            [pscustomobject]@{ logical_name = 'Story'; id = '3'; hierarchy_level = 0; subtask = $false }
        )
        $r = Get-JiraHierarchyDerivation -ProjectKey 'AMBIG' -IssueTypes $itypes
        $r.Status | Should -Be 'parent-level-ambiguous'
        $r.Message | Should -Match 'Capability'
        $r.Message | Should -Match 'Feature'
    }
}

# --- T081-T084 [Phase 6, US3]: the mandatory-field gate (contract §5). Mirror
# of test_hierarchy.bats's own T081-T084 block. ---------------------------

Describe 'Get-JiraHierarchyMandatoryGate' {
    BeforeAll {
        $script:BindingMandatoryJson = '{
          "child_type": {"logical_name":"Story", "id":"10102"},
          "parent_type": {"logical_name":"Deliverable", "id":"10101"},
          "parent_link_available": {"10102": true},
          "required_fields": {
            "10101": [
              {"logical_name":"Summary", "field_id":"summary"},
              {"logical_name":"Business Owner", "field_id":"customfield_40011"},
              {"logical_name":"Program Increment", "field_id":"customfield_40012"}
            ],
            "10102": [
              {"logical_name":"Summary", "field_id":"summary"}
            ]
          }
        }'
    }

    It 'T081 — the satisfaction table: summary/description/issuetype/project/priority/reporter are always satisfiable' {
        $fields = @(
            [pscustomobject]@{ logical_name = 'Summary'; field_id = 'summary' },
            [pscustomobject]@{ logical_name = 'Description'; field_id = 'description' },
            [pscustomobject]@{ logical_name = 'Issue Type'; field_id = 'issuetype' },
            [pscustomobject]@{ logical_name = 'Project'; field_id = 'project' },
            [pscustomobject]@{ logical_name = 'Priority'; field_id = 'priority' },
            [pscustomobject]@{ logical_name = 'Reporter'; field_id = 'reporter' }
        )
        (Get-JiraHierarchyUnsatisfiableFields -Fields $fields -HasParentLink $false).Count | Should -Be 0
    }

    It 'T081 — parent is satisfiable on the child type only when the link is available' {
        $fields = @([pscustomobject]@{ logical_name = 'Parent'; field_id = 'parent' })
        (Get-JiraHierarchyUnsatisfiableFields -Fields $fields -HasParentLink $true).Count | Should -Be 0
        (Get-JiraHierarchyUnsatisfiableFields -Fields $fields -HasParentLink $false) | Should -Be @('Parent')
    }

    It 'T081 — any other field is not satisfiable' {
        $fields = @([pscustomobject]@{ logical_name = 'Business Owner'; field_id = 'customfield_40011' })
        (Get-JiraHierarchyUnsatisfiableFields -Fields $fields -HasParentLink $true) | Should -Be @('Business Owner')
    }

    It 'T082 — the gate reports every unsatisfiable field of every written type in ONE refusal, named by Jira''s own field name' {
        $binding = $script:BindingMandatoryJson | ConvertFrom-Json
        $r = Get-JiraHierarchyMandatoryGate -Binding $binding
        $r.status | Should -Be 'unsatisfiable'
        $r.message | Should -Match '"Deliverable"'
        $r.message | Should -Match '"Business Owner"'
        $r.message | Should -Match '"Program Increment"'
        $r.message | Should -Not -Match 'customfield_'
    }

    It 'T082 — a non-ASCII field name survives the refusal intact' {
        $binding = $script:BindingMandatoryJson | ConvertFrom-Json
        $binding.required_fields.'10101' += [pscustomobject]@{ logical_name = 'Équipe propriétaire'; field_id = 'customfield_40099' }
        $r = Get-JiraHierarchyMandatoryGate -Binding $binding
        $r.message | Should -Match 'Équipe propriétaire'
    }

    It 'T083 — the refusal is a named mandatory-field reason, never a transport error' {
        $binding = $script:BindingMandatoryJson | ConvertFrom-Json
        $r = Get-JiraHierarchyMandatoryGate -Binding $binding
        $r.status | Should -Be 'unsatisfiable'
        $r.reason | Should -Be 'mandatory-fields-unsatisfiable'
    }

    It 'T083 — the gate fires for the child type as well as the parent' {
        $binding = $script:BindingMandatoryJson | ConvertFrom-Json
        $binding.required_fields.'10102' += [pscustomobject]@{ logical_name = 'Team'; field_id = 'customfield_50001' }
        $r = Get-JiraHierarchyMandatoryGate -Binding $binding
        $r.message | Should -Match '"Story"'
        $r.message | Should -Match '"Team"'
    }

    It 'T083 — a hierarchy with no unsatisfiable fields passes the gate cleanly' {
        $binding = $script:BindingMandatoryJson | ConvertFrom-Json
        $binding.required_fields.'10101' = @([pscustomobject]@{ logical_name = 'Summary'; field_id = 'summary' })
        $r = Get-JiraHierarchyMandatoryGate -Binding $binding
        $r.status | Should -Be 'ok'
    }

    It 'T084 — parent-link-unavailable when the child type''s create metadata offers no parent field' {
        $binding = $script:BindingMandatoryJson | ConvertFrom-Json
        $binding.parent_link_available.'10102' = $false
        $binding.required_fields.'10102' = @([pscustomobject]@{ logical_name = 'Summary'; field_id = 'summary' })
        $r = Get-JiraHierarchyMandatoryGate -Binding $binding -ProjectKey 'COMP'
        $r.status | Should -Be 'parent-link-unavailable'
        $r.message | Should -Match 'Story'
        $r.message | Should -Match 'COMP'
    }
}

Describe 'T097 — the diagnostics catalogue, matched verbatim' {
    BeforeAll {
        $script:SpecRefJson = '{"repo":"acme/app","spec_slug":"001-checkout"}'
    }

    It 'parent-marker-malformed reason and message match the contract verbatim' {
        $minfo = '{"state":"malformed","lines":[3]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRefJson -ProjectKey 'COMP' -SpecPath 'specs/001-checkout/spec.md'
        $j = $r.Json | ConvertFrom-Json
        $j.reason | Should -Be 'parent-marker-malformed'
        $j.detail | Should -Be 'specs/001-checkout/spec.md line 3: malformed speckit-jira parent marker; nothing was written for this specification. Expected `<!-- speckit-jira spec=<16 hex> ticket=<KEY> -->`.'
    }

    It 'parent-marker-duplicate reason and message match the contract verbatim' {
        $minfo = '{"state":"duplicate","lines":[2,7]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRefJson -ProjectKey 'COMP' -SpecPath 'specs/001-checkout/spec.md'
        $j = $r.Json | ConvertFrom-Json
        $j.reason | Should -Be 'parent-marker-duplicate'
        $j.detail | Should -Be 'specs/001-checkout/spec.md carries 2 speckit-jira parent markers (lines 2, 7); a specification has exactly one parent. Keep the line naming the parent that exists in Jira and delete the others.'
    }

    It 'the parent''s creating state is parent-key-unrecorded, distinct from a story''s key-unrecorded' {
        $minfo = '{"state":"creating","id":"3f2a91c04b7e6d18"}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRefJson -ProjectKey 'COMP' -SpecPath 'specs/001-checkout/spec.md'
        $j = $r.Json | ConvertFrom-Json
        $j.reason | Should -Be 'parent-key-unrecorded'
        $j.detail | Should -Match '3f2a91c04b7e6d18'
        $j.detail | Should -Match 'COMP'
    }

    It 'no diagnostic message in this catalogue leaks a host, URL scheme or credential' {
        $msgs = @(
            'specs/001-checkout/spec.md line 3: malformed speckit-jira parent marker; nothing was written for this specification. Expected `<!-- speckit-jira spec=<16 hex> ticket=<KEY> -->`.',
            'specs/001-checkout/spec.md carries 2 speckit-jira parent markers (lines 2, 7); a specification has exactly one parent. Keep the line naming the parent that exists in Jira and delete the others.',
            (Get-JiraHierarchyParentLinkUnavailableMessage -ProjectKey 'COMP' -ChildLogicalName 'Story'),
            (Get-JiraHierarchyChildTypeUnresolvedMessage -ProjectKey 'COMP'),
            (Get-JiraHierarchyBindingShapeStaleMessage -ProjectKey 'COMP')
        )
        foreach ($m in $msgs) {
            $m | Should -Not -Match 'http://'
            $m | Should -Not -Match 'https://'
            $m | Should -Not -Match 'RAWSECRET'
        }
    }
}

Describe 'Invoke-JiraReconcile — the mandatory-field gate runs BEFORE recognition' {
    BeforeAll {
        function Invoke-CapturedWithCode {
            param([string[]] $ArgList)
            $sw = [System.IO.StringWriter]::new()
            $orig = [Console]::Out; $origErr = [Console]::Error
            [Console]::SetOut($sw); [Console]::SetError($sw)
            try { $code = Invoke-JiraReconcile -Arguments $ArgList }
            finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
            return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
        }
    }
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse (Join-Path $Root 'tests/conformance/fixtures/repo-with-mandatory-field') $script:Work
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-reporting'
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T083/T084 — zero writes, driven end to end through Invoke-JiraReconcile' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $spec = Join-Path $script:Work 'specs/001-reporting/spec.md'

        $r = Invoke-CapturedWithCode @('reconcile', $spec, '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'Deliverable'
        $r.Out | Should -Match 'Business Owner'
        $r.Out | Should -Match 'Program Increment'

        (Get-JiraMockCallLog -Mock $script:M).Count | Should -Be 0
    }
}
