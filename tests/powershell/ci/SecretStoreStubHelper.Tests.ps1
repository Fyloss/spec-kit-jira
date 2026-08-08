# T005 — Pester twin of tests/bash/ci/test_secret_store_stub_helper.bats.
# Guard for tests/powershell/helpers/SecretStoreStub.psm1.
#
# SC-004 — "the operating system's secret store is consulted at most once per
# reconcile process" — is asserted by a counter this stub records. Two things
# have to be true before that assertion means anything, and both are tested
# here:
#
#   1. The stub COUNTS. A counter that silently stayed at zero would make
#      SC-004 pass on a bridge that called the vault forty times.
#   2. The stub is actually REACHED through Resolve-JiraToken, not merely
#      through a value seam that returns before the vault call site.
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
        $script:Counter = Join-Path $script:TmpDir 'secret-store.count'
        $env:_CRED_SECRET_TOKEN = $null
        $env:JIRA_API_TOKEN = $null
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
    }

    It 'a freshly installed stub has been consulted zero times' {
        Install-SecretStoreStub -CounterFile $script:Counter -Token 'tok'
        Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 0
    }

    It 'an absent counter file reads as zero, not as an error' {
        Get-SecretStoreStubCount -CounterFile (Join-Path $script:TmpDir 'never-created') | Should -Be 0
    }

    It 'each invocation of the stub is recorded once' {
        Install-SecretStoreStub -CounterFile $script:Counter -Token 'tok'
        InModuleScope Credentials { Get-JiraSecretManagerToken | Out-Null }
        InModuleScope Credentials { Get-JiraSecretManagerToken | Out-Null }
        InModuleScope Credentials { Get-JiraSecretManagerToken | Out-Null }
        Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 3
    }

    It 'the stub returns the token it was given' {
        Install-SecretStoreStub -CounterFile $script:Counter -Token 's3cret'
        InModuleScope Credentials { Get-JiraSecretManagerToken } | Should -Be 's3cret'
    }

    It "a null token stands for 'no entry of that name'" {
        Install-SecretStoreStub -CounterFile $script:Counter -Token $null
        InModuleScope Credentials { Get-JiraSecretManagerToken } | Should -BeNullOrEmpty
    }

    It 'a failing store still counts: the attempt was made' {
        Install-SecretStoreStub -CounterFile $script:Counter -Token $null
        InModuleScope Credentials { Get-JiraSecretManagerToken | Out-Null }
        Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 1
    }

    It 'Resolve-JiraToken reaches the stub and its consultation is counted' {
        Install-SecretStoreStub -CounterFile $script:Counter -Token 'from-the-store'
        Resolve-JiraToken | Should -Be 'from-the-store'
        Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 1
    }

    It 'the environment still wins over the stub, with zero consultations' {
        Install-SecretStoreStub -CounterFile $script:Counter -Token 'from-the-store'
        $env:JIRA_API_TOKEN = 'from-the-env'
        Resolve-JiraToken | Should -Be 'from-the-env'
        Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 0
    }
}
