# T018 — Credential resolution (ELIMINATORY NFR-3 / SC-007), PowerShell side.
# Mirror of tests/bash/lib/test_credentials.bats.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../helpers/SecretStoreStub.psm1') -Force
}

Describe 'Credentials' {
    BeforeEach {
        $env:JIRA_API_TOKEN = $null
        $env:_CRED_SECRET_TOKEN = $null
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
        $env:JIRA_CONFIG_DIR = $script:TmpDir
        # Re-import -Force: resets the module's $script:-scoped credential
        # cache (021, US3) to 'unset', the PowerShell proxy for "a fresh
        # process" — module scope has no per-test isolation otherwise.
        Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
    }

    AfterEach {
        $env:JIRA_API_TOKEN = $null
        $env:_CRED_SECRET_TOKEN = $null
        $env:JIRA_CONFIG_DIR = $null
        if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir }
    }

    Context 'Resolve-JiraToken' {
    It 'resolves the token from the environment first' {
        $env:JIRA_API_TOKEN = 'env-token'
        Resolve-JiraToken | Should -Be 'env-token'
    }

    It 'falls back to the gitignored .env when env and secret manager are empty' {
        Set-Content -Path (Join-Path $script:TmpDir '.env') -Value 'JIRA_API_TOKEN=file-token'
        Resolve-JiraToken | Should -Be 'file-token'
    }

    It 'environment token wins over the .env file' {
        Set-Content -Path (Join-Path $script:TmpDir '.env') -Value 'JIRA_API_TOKEN=file-token'
        $env:JIRA_API_TOKEN = 'env-token'
        Resolve-JiraToken | Should -Be 'env-token'
    }

    It "reads an 'export JIRA_API_TOKEN=...' line in .env (dotenv convention)" {
        Set-Content -Path (Join-Path $script:TmpDir '.env') -Value 'export JIRA_API_TOKEN=file-token'
        Resolve-JiraToken | Should -Be 'file-token'
    }

    It 'strips surrounding quotes from the .env value (dotenv convention)' {
        Set-Content -Path (Join-Path $script:TmpDir '.env') -Value 'JIRA_API_TOKEN="file-token"'
        Resolve-JiraToken | Should -Be 'file-token'
        Set-Content -Path (Join-Path $script:TmpDir '.env') -Value "JIRA_API_TOKEN='file-token'"
        Resolve-JiraToken | Should -Be 'file-token'
    }

    It 'strips the carriage return from a Windows-authored (CRLF) .env' {
        [System.IO.File]::WriteAllText((Join-Path $script:TmpDir '.env'), "JIRA_API_TOKEN=file-token`r`n")
        Resolve-JiraToken | Should -Be 'file-token'
    }

    It 'secret manager (mockable) sits between env and .env' {
        Set-Content -Path (Join-Path $script:TmpDir '.env') -Value 'JIRA_API_TOKEN=file-token'
        $env:_CRED_SECRET_TOKEN = 'keychain-token'
        Resolve-JiraToken | Should -Be 'keychain-token'
    }

    It 'returns null when no source provides a token' {
            Resolve-JiraToken | Should -BeNullOrEmpty
        }

        It 'never emits the token on the verbose stream (SC-007)' {
            $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
            $tmp = New-TemporaryFile
            Resolve-JiraToken -Verbose 4> $tmp.FullName | Out-Null
            $trace = Get-Content -Raw $tmp.FullName -ErrorAction SilentlyContinue
            $trace | Should -Not -Match 'RAWSECRETXYZ'
            Remove-Item $tmp.FullName -Force
        }
    }

    # --- T039 [US3] — the per-run credential cache, PowerShell twin of
    # T034/T036/T037/T038 in test_credentials.bats/test_reconcile_credential_cache.bats
    # (contracts/credential-cache.md). No priming function exists on this port
    # (module scope already persists for the process); the BeforeEach re-import
    # above is this file's proxy for "a fresh process".
    Context 'the credential cache' {
        It 'the secret store is consulted exactly once across many resolutions, including a simulated retry (T034)' {
            $counter = Join-Path $script:TmpDir 'secretstore.count'
            Install-SecretStoreStub -CounterFile $counter -Token 'from-the-store'
            1..5 | ForEach-Object { Resolve-JiraToken | Should -Be 'from-the-store' }
            Get-SecretStoreStubCount -CounterFile $counter | Should -Be 1
        }

        It 'the cache is never written to $env: — a child process spawned mid-run inherits no copy of the token (T036)' {
            $env:_CRED_SECRET_TOKEN = 'MID-RUN-SECRET-TOKEN'
            Resolve-JiraToken | Should -Be 'MID-RUN-SECRET-TOKEN'
            $leaked = Get-ChildItem Env: | Where-Object {
                $_.Name -ne '_CRED_SECRET_TOKEN' -and $_.Value -eq 'MID-RUN-SECRET-TOKEN'
            }
            $leaked | Should -BeNullOrEmpty
        }

        It 'credential rotation: two runs pick up two different stub tokens (T037)' {
            $env:_CRED_SECRET_TOKEN = 'token-one'
            Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
            Resolve-JiraToken | Should -Be 'token-one'

            $env:_CRED_SECRET_TOKEN = 'token-two'
            Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
            Resolve-JiraToken | Should -Be 'token-two'
        }

        It "an unresolved outcome caches as 'unresolved', a state distinct from an empty resolved token — the sources are not re-consulted on a second resolve (T037)" {
            $counter = Join-Path $script:TmpDir 'secretstore.count'
            Install-SecretStoreStub -CounterFile $counter -Token $null
            Resolve-JiraToken | Should -BeNullOrEmpty
            Resolve-JiraToken | Should -BeNullOrEmpty
            Get-SecretStoreStubCount -CounterFile $counter | Should -Be 1
        }

        It 'the secret-manager rung returning nothing falls through silently to .env, no error (T038)' {
            Set-Content -Path (Join-Path $script:TmpDir '.env') -Value 'JIRA_API_TOKEN=file-token'
            $counter = Join-Path $script:TmpDir 'secretstore.count'
            Install-SecretStoreStub -CounterFile $counter -Token $null
            { Resolve-JiraToken } | Should -Not -Throw
            Resolve-JiraToken | Should -Be 'file-token'
        }
    }

    Context 'Get-JiraAuthHeader' {
        It 'builds a Basic base64 header that decodes to email:token, raw token absent' {
            $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
            $header = Get-JiraAuthHeader -Email 'user@example.com'
            $header.Authorization | Should -Not -Match 'RAWSECRETXYZ'
            $header.Authorization | Should -Match '^Basic '
            $b64 = $header.Authorization.Substring('Basic '.Length)
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
            $decoded | Should -Be 'user@example.com:RAWSECRETXYZ'
        }
    }

    # --- T069-T072 [US6] — the Windows SecretManagement vault
    # (contracts/credential-cache.md §5). `Get-Secret` does not exist on this
    # host (SecretManagement is not installed), so it is stubbed as a
    # global function first — Pester's `Mock -ModuleName` can only replace a
    # command that already resolves somewhere — then mocked into Credentials'
    # own session state, matching Get-JiraSecretManagerToken's unqualified
    # call site.
    Context 'the Windows SecretManagement vault (US6)' {
        AfterEach {
            Remove-Item Function:\Get-Secret -ErrorAction SilentlyContinue
        }

        It 'resolves the token from a stubbed vault when the environment is absent, and the environment still wins over it (T069)' {
            function global:Get-Secret { 'vault-token' }
            Mock -ModuleName Credentials -CommandName Get-Secret -MockWith { 'vault-token' }
            Resolve-JiraToken | Should -Be 'vault-token'

            Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
            Mock -ModuleName Credentials -CommandName Get-Secret -MockWith { 'vault-token' }
            $env:JIRA_API_TOKEN = 'env-token'
            Resolve-JiraToken | Should -Be 'env-token'
        }

        It 'falls through silently when the SecretManagement module is not installed (T070)' {
            Mock -ModuleName Credentials -CommandName Get-Command -ParameterFilter { $Name -eq 'Get-Secret' } -MockWith { $null }
            { Resolve-JiraToken } | Should -Not -Throw
            Resolve-JiraToken | Should -BeNullOrEmpty
        }

        It 'falls through silently when no vault is registered (T070)' {
            function global:Get-Secret { throw 'No vault is registered as the default vault.' }
            Mock -ModuleName Credentials -CommandName Get-Secret -MockWith { throw 'No vault is registered as the default vault.' }
            { Resolve-JiraToken } | Should -Not -Throw
            Resolve-JiraToken | Should -BeNullOrEmpty
        }

        It 'falls through silently when no secret named spec-kit-jira exists (T070)' {
            function global:Get-Secret { throw 'The secret spec-kit-jira was not found.' }
            Mock -ModuleName Credentials -CommandName Get-Secret -MockWith { throw 'The secret spec-kit-jira was not found.' }
            { Resolve-JiraToken } | Should -Not -Throw
            Resolve-JiraToken | Should -BeNullOrEmpty
        }

        It 'falls through silently and returns rather than waiting when the vault is locked (T070)' {
            function global:Get-Secret { throw 'The vault SecretStore requires a password.' }
            Mock -ModuleName Credentials -CommandName Get-Secret -MockWith { throw 'The vault SecretStore requires a password.' }
            $result = $null
            $elapsed = Measure-Command { $result = Resolve-JiraToken }
            $result | Should -BeNullOrEmpty
            $elapsed.TotalSeconds | Should -BeLessThan 2
        }

        It 'a vault-sourced token never enters $env: and never appears in an active Start-Transcript (T072)' {
            function global:Get-Secret { 'VAULT-SOURCED-SECRET-XYZ' }
            Mock -ModuleName Credentials -CommandName Get-Secret -MockWith { 'VAULT-SOURCED-SECRET-XYZ' }
            $transcriptPath = Join-Path $script:TmpDir 'transcript.txt'
            Start-Transcript -Path $transcriptPath -Force | Out-Null
            try {
                Resolve-JiraToken | Should -Be 'VAULT-SOURCED-SECRET-XYZ'
            } finally {
                Stop-Transcript | Out-Null
            }
            $leaked = Get-ChildItem Env: | Where-Object { $_.Value -eq 'VAULT-SOURCED-SECRET-XYZ' }
            $leaked | Should -BeNullOrEmpty
            (Get-Content -Raw $transcriptPath) | Should -Not -Match 'VAULT-SOURCED-SECRET-XYZ'
        }
    }
}
