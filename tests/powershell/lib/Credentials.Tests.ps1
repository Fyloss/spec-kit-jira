# T018 — Credential resolution (ELIMINATORY NFR-3 / SC-007), PowerShell side.
# Mirror of tests/bash/lib/test_credentials.bats.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
}

Describe 'Credentials' {
    BeforeEach {
        $env:JIRA_API_TOKEN = $null
        $env:_CRED_SECRET_TOKEN = $null
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
        $env:JIRA_CONFIG_DIR = $script:TmpDir
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
}
