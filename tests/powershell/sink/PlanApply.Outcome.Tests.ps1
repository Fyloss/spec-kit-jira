# 015 T027 [US3] — mirror of tests/bash/sink/test_plan_apply_outcome.bats.
# Invoke-JiraApplyWriteSetWithRecognition's confirmed-creation outcome
# (contract §4.2, data-model.md §5, research R4): {ExitCode; Created} — the
# structured PowerShell mirror of the bash port's stdout outcome
# {"created":[{key, role, local_id}, ...]}.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/PlanApply.psm1') -Force
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function New-MockConfig {
        param([string] $Json)
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($path, $Json)
        return $path
    }
}

Describe 'Invoke-JiraApplyWriteSetWithRecognition — the confirmed-creation outcome (015)' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        # 032, C6.4 — cleared with the rest. FR-011 EXEMPTS an
        # environment-supplied destination from the pin, so a leaked value
        # would silently exempt a later test that is meant to meet the gate,
        # hiding a failure rather than causing one.
        $env:SPEC_KIT_JIRA_BASE_URL = $null
    }

    It 'normal completion: the outcome names both creations, parent first (O1/O2/O3)' {
        $script:M = Start-JiraMock -ConfigPath (New-MockConfig '{"projects":{"AAA":"team"}}')
        # 032, C6.4 — declare the destination the way production does. The
        # connection chokepoint sets this variable before any request; a suite
        # that drives the transport directly must stand in for it, or the
        # credential producer rightly refuses a destination nothing verified.
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $base = $script:M.BaseUrl
        $plan = '{"parent":{"method":"POST","url":"' + $base + '/rest/api/3/issue","body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10101"},"summary":"The Epic"}},"local_id":"aaaaaaaaaaaaaaaa","role":"parent"},' +
            '"stories":[{"method":"POST","url":"' + $base + '/rest/api/3/issue","body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10102"},"summary":"A story","parent":{"key":"<resolved at apply time>"}}},"local_id":"1111111111111111","role":"story"}]}'
        $specRef = '{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
        $specFile = Join-Path $TestDrive 'spec.md'
        Set-Content -LiteralPath $specFile -Value '# Title' -NoNewline

        $result = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $specRef -SpecFile $specFile
        $result.ExitCode | Should -Be 0
        $created = @($result.Created)
        $created.Count | Should -Be 2
        $created[0].role | Should -Be 'parent'
        $created[0].key | Should -Be 'AAA-1'
        $created[1].role | Should -Be 'story'
        $created[1].key | Should -Be 'AAA-2'
    }

    It "parent rejection: the outcome is empty — nothing was created before the parent's own write failed (O1/O3)" {
        $script:M = Start-JiraMock -ConfigPath (New-MockConfig '{"projects":{"AAA":"team"},"faults":{"AAA":{"status":400}}}')
        # 032, C6.4 — declare the destination the way production does. The
        # connection chokepoint sets this variable before any request; a suite
        # that drives the transport directly must stand in for it, or the
        # credential producer rightly refuses a destination nothing verified.
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $base = $script:M.BaseUrl
        $plan = '{"parent":{"method":"POST","url":"' + $base + '/rest/api/3/issue","body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10101"},"summary":"The Epic"}},"local_id":"aaaaaaaaaaaaaaaa","role":"parent"},' +
            '"stories":[{"method":"POST","url":"' + $base + '/rest/api/3/issue","body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10102"},"summary":"A story","parent":{"key":"<resolved at apply time>"}}},"local_id":"1111111111111111","role":"story"}]}'
        $specRef = '{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
        $specFile = Join-Path $TestDrive 'spec2.md'
        Set-Content -LiteralPath $specFile -Value '# Title' -NoNewline

        $result = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $specRef -SpecFile $specFile
        $result.ExitCode | Should -Be 2
        @($result.Created).Count | Should -Be 0
    }

    It 'story rejection: the outcome carries the parent already created, and nothing for the failed story (O1/O2/O3)' {
        $script:M = Start-JiraMock -ConfigPath (New-MockConfig '{"projects":{"AAA":"team","BBB":"team"},"faults":{"BBB":{"status":400}}}')
        # 032, C6.4 — declare the destination the way production does. The
        # connection chokepoint sets this variable before any request; a suite
        # that drives the transport directly must stand in for it, or the
        # credential producer rightly refuses a destination nothing verified.
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $base = $script:M.BaseUrl
        $plan = '{"parent":{"method":"POST","url":"' + $base + '/rest/api/3/issue","body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10101"},"summary":"The Epic"}},"local_id":"aaaaaaaaaaaaaaaa","role":"parent"},' +
            '"stories":[{"method":"POST","url":"' + $base + '/rest/api/3/issue","body":{"fields":{"project":{"key":"BBB"},"issuetype":{"id":"10102"},"summary":"A story"}},"local_id":"1111111111111111","role":"story"}]}'
        $specRef = '{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
        $specFile = Join-Path $TestDrive 'spec3.md'
        Set-Content -LiteralPath $specFile -Value '# Title' -NoNewline

        $result = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $specRef -SpecFile $specFile
        $result.ExitCode | Should -Be 2
        $created = @($result.Created)
        $created.Count | Should -Be 1
        $created[0].role | Should -Be 'parent'
        $created[0].key | Should -Be 'AAA-1'
    }

    It 'O5 — an UPDATE (PUT) never produces a created entry' {
        $script:M = Start-JiraMock -ConfigPath (New-MockConfig '{"projects":{"AAA":"team"},"createdKey":"AAA-9"}')
        # 032, C6.4 — declare the destination the way production does. The
        # connection chokepoint sets this variable before any request; a suite
        # that drives the transport directly must stand in for it, or the
        # credential producer rightly refuses a destination nothing verified.
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $base = $script:M.BaseUrl
        $plan = '{"parent":null,"stories":[{"method":"PUT","url":"' + $base + '/rest/api/3/issue/AAA-9","body":{"fields":{"summary":"Updated"}}}]}'
        $specRef = '{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
        $specFile = Join-Path $TestDrive 'spec4.md'
        Set-Content -LiteralPath $specFile -Value '# Title' -NoNewline

        $result = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson $specRef -SpecFile $specFile
        $result.ExitCode | Should -Be 0
        @($result.Created).Count | Should -Be 0
    }
}
