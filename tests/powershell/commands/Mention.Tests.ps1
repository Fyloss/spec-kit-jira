# T086 [US10] — Editing an existing mentioned ticket, PowerShell side. Mirror of
# tests/bash/commands/test_mention.bats. Cross-port byte agreement of the fetch is
# proven in bats; here we assert the command semantics (FR-049, FR-051).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $script:MockDir = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $CmdDir 'Mention.psm1') -Force
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force

    function Invoke-MentionSummary([string[]] $ArgList) {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraMention -Arguments $ArgList) }
        finally { [Console]::SetOut($orig) }
        return $sw.ToString().Trim()
    }
}

Describe 'Mentioned-ticket editing' {
    BeforeEach {
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-onboarding'
        $env:SPEC_KIT_JIRA_FLAGGED_FIELD_ID = 'customfield_40099'
        $script:Mock = $null
    }
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock }
    }

    It 'stamps identity, updates only that ticket, and logs the mutation (FR-049)' {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/mention.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $obj = Invoke-MentionSummary @('mention', 'MENT-1', '--json') | ConvertFrom-Json
        $obj.command | Should -Be 'mention'
        @($obj.mutations).Count | Should -Be 1
        $obj.mutations[0].ticket | Should -Be 'MENT-1'
        $calls = Get-JiraMockCallLog -Mock $script:Mock
        @($calls | Where-Object { $_ -match '^PUT /rest/api/3/issue/MENT-1/properties/' }).Count | Should -Be 1
    }

    It 'stamps a PARENT-role identity, the only shape recognition accepts' {
        # Invoke-JiraParentRecognition blocks `parent-identity-unverifiable` on any
        # marker whose role is not 'parent'. Stamping without a role bound nothing.
        # Asserted on the call, exactly as the bats twin does: the mock persists a
        # property only for a key it already holds in state.
        Mock -CommandName Set-JiraIdentity -ModuleName Mention -MockWith { return 0 }
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/mention.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $null = Invoke-MentionSummary @('mention', 'MENT-1', '--json')
        Should -Invoke -CommandName Set-JiraIdentity -ModuleName Mention -Times 1 -Exactly `
            -ParameterFilter { $IssueKey -eq 'MENT-1' -and $Origin -eq 'human' -and $Role -eq 'parent' }
    }

    It 'makes zero writes and refuses a ticket claimed by another spec (FR-051)' {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/mention-claimed.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $code = Invoke-JiraMention -Arguments @('mention', 'MENT-1', '--json')
        $code | Should -Be 4
        @(Get-JiraMockCallLog -Mock $script:Mock | Where-Object { $_ -match '^PUT' }).Count | Should -Be 0
    }

    It 'requires an issue key argument' {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/mention.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $code = Invoke-JiraMention -Arguments @('mention', '--json')
        $code | Should -Be 1
    }
}
