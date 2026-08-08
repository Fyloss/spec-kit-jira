# T024 [Phase 4, US2] — Pester twin of tests/bash/lib/test_run_state_concurrency.bats.
# contracts/run-state.md §5: two racing writers each read the whole document
# or none, never half of one. Tested directly at the document layer
# (Save-JiraRunState/Get-JiraRunStatePath/New-JiraRunStateDocument), which
# already exists (T019) — a genuine lock-in test today, not a forward guard.
#
# Constitution XIII test isolation: writers are PowerShell background jobs
# identified only by the $Job object this test itself created and waited on
# — no process-name scan. All file state lives under a per-test temp WORK
# the AfterEach removes.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '../../../scripts/powershell/lib/RunState.psm1'
    Import-Module $ModulePath -Force
}

Describe 'RunState concurrency' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Work 'specs/021-example') -Force | Out-Null
        $script:Spec = Join-Path $script:Work 'specs/021-example/spec.md'
        [System.IO.File]::WriteAllText($script:Spec, "# Feature Specification: Example`n")
    }

    AfterEach {
        Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'T024 — two concurrent writers to the same state path never leave a torn document' {
        $path = Get-JiraRunStatePath -SpecPath $script:Spec
        $writer = {
            param($ModulePath, $Spec, $OnDrift)
            Import-Module $ModulePath
            for ($i = 0; $i -lt 30; $i++) {
                Save-JiraRunState -SpecPath $Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift $OnDrift
            }
        }
        $jobA = Start-Job -ScriptBlock $writer -ArgumentList $ModulePath, $script:Spec, 'abort'
        $jobB = Start-Job -ScriptBlock $writer -ArgumentList $ModulePath, $script:Spec, 'proceed'
        try {
            Wait-Job -Job $jobA, $jobB | Out-Null
            Receive-Job -Job $jobA -ErrorAction Stop | Out-Null
            Receive-Job -Job $jobB -ErrorAction Stop | Out-Null
        }
        finally {
            Remove-Job -Job $jobA, $jobB -Force -ErrorAction SilentlyContinue
        }

        Test-Path -LiteralPath $path | Should -Be $true
        { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } | Should -Not -Throw

        $docA = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
        $docB = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'proceed'
        $content = Get-Content -LiteralPath $path -Raw
        (($content -eq $docA) -or ($content -eq $docB)) | Should -Be $true
    }

    It 'T024 — a reader never observes a torn document while a writer hammers the same path' {
        $path = Get-JiraRunStatePath -SpecPath $script:Spec
        $job = Start-Job -ScriptBlock {
            param($ModulePath, $Spec)
            Import-Module $ModulePath
            for ($i = 0; $i -lt 50; $i++) {
                Save-JiraRunState -SpecPath $Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            }
        } -ArgumentList $ModulePath, $script:Spec

        try {
            $polls = 0
            while ($job.State -eq 'Running' -and $polls -lt 5000) {
                # A read racing the rename may legitimately see "no document
                # yet" (FileNotFoundException) — contract §5 allows "the whole
                # document or none." Only a read that succeeds but returns
                # something ConvertFrom-Json rejects is a torn write.
                $content = $null
                try { $content = [System.IO.File]::ReadAllText($path) } catch { }
                if ($content) {
                    { $content | ConvertFrom-Json } | Should -Not -Throw -Because 'a reader must never observe a torn write'
                }
                $polls++
            }
            Wait-Job -Job $job | Out-Null
            Receive-Job -Job $job -ErrorAction Stop | Out-Null
        }
        finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        Test-Path -LiteralPath $path | Should -Be $true
        { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}
