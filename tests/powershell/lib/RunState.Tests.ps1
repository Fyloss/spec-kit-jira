# T019 [US2] — The run-state short-circuit's document layer (spec FR-019…
# FR-028, contracts/run-state.md, data-model.md §1).
# Pester twin of tests/bash/lib/test_run_state.bats (T018).
#
# git hash-object needs no repository — a plain temp workdir is enough
# (research R7). $env:JIRA_CONFIG_DIR is overridden to an absolute path per
# test, which is fine here: cross-port byte parity for the "inputs" keys is a
# conformance-corpus concern (T020/T021), not this file's.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '../../../scripts/powershell/lib/RunState.psm1'
    Import-Module $ModulePath -Force
}

Describe 'RunState' {
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

    Describe 'New-JiraRunStateDocument — shape and determinism' {
        It 'is deterministic across repeated calls' {
            $a = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $b = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $a | Should -Not -BeNullOrEmpty
            $a | Should -Be $b
        }

        It 'carries exactly the documented top-level fields, and no project_key' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $keys = ($doc | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object
            ($keys -join ',') | Should -Be 'base_url,email,extension_version,field_values,inputs,on_drift,schema'
        }

        It 'schema is the integer 1 at introduction' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $parsed = $doc | ConvertFrom-Json
            [int]$parsed.schema | Should -Be 1
            $doc | Should -Match '"schema":1[,}]'
        }

        It 'carries base_url, email, on_drift, and field_values verbatim' {
            $fv = "KEY=Story=Label=Value`u{1f}KEY=Task=Other=Val"
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'proceed' -FieldValues $fv
            $parsed = $doc | ConvertFrom-Json
            $parsed.base_url | Should -Be 'https://acme.atlassian.net'
            $parsed.email | Should -Be 'user@example.com'
            $parsed.on_drift | Should -Be 'proceed'
            $parsed.field_values | Should -Be $fv
        }

        It 'never contains a credential-shaped string' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $doc | Should -Not -Match 'Authorization'
            $doc | Should -Not -Match 'Basic '
            $doc | Should -Not -Match 'ATATT'
        }
    }

    Describe 'inputs — hashing primitive and presence rules' {
        It 'spec.md is always present, hashed with git hash-object --no-filters' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $want = (& git hash-object --no-filters $script:Spec)
            $got = ($doc | ConvertFrom-Json).inputs.'spec.md'
            $got | Should -Be $want
        }

        It 'tasks.md is omitted when absent, present with its hash when it exists' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $inputs = ($doc | ConvertFrom-Json).inputs
            ($inputs.PSObject.Properties.Name -contains 'tasks.md') | Should -BeFalse

            $tasksPath = Join-Path (Split-Path -Parent $script:Spec) 'tasks.md'
            [System.IO.File]::WriteAllText($tasksPath, "- [ ] T001 do the thing`n")
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $want = (& git hash-object --no-filters $tasksPath)
            $got = ($doc | ConvertFrom-Json).inputs.'tasks.md'
            $got | Should -Be $want
        }

        It 'config.yml, config.local.yml, and personal.yml are each omitted when absent' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $keys = (($doc | ConvertFrom-Json).inputs.PSObject.Properties.Name | Sort-Object) -join ','
            $keys | Should -Be 'spec.md'
        }

        It 'config.yml, config.local.yml, and personal.yml are each present with a hash when they exist' {
            $cfgYml = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
            $cfgLocalYml = Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml'
            $personalYml = Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'
            [System.IO.File]::WriteAllText($cfgYml, "projects: []`n")
            [System.IO.File]::WriteAllText($cfgLocalYml, "overrides: []`n")
            [System.IO.File]::WriteAllText($personalYml, "name: Ada`n")

            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $inputs = ($doc | ConvertFrom-Json).inputs
            $inputs.$cfgYml | Should -Be (& git hash-object --no-filters $cfgYml)
            $inputs.$cfgLocalYml | Should -Be (& git hash-object --no-filters $cfgLocalYml)
            $inputs.$personalYml | Should -Be (& git hash-object --no-filters $personalYml)
        }

        It 'returns $null when spec.md cannot be hashed' {
            $missing = Join-Path $script:Work 'specs/021-example/does-not-exist.md'
            $doc = New-JiraRunStateDocument -SpecPath $missing -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $doc | Should -BeNullOrEmpty
        }
    }

    Describe 'Test-JiraRunStateMatch' {
        It 'is $false when no state file exists' {
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' | Should -BeFalse
        }

        It 'is $true after Save-JiraRunState with the identical inputs' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' | Should -BeTrue
        }

        It 'is $false once spec.md changes' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            [System.IO.File]::WriteAllText($script:Spec, "# Feature Specification: Example (touched)`n")
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' | Should -BeFalse
        }

        It 'is $false once on_drift differs' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'proceed' | Should -BeFalse
        }

        It 'is $false once field_values differs' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -FieldValues 'KEY=Story=Label=New' | Should -BeFalse
        }

        It 'is $false when the recorded file is corrupt JSON' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $recordedPath = Get-JiraRunStatePath -SpecPath $script:Spec
            [System.IO.File]::WriteAllText($recordedPath, 'not json')
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' | Should -BeFalse
        }
    }

    Describe 'Save-JiraRunState' {
        It 'writes a document byte-identical to a fresh compose' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $recorded = [System.IO.File]::ReadAllText((Get-JiraRunStatePath -SpecPath $script:Spec))
            $fresh = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $recorded | Should -Be $fresh
        }

        It 'creates the state directory and its self-ignoring .gitignore' {
            $stateDir = Join-Path $env:JIRA_CONFIG_DIR 'state'
            Test-Path -LiteralPath $stateDir | Should -BeFalse
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            Test-Path -LiteralPath $stateDir | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $stateDir '.gitignore') -Raw).Trim() | Should -Be '*'
        }

        It 'leaves no sibling temp file behind on success' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort'
            $stateDir = Join-Path $env:JIRA_CONFIG_DIR 'state'
            $leftovers = Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp.*' -ErrorAction SilentlyContinue
            $leftovers | Should -BeNullOrEmpty
        }

        It 'never fails the run: a write error is a warning, not an exception' {
            $stateDir = Join-Path $env:JIRA_CONFIG_DIR 'state'
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            $recordedPath = Get-JiraRunStatePath -SpecPath $script:Spec
            # Simulate an unwritable target: occupy the final name with a read-only
            # directory, so the terminal rename step fails without touching
            # filesystem permissions (which `chmod 000` would, on POSIX only).
            New-Item -ItemType Directory -Path $recordedPath -Force | Out-Null
            { Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' } | Should -Not -Throw
        }
    }

    Describe 'Get-JiraRunStatePath' {
        It 'names the recorded document after the spec''s feature directory' {
            $want = Join-Path (Join-Path $env:JIRA_CONFIG_DIR 'state') '021-example.json'
            (Get-JiraRunStatePath -SpecPath $script:Spec) | Should -Be $want
        }
    }

    Describe 'T023 [022] — task_mirror edits invalidate the short-circuit' {
        It 'editing task_mirror in config.yml changes the recorded config.yml hash' {
            $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
            [System.IO.File]::WriteAllText($cfgPath, "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`n")
            $before = (New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -FieldValues '' | ConvertFrom-Json -Depth 10).inputs.$cfgPath
            Add-Content -LiteralPath $cfgPath -Value "task_mirror:`n  CONSUMER: checklist`n"
            $after = (New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -FieldValues '' | ConvertFrom-Json -Depth 10).inputs.$cfgPath
            $after | Should -Not -Be $before
            $expected = (& git hash-object --no-filters $cfgPath 2>$null | Select-Object -First 1).Trim()
            $after | Should -Be $expected
        }
    }
}
