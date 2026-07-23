# T068 [US6] — Status-category-aware drift classification, PowerShell side.
# Mirror of tests/bash/engine/test_drift.bats. Cross-port byte agreement is proven
# in bats; here we assert the decision semantics (FR-031, FR-034, FR-035).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Drift.psm1') -Force
    $script:Order = '["To Do","In Progress","In Review","Done"]'
    function Invoke-Drift([string] $Cur, [string] $Cat, [string] $Tgt, [string] $OnDrift = 'abort') {
        $in = [ordered]@{
            current_status   = $Cur
            current_category = $Cat
            target_status    = $Tgt
            order            = @('To Do', 'In Progress', 'In Review', 'Done')
            on_drift         = $OnDrift
        } | ConvertTo-Json -Compress -Depth 10
        return (Get-JiraDriftDecision -InputJson $in | ConvertFrom-Json)
    }
}

Describe 'Get-JiraDriftDecision' {
    It 'halts all writes and surfaces two remediations for a halted status (FR-034)' {
        $d = Invoke-Drift 'Blocked' 'halted' 'Done'
        $d.decision | Should -Be 'halt'
        $d.content_writes | Should -BeFalse
        @($d.remediations).Count | Should -Be 2
    }

    It 'withholds an unknown status transition and suggests classifying it (FR-034)' {
        $d = Invoke-Drift 'Investigating' 'unknown' 'Done'
        $d.decision | Should -Be 'withhold'
        $d.content_writes | Should -BeTrue
        $d.warnings[0] | Should -BeLike '*classify*'
    }

    It 'treats an aligned post-scope status as no drift (FR-034)' {
        $d = Invoke-Drift 'Done' 'post-scope' 'Done'
        $d.decision | Should -Be 'transition'
        @($d.warnings).Count | Should -Be 0
    }

    It 'aborts a regressed disk phase against a post-scope ticket by default (FR-035)' {
        $d = Invoke-Drift 'Done' 'post-scope' 'In Progress' 'abort'
        $d.decision | Should -Be 'withhold'
        $d.content_writes | Should -BeTrue
        $d.warnings[0] | Should -BeLike '*--on-drift=proceed*'
    }

    It 'pulls a post-scope ticket backward with --on-drift=proceed (FR-035)' {
        $d = Invoke-Drift 'Done' 'post-scope' 'In Progress' 'proceed'
        $d.decision | Should -Be 'transition'
        @($d.warnings).Count | Should -Be 1
    }

    It 'withholds and names a mapped ticket advanced Jira-side, never silent (FR-031)' {
        $d = Invoke-Drift 'In Review' 'mapped' 'In Progress' 'abort'
        $d.decision | Should -Be 'withhold'
        $d.warnings[0] | Should -BeLike '*drift*'
    }

    It 'pulls a mapped ticket back with --on-drift=proceed (FR-031)' {
        $d = Invoke-Drift 'In Review' 'mapped' 'In Progress' 'proceed'
        $d.decision | Should -Be 'transition'
    }

    It 'transitions a mapped forward move cleanly with no warning' {
        $d = Invoke-Drift 'To Do' 'mapped' 'In Progress'
        $d.decision | Should -Be 'transition'
        @($d.warnings).Count | Should -Be 0
    }
}
