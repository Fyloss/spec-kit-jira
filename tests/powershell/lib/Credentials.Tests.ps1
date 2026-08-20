# 030 — Credential resolution (contracts/credential-resolution.md), PowerShell
# side. Mirror of tests/bash/lib/test_credentials.bats. Two rungs: environment
# variable -> operator-declared retrieval command ($env:JIRA_PAT_COMMAND). No
# .env, no hardcoded secret-manager probe. The resolved token NEVER appears in
# argv, logs, errors, or the verbose stream.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../helpers/SecretStoreStub.psm1') -Force
}

Describe 'Credentials' {
    BeforeEach {
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_PAT_COMMAND = $null
        $env:_CRED_SECRET_TOKEN = $null
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
        $script:BinDir = Join-Path $script:TmpDir 'bin'
        $script:Counter = Join-Path $script:TmpDir 'count'
        $env:JIRA_CONFIG_DIR = $script:TmpDir
        # Re-import -Force: resets the module's $script:-scoped credential
        # cache (021, US3) to 'unset', the PowerShell proxy for "a fresh
        # process" — module scope has no per-test isolation otherwise.
        Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
    }

    AfterEach {
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_PAT_COMMAND = $null
        $env:_CRED_SECRET_TOKEN = $null
        $env:JIRA_CONFIG_DIR = $null
        if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir }
        Remove-Item Function:\Get-Secret -ErrorAction SilentlyContinue # NOT Function:\global:Get-Secret — Set-Item honours the global: scope prefix on write, but Remove-Item silently no-ops on it (verified: the function survives), so removal must address the drive by its unqualified name
    }

    Context 'Sources and outcomes (C1.1, C3.1-C3.11)' {
        It 'resolves the token from the environment first (C3.1)' {
            $env:JIRA_API_TOKEN = 'env-token'
            Resolve-JiraToken | Should -Be 'env-token'
        }

        It 'no JIRA_API_TOKEN, command succeeds with non-empty stdout: token resolved (C3.2)' {
            Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 'from-command' | Out-Null
            Resolve-JiraToken | Should -Be 'from-command'
        }

        It 'environment token wins over a declared command, which is never executed (C3.11)' {
            Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 'from-command' | Out-Null
            $env:JIRA_API_TOKEN = 'env-token'
            Resolve-JiraToken | Should -Be 'env-token'
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 0
        }

        It 'the _CRED_SECRET_TOKEN test override stands in for the command, unexecuted' {
            Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 'from-command' | Out-Null
            $env:_CRED_SECRET_TOKEN = 'keychain-token'
            Resolve-JiraToken | Should -Be 'keychain-token'
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 0
        }

        It 'C3.3: neither variable set — failure names both, returns null' {
            Resolve-JiraToken | Should -BeNullOrEmpty
        }

        It 'C3.3 message names JIRA_API_TOKEN and JIRA_PAT_COMMAND' {
            Resolve-JiraToken | Out-Null
            Get-JiraCredentialLastError | Should -Match 'JIRA_API_TOKEN'
            Get-JiraCredentialLastError | Should -Match 'JIRA_PAT_COMMAND'
        }

        It 'C3.4: command not found — message names it and that it could not be executed' {
            $env:JIRA_PAT_COMMAND = 'spec-kit-jira-no-such-helper'
            Resolve-JiraToken | Out-Null
            Get-JiraCredentialLastError | Should -Match 'spec-kit-jira-no-such-helper'
            Get-JiraCredentialLastError | Should -Match 'could not be executed'
        }

        It 'C3.5: command exits non-zero — message names it and the exit status' {
            $prog = Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token '' -ExitCode 3
            Resolve-JiraToken | Out-Null
            $pattern = [regex]::Escape($prog)
            Get-JiraCredentialLastError | Should -Match $pattern
            Get-JiraCredentialLastError | Should -Match 'status 3'
        }

        It 'C3.7: command exits zero with empty stdout — message names it and that output was empty' {
            $prog = Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token ''
            Resolve-JiraToken | Out-Null
            $pattern = [regex]::Escape($prog)
            Get-JiraCredentialLastError | Should -Match $pattern
            Get-JiraCredentialLastError | Should -Match 'produced no output'
        }

        It 'C3.6: command exceeds the bound — message names it and the bound' {
            InModuleScope Credentials { $script:CredBoundSeconds = 1 }
            if ($IsWindows) {
                $env:JIRA_PAT_COMMAND = 'powershell -NoProfile -Command Start-Sleep -Seconds 5'
            } else {
                $env:JIRA_PAT_COMMAND = 'sleep 5'
            }
            Resolve-JiraToken | Out-Null
            Get-JiraCredentialLastError | Should -Match '1s bound'
        }
    }
    # PR review (Copilot, 030): the bound-exceeded path killed the child and
    # returned at once — without reaping it, without letting the two redirected
    # reads settle, and without releasing the Process handle. Measured on macOS:
    # the child itself is reaped by .NET's own SIGCHLD handler and the two pipe
    # descriptors each attempt holds are eventually reclaimed by the finalizer,
    # so the cost is deferred rather than permanent — what the fix buys is
    # deterministic release, which is what the first test below measures (it
    # deliberately does NOT force a collection first). The Bash port has no
    # counterpart defect (it redirects to files it removes and reaps with
    # `wait`), so this is a port-local guard, not a conformance scenario.
    Context 'Child-process hygiene on the bound-exceeded path' {
        BeforeEach {
            # No portable descriptor count on Windows (the .NET HandleCount is
            # 0 on Unix and process-wide on Windows, so it measures neither
            # the same thing nor reliably); these two are POSIX-only.
            $script:CountFds = {
                if (Test-Path "/proc/$PID/fd") { return (Get-ChildItem "/proc/$PID/fd" -Force).Count }
                return (& lsof -p $PID 2> $null | Measure-Object).Count
            }
        }

        It 'releases the child descriptors without waiting for a collection' -Skip:$IsWindows {
            InModuleScope Credentials { $script:CredBoundSeconds = 0.2 }
            [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers(); [System.GC]::Collect()
            $before = & $script:CountFds
            # Get-JiraCredentialFromCommand, not Resolve-JiraToken: the latter
            # caches the failure and would consult its sources only once.
            for ($i = 0; $i -lt 5; $i++) {
                Get-JiraCredentialFromCommand -CommandLine 'sleep 30' | Should -BeNullOrEmpty
            }
            # No collection forced here — pre-fix this reads +10 (the two pipe
            # ends of each attempt, held until the finalizer runs).
            (& $script:CountFds) - $before | Should -BeLessThan 5
        }

        It 'still returns when the command leaves a grandchild holding the pipe' -Skip:$IsWindows {
            New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
            $prog = Join-Path $script:BinDir 'leaves-grandchild'
            # The backgrounded sleep inherits stdout, so the pipe stays open
            # after the direct child is killed: an unbounded drain would block
            # here for as long as the grandchild lives.
            Set-Content -LiteralPath $prog -Value "#!/usr/bin/env bash`nsleep 5 &`nsleep 30`n" -NoNewline
            & chmod +x $prog
            InModuleScope Credentials { $script:CredBoundSeconds = 0.2 }
            $elapsed = Measure-Command { Get-JiraCredentialFromCommand -CommandLine $prog | Should -BeNullOrEmpty }
            $elapsed.TotalSeconds | Should -BeLessThan 5
            Get-JiraCredentialLastError | Should -Match 'bound'
        }
    }


    Context 'Tokenization and secrecy (C2.1-C2.5)' {
        It 'C2.3: interior whitespace preserved, surrounding whitespace (incl. CR) trimmed' {
            New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
            if ($IsWindows) {
                $ps1 = Join-Path $script:BinDir 'spaced.ps1'
                Set-Content -LiteralPath $ps1 -Value '[Console]::Out.Write("  a b  " + [char]13 + [char]10)'
                $env:JIRA_PAT_COMMAND = "powershell -NoProfile -File $ps1"
                # What this test asserts is the TRIMMING, not the bound — C2.5
                # is what pins the 5-second default. Windows PowerShell 5.1's
                # cold start is the slowest thing either port ever spawns, and
                # it does not fit reliably inside 5 s on a loaded runner: this
                # test failed on `windows-latest` at 5.07 s (run 32274698063),
                # where the process was killed at the bound and the assertion
                # then compared '' against 'a b' — a red test naming whitespace
                # for a defect that was never about whitespace. Only the
                # Windows branch is relaxed; the POSIX one still runs the real
                # default against a shell script that starts in milliseconds.
                InModuleScope Credentials { $script:CredBoundSeconds = 60 }
            } else {
                $prog = Join-Path $script:BinDir 'spaced'
                Set-Content -LiteralPath $prog -Value "#!/usr/bin/env bash`nprintf '  a b  \r\n'`n" -NoNewline
                & chmod +x $prog
                $env:JIRA_PAT_COMMAND = $prog
            }
            Resolve-JiraToken | Should -Be 'a b'
        }

        It "C2.4: the command's stderr never contributes to the token's value" {
            New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
            if ($IsWindows) {
                $ps1 = Join-Path $script:BinDir 'noisy.ps1'
                Set-Content -LiteralPath $ps1 -Value "[Console]::Error.WriteLine('leaked-on-stderr'); [Console]::Out.Write('real-token')"
                $env:JIRA_PAT_COMMAND = "powershell -NoProfile -File $ps1"
                # Same exposure as C2.3 above, and for the same reason: this
                # test is about stderr never reaching the token's value, not
                # about the clock. It has not gone red yet only because it lost
                # no race so far.
                InModuleScope Credentials { $script:CredBoundSeconds = 60 }
            } else {
                $prog = Join-Path $script:BinDir 'noisy'
                Set-Content -LiteralPath $prog -Value "#!/usr/bin/env bash`necho leaked-on-stderr >&2`nprintf 'real-token'`n" -NoNewline
                & chmod +x $prog
                $env:JIRA_PAT_COMMAND = $prog
            }
            Resolve-JiraToken | Should -Be 'real-token'
        }

        It 'C2.2: shell metacharacters in JIRA_PAT_COMMAND are inert' {
            $evidence = Join-Path $script:TmpDir 'x'
            $env:JIRA_PAT_COMMAND = "echo a | tee $evidence"
            Resolve-JiraToken | Should -Be "a | tee $evidence"
            Test-Path $evidence | Should -BeFalse
        }

        It 'C2.1: no shell, no eval — a command-substitution-shaped value is never evaluated' {
            $evidence = Join-Path $script:TmpDir 'evidence'
            $env:JIRA_PAT_COMMAND = "echo `$(touch $evidence)"
            Resolve-JiraToken | Out-Null
            Test-Path $evidence | Should -BeFalse
        }

        It 'C2.5: execution is bounded, and the bound is not configurable from a file' {
            InModuleScope Credentials { $script:CredBoundSeconds } | Should -Be 5
        }
    }

    Context 'The .env rung and the hardcoded probe are gone (C1.2, C1.3/C1.3a)' {
        It 'C1.2: a gitignored .env holding a token is never opened — ignored entirely, no message names it' {
            Set-Content -Path (Join-Path $script:TmpDir '.env') -Value 'JIRA_API_TOKEN=file-token'
            Resolve-JiraToken | Should -BeNullOrEmpty
            Get-JiraCredentialLastError | Should -Not -Match '\.env'
        }

        It 'C1.3/C1.3a: a stubbed Get-Secret returning a token is never consulted absent a declared command' {
            Install-SecretStoreStub -CounterFile $script:Counter -Token 'from-the-store'
            Resolve-JiraToken | Should -BeNullOrEmpty
            Get-SecretStoreStubCount -CounterFile $script:Counter | Should -Be 0
        }

        It 'Get-JiraEnvFileToken and Get-JiraSecretManagerToken no longer exist' {
            { InModuleScope Credentials { Get-JiraEnvFileToken } } | Should -Throw
            { InModuleScope Credentials { Get-JiraSecretManagerToken } } | Should -Throw
        }
    }

    Context 'Secrecy (§4)' {
        It 'never emits the token on the verbose stream (SC-007)' {
            $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
            $tmp = New-TemporaryFile
            Resolve-JiraToken -Verbose 4> $tmp.FullName | Out-Null
            $trace = Get-Content -Raw $tmp.FullName -ErrorAction SilentlyContinue
            $trace | Should -Not -Match 'RAWSECRETXYZ'
            Remove-Item $tmp.FullName -Force
        }

        It 'Get-JiraAuthHeader emits Basic auth base64, never the raw token (NFR-3)' {
            $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
            $header = Get-JiraAuthHeader -Email 'user@example.com'
            $header.Authorization | Should -Not -Match 'RAWSECRETXYZ'
            $header.Authorization | Should -Match '^Basic '
            $b64 = $header.Authorization.Substring('Basic '.Length)
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
            $decoded | Should -Be 'user@example.com:RAWSECRETXYZ'
        }

        It "C4.4: a failure report never echoes the command's own stdout" {
            New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
            if ($IsWindows) {
                $ps1 = Join-Path $script:BinDir 'partial.ps1'
                Set-Content -LiteralPath $ps1 -Value "[Console]::Out.Write('PARTIAL-SECRET-ON-STDOUT'); exit 1"
                $env:JIRA_PAT_COMMAND = "powershell -NoProfile -File $ps1"
            } else {
                $prog = Join-Path $script:BinDir 'partial'
                Set-Content -LiteralPath $prog -Value "#!/usr/bin/env bash`nprintf 'PARTIAL-SECRET-ON-STDOUT'`nexit 1`n" -NoNewline
                & chmod +x $prog
                $env:JIRA_PAT_COMMAND = $prog
            }
            Resolve-JiraToken | Out-Null
            Get-JiraCredentialLastError | Should -Not -Match 'PARTIAL-SECRET-ON-STDOUT'
        }

        It 'Get-JiraAuthHeader returns $null on a resolution failure, with the reason in Get-JiraCredentialLastError (C6.2, C6.3)' {
            $header = Get-JiraAuthHeader -Email 'user@example.com'
            $header | Should -BeNullOrEmpty
            Get-JiraCredentialLastError | Should -Match 'credential resolution failed'
        }
    }

    # --- the per-run credential cache (contracts/credential-cache.md). No
    # priming function exists on this port (module scope already persists for
    # the process, so there is no subshell to lose a primed cache to — the
    # Bash port's `cred_prime_cache`/several-`$(...)`-subshells test has no
    # PowerShell twin for that reason); the BeforeEach re-import above is this
    # file's proxy for "a fresh process".
    Context 'the credential cache (C2.6, C5)' {
        It 'the command is consulted exactly once across many resolutions, including a simulated retry' {
            Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token 'from-the-command' | Out-Null
            1..5 | ForEach-Object { Resolve-JiraToken | Should -Be 'from-the-command' }
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 1
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

        It "an unresolved outcome caches as 'unresolved', a state distinct from an empty resolved token — the sources are not re-consulted on a second resolve (C2.6)" {
            $prog = Install-JiraPatCommandStub -BinDir $script:BinDir -CounterFile $script:Counter -Token '' -ExitCode 1
            Resolve-JiraToken | Should -BeNullOrEmpty
            Resolve-JiraToken | Should -BeNullOrEmpty
            Get-JiraPatCommandStubCount -CounterFile $script:Counter | Should -Be 1
        }
    }
}
