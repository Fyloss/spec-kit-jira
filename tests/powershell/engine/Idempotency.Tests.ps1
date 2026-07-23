# T072 [US6] — Zero-churn idempotency diff, PowerShell side.
# Mirror of tests/bash/engine/test_idempotency.bats. Cross-port byte agreement is
# proven in bats; here we assert the decision semantics (FR-030).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Idempotency.psm1') -Force
    $script:Begin = '<!-- x:begin -->'
    $script:End = '<!-- x:end -->'
}

Describe 'Test-JiraIdempotentEqual' {
    It 'is ordinal byte equality' {
        Test-JiraIdempotentEqual 'abc' 'abc' | Should -BeTrue
        Test-JiraIdempotentEqual 'abc' 'abC' | Should -BeFalse
    }
}

Describe 'Get-JiraIdempotentFieldStatus' {
    It 'is unchanged when every desired key already matches (key-order independent)' {
        $cur = '{"summary":"Title","priority":{"id":"2"},"extra":"kept"}'
        $des = '{"priority":{"id":"2"},"summary":"Title"}'
        Get-JiraIdempotentFieldStatus -CurrentFieldsJson $cur -DesiredFieldsJson $des | Should -Be 'unchanged'
    }

    It 'is changed when any desired value differs' {
        $cur = '{"summary":"Old","priority":{"id":"2"}}'
        $des = '{"summary":"New","priority":{"id":"2"}}'
        Get-JiraIdempotentFieldStatus -CurrentFieldsJson $cur -DesiredFieldsJson $des | Should -Be 'changed'
    }

    It 'is changed when a desired key is absent from current' {
        Get-JiraIdempotentFieldStatus -CurrentFieldsJson '{"summary":"Title"}' -DesiredFieldsJson '{"priority":{"id":"2"}}' | Should -Be 'changed'
    }
}

Describe 'Get-JiraIdempotentManagedStatus' {
    It 'is unchanged when the splice is a no-op' {
        $block = "$script:Begin`nbody line`n$script:End"
        $host0 = "prelude`n$block`nepilogue`n"
        $r = Get-JiraIdempotentManagedStatus -BeginToken $script:Begin -EndToken $script:End -NewBlock $block -Text $host0
        $r.ExitCode | Should -Be 0
        $r.Status | Should -Be 'unchanged'
    }

    It 'is changed when the block body differs' {
        $host0 = "prelude`n$script:Begin`nold body`n$script:End`n"
        $newBlock = "$script:Begin`nnew body`n$script:End"
        $r = Get-JiraIdempotentManagedStatus -BeginToken $script:Begin -EndToken $script:End -NewBlock $newBlock -Text $host0
        $r.ExitCode | Should -Be 0
        $r.Status | Should -Be 'changed'
    }

    It 'refuses malformed markers with exit 4 and no status' {
        $host0 = "$script:Begin`na`n$script:Begin`nb`n$script:End`n"
        $newBlock = "$script:Begin`nx`n$script:End"
        $r = Get-JiraIdempotentManagedStatus -BeginToken $script:Begin -EndToken $script:End -NewBlock $newBlock -Text $host0 2>$null
        $r.ExitCode | Should -Be 4
        $r.Status | Should -Be ''
    }
}
