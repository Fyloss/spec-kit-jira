# Guard for tests/powershell/helpers/SecretStoreStub.psm1 (030, C7.1 —
# repurposed, not deleted, from feature 021). Pester twin of
# tests/bash/ci/test_secret_store_stub_helper.bats.
#
# Two stand-ins, two claims:
#
#   1. Install-JiraPatCommandStub COUNTS, and Resolve-JiraToken actually
#      REACHES it through $env:JIRA_PAT_COMMAND (C2.6 — at most once per run).
#   2. Install-SecretStoreStub COUNTS, and Resolve-JiraToken NEVER reaches it
#      (C1.3a — the hardcoded probe is gone; a global Get-Secret that would
#      return a token must stay uninvoked).
#
# Test isolation (Constitution XIII): the counter file lives under a path this
# test created, and the count is read from that file — never from a scan of
# the machine.

BeforeAll {
    $ModuleDir = Join-Path $PSScriptRoot '../helpers'
    Import-Module (Join-Path $ModuleDir 'SecretStoreStub.psm1') -Force
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
}

Describe 'SecretStoreStub helper' {
    BeforeEach {
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
        $script:BinDir = Join-Path $script:TmpDir 'bin'
        $script:Counter = Join-Path $script:TmpDir 'pat-command.count'
        $env:_CRED_SECRET_TOKEN = $null
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_PAT_COMMAND = $null
        # Re-import -Force: resets Credentials.psm1's $script:-scoped credential
        # cache (021, US3) to 'unset' so Resolve-JiraToken below is not answered
        # from a previous test's cached token (module scope persists for the
        # whole Pester process — see the same comment in Credentials.Tests.ps1).
        Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
    }

    AfterEach {
        if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir }
        $env:_CRED_SECRET_TOKEN = $null
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_PAT_COMMAND = $null
        Remove-Item Function:\Get-Secret -ErrorAction SilentlyContinue # NOT Function:\global:Get-Secret — Set-Item honours the global: scope prefix on write, but Remove-Item silently no-ops on it (verified: the function survives), so removal must address the drive by its unqualified name
    }

    Context 'Install-JiraPatCommandStub: counts, and is reached' {
        It 'a freshly installed pat-command stub has been consulted zero times' {
            Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 'tok' | Out-Null
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 0
        }

        It 'an absent counter file reads as zero, not as an error' {
            Get-JiraPatCommandStubCount -CounterFile (Join-Path $script:TmpDir 'never-created') | Should -Be 0
        }

        It 'each invocation of the stubbed command is recorded once' {
            $prog = Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 'tok'
            & $prog | Out-Null
            & $prog | Out-Null
            & $prog | Out-Null
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 3
        }

        It 'the stub prints the token it was given' {
            $prog = Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 's3cret'
            (& $prog) | Should -Be 's3cret'
        }

        It 'an empty token stands for C3.7: nothing printed, exit 0' {
            $prog = Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token ''
            $out = & $prog
            $LASTEXITCODE | Should -Be 0
            $out | Should -BeNullOrEmpty
        }

        It 'a non-zero exit code stands for C3.5, and the attempt still counts' {
            $prog = Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token '' -ExitCode 1
            & $prog | Out-Null
            $LASTEXITCODE | Should -Be 1
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 1
        }

        It 'Resolve-JiraToken reaches the stub through JIRA_PAT_COMMAND, and the count is exactly one' {
            Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 'from-the-command' | Out-Null
            Resolve-JiraToken | Should -Be 'from-the-command'
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 1
        }

        It 'Resolve-JiraToken: the environment still wins over a declared command, uninvoked' {
            Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 'from-the-command' | Out-Null
            $env:JIRA_API_TOKEN = 'from-the-env'
            Resolve-JiraToken | Should -Be 'from-the-env'
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 0
        }
    }

    Context 'Install-SecretStoreStub: counts, and is NEVER reached (C1.3a)' {
        It 'a freshly installed secret-store stub has been consulted zero times' {
            Install-SecretStoreStub -CounterFile $script:Counter -Token 'tok'
            Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 0
        }

        It 'each invocation of the stubbed store tool is recorded once' {
            Install-SecretStoreStub -CounterFile $script:Counter -Token 'tok'
            Get-Secret | Out-Null
            Get-Secret | Out-Null
            Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 2
        }

        It 'C1.3a: Resolve-JiraToken with a stubbed Get-Secret in global scope and no JIRA_PAT_COMMAND still fails, uninvoked' {
            Install-SecretStoreStub -CounterFile $script:Counter -Token 'from-the-store'
            { Resolve-JiraToken } | Should -Not -Throw
            Resolve-JiraToken | Should -BeNullOrEmpty
            Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 0
        }
    }
}
