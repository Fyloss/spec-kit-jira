# T047/T048/T049 [US11] — Privacy guard BLOCK tier (FR-052, Constitution IV/IX).
# Mirror of tests/bash/sink/test_privacy_block.bats. Before every write the guard
# blocks on an ATATT token prefix, a real *.atlassian.net host, or an exact known
# coordinate — zero writes, dedicated exit 9. Precision over recall: generic
# email/UUID shapes (P3 WARN tier) do not block. The offending value is never
# echoed. The apply path routes every write through the guard with no gap.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Sink = Join-Path $Root 'scripts/powershell/sink/jira'
    $Engine = Join-Path $Root 'scripts/powershell/engine'
    $script:Mock = Join-Path $Root 'tests/conformance/mock-jira'
    # Import PlanApply first: it re-imports PrivacyGuard -Force into its own module
    # scope, so import PrivacyGuard LAST to keep its functions in the test session.
    Import-Module (Join-Path $Sink 'PlanApply.psm1') -Force
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $Sink 'PrivacyGuard.psm1') -Force
    Import-Module (Join-Path $Engine 'Markdown.psm1') -Force
    Import-Module (Join-Path $Sink 'Adf.psm1') -Force
    Import-Module (Join-Path $Sink '../../lib/Output.psm1') -Force -Global
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
}

Describe 'Privacy guard BLOCK tier' {
    It 'blocks on an ATATT token prefix (exit 9)' {
        Test-JiraPrivacyBlock -Payload 'see token ATATT3xFfGF0abcdef' | Should -Be 9
    }
    It 'blocks on a real *.atlassian.net host (exit 9)' {
        Test-JiraPrivacyBlock -Payload 'mirror of acme-corp.atlassian.net/browse/X' | Should -Be 9
    }
    It 'blocks on an exact known coordinate (exit 9)' {
        Test-JiraPrivacyBlock -Payload 'internal ref ACME-PROD site' -KnownCoordinatesJson '["ACME-PROD site"]' | Should -Be 9
    }
    It 'passes ordinary content — precision over recall (exit 0)' {
        Test-JiraPrivacyBlock -Payload 'Add the billing feature; team@example.com; 550e8400-e29b-41d4-a716-446655440000' | Should -Be 0
    }
}

Describe 'Privacy guard fail-open regressions (case bypass + allowlist shredding)' {
    It 'blocks a MiXeD-case Atlassian host — DNS hosts are case-insensitive (FR-052)' {
        Test-JiraPrivacyBlock -Payload 'see https://Acme.Atlassian.Net/browse/PROJ-1' | Should -Be 9
    }
    It 'an allowlist entry overlapping the token shape never disables token detection (FR-052)' {
        Test-JiraPrivacyBlock -Payload 'see token ATATT3xFfGF0abcdef for access' -AllowlistJson '["ATAT"]' | Should -Be 9
    }
    It 'an allowlist entry matching a SUBSTRING of a real host never neutralises it (FR-052)' {
        Test-JiraPrivacyBlock -Payload 'leak acme-corp.atlassian.net' -AllowlistJson '["corp.atlassian.net"]' | Should -Be 9
    }
    It 'an allowlist entry overlapping a known coordinate never disables its detection (FR-052)' {
        Test-JiraPrivacyBlock -Payload 'internal ref ACME-PROD site' -KnownCoordinatesJson '["ACME-PROD site"]' -AllowlistJson '["ACME"]' | Should -Be 9
    }
    It 'an allowlisted domain still exempts its own hosts, any case (FR-053 preserved)' {
        Test-JiraPrivacyBlock -Payload 'see OurCo.Atlassian.Net/wiki/spaces/OPS' -AllowlistJson '["ourco.atlassian.net"]' | Should -Be 0
    }
    It 'keeps case-variant known coordinates DISTINCT and sorted like jq unique (NFR-1)' {
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        Get-JiraApplyKnownCoordinate -ExtraJson '["PROJ-Secret","proj-secret","B","a"]' |
            Should -Be '["B","PROJ-Secret","a","proj-secret"]'
    }
}

Describe '016 research §4 — a BLOCK-tier host inside a Markdown link' {
    It 'still blocks once rendered to ADF' {
        $spans = @(ConvertTo-JiraMarkdownInlineSpanList -Text '[docs](https://acme-corp.atlassian.net/wiki/x)' | ConvertFrom-Json -Depth 20)
        $content = ConvertTo-JiraJsonValue ([ordered]@{
                description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = $spans }) }
            })
        $adf = ConvertTo-JiraAdfDocument -ContentJson $content
        Test-JiraPrivacyBlock -Payload $adf | Should -Be 9
    }
}

Describe 'Privacy guard as the mandatory pre-write gate' {
    BeforeEach {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach { Stop-JiraMock -Mock $M }

    It 'blocks before any write and performs ZERO writes (exit 9)' {
        $actions = '[{"method":"POST","url":"' + $M.BaseUrl + '/rest/api/3/issue","body":{"fields":{"summary":"leak acme-corp.atlassian.net"}}}]'
        Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 9
        @(Get-JiraMockCallLog -Mock $M).Count | Should -Be 0
    }

    It 'lets a clean write through (no gap for legitimate writes)' {
        $actions = '[{"method":"POST","url":"' + $M.BaseUrl + '/rest/api/3/issue","body":{"fields":{"summary":"Add the billing feature"}}}]'
        Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 0
        (Get-JiraMockCallLog -Mock $M) -join "`n" | Should -Match 'POST /rest/api/3/issue'
    }
}

Describe 'T058 [Phase 5, US2] — the parent payload passes the SAME pre-write gate' {
    BeforeEach {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach { Stop-JiraMock -Mock $M }

    It 'a blocked parent payload yields ZERO writes for the whole specification, including its stories' {
        $plan = '{"parent":{"method":"POST","url":"' + $M.BaseUrl + '/rest/api/3/issue","body":{"fields":{"summary":"leak acme-corp.atlassian.net"}},"local_id":"aaaaaaaaaaaaaaaa","role":"parent"},"stories":[{"method":"POST","url":"' + $M.BaseUrl + '/rest/api/3/issue","body":{"fields":{"summary":"Add the billing feature"}},"local_id":"1111111111111111","role":"story"}]}'
        $specRef = '{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
        $specFile = Join-Path $TestDrive 'spec.md'
        Set-Content -LiteralPath $specFile -Value '# Title' -NoNewline
        # 015: the function now returns [ordered]@{ ExitCode; Created } rather
        # than a bare exit code (contract §4.2/data-model.md §5 — the
        # structured mirror of the bash port's stdout outcome). O4: Created
        # stays empty on this pre-write privacy-guard return.
        $result = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $specRef -SpecFile $specFile
        $result.ExitCode | Should -Be 9
        @($result.Created).Count | Should -Be 0
        @(Get-JiraMockCallLog -Mock $M).Count | Should -Be 0
    }

    It 'a clean parent and clean stories are written through (no gap for legitimate writes)' {
        $plan = '{"parent":{"method":"POST","url":"' + $M.BaseUrl + '/rest/api/3/issue","body":{"fields":{"summary":"The Epic"}},"local_id":"aaaaaaaaaaaaaaaa","role":"parent"},"stories":[{"method":"POST","url":"' + $M.BaseUrl + '/rest/api/3/issue","body":{"fields":{"summary":"Add the billing feature","parent":{"key":"<resolved at apply time>"}}},"local_id":"1111111111111111","role":"story"}]}'
        $specRef = '{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
        $specFile = Join-Path $TestDrive 'spec2.md'
        Set-Content -LiteralPath $specFile -Value '# Title' -NoNewline
        $result = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $specRef -SpecFile $specFile
        $result.ExitCode | Should -Be 0
        @($result.Created).Count | Should -Be 2
        @([regex]::Matches((Get-JiraMockCallLog -Mock $M) -join "`n", 'POST /rest/api/3/issue')).Count | Should -Be 2
    }

    It '015 T027 (rule O4) — a blocked STORY payload (clean parent) also reports zero Created' {
        $plan = '{"parent":{"method":"POST","url":"' + $M.BaseUrl + '/rest/api/3/issue","body":{"fields":{"summary":"The Epic"}},"local_id":"aaaaaaaaaaaaaaaa","role":"parent"},"stories":[{"method":"POST","url":"' + $M.BaseUrl + '/rest/api/3/issue","body":{"fields":{"summary":"leak acme-corp.atlassian.net"}},"local_id":"1111111111111111","role":"story"}]}'
        $specRef = '{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
        $specFile = Join-Path $TestDrive 'spec_story_block.md'
        Set-Content -LiteralPath $specFile -Value '# Title' -NoNewline
        $result = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $specRef -SpecFile $specFile
        $result.ExitCode | Should -Be 9
        @($result.Created).Count | Should -Be 0
        @(Get-JiraMockCallLog -Mock $M).Count | Should -Be 0
    }
}

Describe '018, T017 — the narrowed scan scope (contract §5, FR-024a)' {
    BeforeEach {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach { Stop-JiraMock -Mock $M }

    It 'a *.atlassian.net host present only in the preserved human prefix does not block the run' {
        $marker = Get-JiraManagedMarker
        $desc = @{
            type    = 'doc'; version = 1
            content = @(
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'see mirror of https://acme-corp.atlassian.net/browse/X' }) },
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $marker; marks = @(@{ type = 'strong' }) }) },
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'managed body, composed by the mirror' }) }
            )
        } | ConvertTo-Json -Depth 100 -Compress
        $actions = '[{"method":"PUT","url":"' + $M.BaseUrl + '/rest/api/3/issue/PROJ-1","body":{"fields":{"description":' + $desc + '}}}]'
        Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 0
        (Get-JiraMockCallLog -Mock $M) -join "`n" | Should -Match 'PUT /rest/api/3/issue/PROJ-1'
    }

    It 'the same host in a node the mirror composes still blocks with zero writes' {
        $marker = Get-JiraManagedMarker
        $desc = @{
            type    = 'doc'; version = 1
            content = @(
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'an ordinary human note' }) },
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $marker; marks = @(@{ type = 'strong' }) }) },
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'leak acme-corp.atlassian.net' }) }
            )
        } | ConvertTo-Json -Depth 100 -Compress
        $actions = '[{"method":"PUT","url":"' + $M.BaseUrl + '/rest/api/3/issue/PROJ-1","body":{"fields":{"description":' + $desc + '}}}]'
        Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 9
        @(Get-JiraMockCallLog -Mock $M).Count | Should -Be 0
    }
}

Describe 'T110a [Phase 8, 022] — a checklist entry rides the same description sweep' {
    BeforeAll {
        $script:DocWithChecklistTask = '{
          "routing": {"project_key":"COMP"},
          "epic": {"title":"E", "local_id":"e1",
            "marker":{"state":"assigned","id":"e1","lines":[2]},
            "description":{"blocks":[]}},
          "stories": [
            {"local_id":"s1","title":"A story","description":{"blocks":[]},
             "tasks":[{"title":"REPLACE_TITLE","done":false,"phase":null}],
             "priority_logical":"P1"}
          ]
        }'
    }
    BeforeEach {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach { Stop-JiraMock -Mock $M }

    It 'a checklist entry carrying a BLOCK-tier value aborts the apply before the first write (FR-038)' {
        $doc = $script:DocWithChecklistTask | ConvertFrom-Json -Depth 100
        $doc.stories[0].tasks[0].title = 'leak acme-corp.atlassian.net'
        $docJson = ConvertTo-Json $doc -Depth 20 -Compress
        $ctx = '{"base_url":"' + $M.BaseUrl + '","story_type_id":"10002","parent_type_id":"10101","parent_local_id":"e1","priority_ids":{},"task_mirror":"checklist"}'
        $plan = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $actions = ConvertTo-Json (@($plan.stories) + @($plan.parent)) -Depth 20 -Compress
        Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 9
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -Be 0
    }

    It 'an allowlisted Confluence link inside a checklist entry passes silently' {
        $env:SPEC_KIT_JIRA_ALLOWLIST = '["docs.example-support.atlassian.net"]'
        try {
            $doc = $script:DocWithChecklistTask | ConvertFrom-Json -Depth 100
            $doc.stories[0].tasks[0].title = 'see https://docs.example-support.atlassian.net/wiki/x'
            $docJson = ConvertTo-Json $doc -Depth 20 -Compress
            $ctx = '{"base_url":"' + $M.BaseUrl + '","story_type_id":"10002","parent_type_id":"10101","parent_local_id":"e1","priority_ids":{},"task_mirror":"checklist"}'
            $plan = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
            $actions = ConvertTo-Json (@($plan.stories) + @($plan.parent)) -Depth 20 -Compress
            Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 0
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_ALLOWLIST -ErrorAction SilentlyContinue }
    }
}
