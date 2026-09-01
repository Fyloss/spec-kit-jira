# T019 [US2] — The run-state short-circuit's document layer (spec FR-019…
# FR-028, contracts/run-state.md, data-model.md §1).
# Pester twin of tests/bash/lib/test_run_state.bats (T018).
#
# git hash-object needs no repository — a plain temp workdir is enough
# (research R7). $env:JIRA_CONFIG_DIR is overridden to an absolute path per
# test, which is fine here: cross-port byte parity for the "inputs" keys is a
# conformance-corpus concern (T020/T021), not this file's.

# 036, contracts/run-state-v3.md C2: `inputs` is no longer three fixed
# documents. It is the ARTIFACT SET, supplied as -ArtifactSetJson, so every
# call below passes `(Get-FixtureSet)` — a hand-built set for this fixture,
# since the engine that normally builds one needs a git repository and these
# cases are about the document's OTHER fields. The artifact-set rules
# themselves are covered in RunState.Artifacts.Tests.ps1.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '../../../scripts/powershell/lib/RunState.psm1'
    Import-Module $ModulePath -Force

    # Recomputed on demand, so a test that MUTATES a file gets the new hash.
    function Get-FixtureSet {
        $dir = [System.IO.Path]::GetDirectoryName($script:Spec)
        $out = @()
        foreach ($f in 'spec.md', 'plan.md', 'tasks.md') {
            $p = Join-Path $dir $f
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            $h = (& git hash-object --no-filters $p 2>$null | Select-Object -First 1)
            $out += [ordered]@{ path = $f; hash = [string] $h; size = 0; attachment_name = $f }
        }
        if ($out.Count -eq 0) { return '[]' }
        return (ConvertTo-Json -InputObject @($out) -Depth 5 -Compress)
    }
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
            $a = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $b = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $a | Should -Not -BeNullOrEmpty
            $a | Should -Be $b
        }

        It 'carries exactly the documented top-level fields, and no project_key' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $keys = ($doc | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object
            ($keys -join ',') | Should -Be 'base_url,email,extension_version,field_values,hook_event,inputs,on_drift,schema'
        }

        It 'schema is the integer 3 since 036''s artifact-set inputs (contracts/run-state-v3.md C1)' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $parsed = $doc | ConvertFrom-Json
            [int]$parsed.schema | Should -Be 3
            $doc | Should -Match '"schema":3[,}]'
        }

        It 'hook_event is carried verbatim, empty string when a run has none' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -HookEvent 'after_plan' -ArtifactSetJson (Get-FixtureSet)
            ($doc | ConvertFrom-Json).hook_event | Should -Be 'after_plan'
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            ($doc | ConvertFrom-Json).hook_event | Should -Be ''
        }

        It 'carries base_url, email, on_drift, and field_values verbatim' {
            $fv = "KEY=Story=Label=Value`u{1f}KEY=Task=Other=Val"
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'proceed' -FieldValues $fv -ArtifactSetJson (Get-FixtureSet)
            $parsed = $doc | ConvertFrom-Json
            $parsed.base_url | Should -Be 'https://acme.atlassian.net'
            $parsed.email | Should -Be 'user@example.com'
            $parsed.on_drift | Should -Be 'proceed'
            $parsed.field_values | Should -Be $fv
        }

        It 'never contains a credential-shaped string' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $doc | Should -Not -Match 'Authorization'
            $doc | Should -Not -Match 'Basic '
            $doc | Should -Not -Match 'ATATT'
        }
    }

    Describe 'inputs — hashing primitive and presence rules' {
        It 'spec.md is always present, hashed with git hash-object --no-filters' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $want = (& git hash-object --no-filters $script:Spec)
            $got = ($doc | ConvertFrom-Json).inputs.'spec.md'
            $got | Should -Be $want
        }

        It 'tasks.md is omitted when absent, present with its hash when it exists' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $inputs = ($doc | ConvertFrom-Json).inputs
            ($inputs.PSObject.Properties.Name -contains 'tasks.md') | Should -BeFalse

            $tasksPath = Join-Path (Split-Path -Parent $script:Spec) 'tasks.md'
            [System.IO.File]::WriteAllText($tasksPath, "- [ ] T001 do the thing`n")
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $want = (& git hash-object --no-filters $tasksPath)
            $got = ($doc | ConvertFrom-Json).inputs.'tasks.md'
            $got | Should -Be $want
        }

        It 'plan.md is omitted when absent, present with its hash when it exists (contracts/run-state-v2.md C3)' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $inputs = ($doc | ConvertFrom-Json).inputs
            ($inputs.PSObject.Properties.Name -contains 'plan.md') | Should -BeFalse

            $planPath = Join-Path (Split-Path -Parent $script:Spec) 'plan.md'
            [System.IO.File]::WriteAllText($planPath, "## Summary`n")
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $want = (& git hash-object --no-filters $planPath)
            $got = ($doc | ConvertFrom-Json).inputs.'plan.md'
            $got | Should -Be $want
        }

        It 'config.yml, config.local.yml, and personal.yml are each omitted when absent' {
            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
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

            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $inputs = ($doc | ConvertFrom-Json).inputs
            # The KEY is spelled the way the Bash twin spells it — always a
            # forward slash — not the way Join-Path would spell it on this
            # host. On Windows those two differ, which is the whole point.
            $inputs."$env:JIRA_CONFIG_DIR/config.yml" | Should -Be (& git hash-object --no-filters $cfgYml)
            $inputs."$env:JIRA_CONFIG_DIR/config.local.yml" | Should -Be (& git hash-object --no-filters $cfgLocalYml)
            $inputs."$env:JIRA_CONFIG_DIR/personal.yml" | Should -Be (& git hash-object --no-filters $personalYml)
        }

        It 'spells the config input key by concatenation, never through Join-Path (FR-027)' {
            # Reproduces off Windows what `windows-latest` reported for
            # sc008-deleted-managed-region-restored: Join-Path NORMALISES, and
            # the Bash twin's "${JIRA_CONFIG_DIR}/${f}" does not. A trailing
            # separator on the config dir makes the two disagree on every host
            # — Join-Path collapses it, concatenation keeps it — so this fails
            # on macOS and Linux too, where the separator difference alone
            # cannot be seen. The doubled slash is mirrored rather than tidied
            # for the same reason the target guard mirrors its own: the corpus
            # compares bytes.
            $env:JIRA_CONFIG_DIR = "$env:JIRA_CONFIG_DIR/"
            $cfgYml = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
            [System.IO.File]::WriteAllText($cfgYml, "projects: []`n")

            $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $keys = ($doc | ConvertFrom-Json).inputs.PSObject.Properties.Name
            $keys | Should -Contain "$env:JIRA_CONFIG_DIR/config.yml"
        }

        It 'returns $null when spec.md cannot be hashed' {
            $missing = Join-Path $script:Work 'specs/021-example/does-not-exist.md'
            $doc = New-JiraRunStateDocument -SpecPath $missing -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $doc | Should -BeNullOrEmpty
        }
    }

    Describe 'Test-JiraRunStateMatch' {
        It 'is $false when no state file exists' {
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet) | Should -BeFalse
        }

        It 'is $true after Save-JiraRunState with the identical inputs' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet) | Should -BeTrue
        }

        It 'is $false once spec.md changes' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            [System.IO.File]::WriteAllText($script:Spec, "# Feature Specification: Example (touched)`n")
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet) | Should -BeFalse
        }

        It 'is $false once on_drift differs' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'proceed' -ArtifactSetJson (Get-FixtureSet) | Should -BeFalse
        }

        It 'is $false once field_values differs' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -FieldValues 'KEY=Story=Label=New' -ArtifactSetJson (Get-FixtureSet) | Should -BeFalse
        }

        It 'is $false once hook_event differs — an unhonoured lifecycle event is never skipped (S1, S9)' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -HookEvent 'after_plan' -ArtifactSetJson (Get-FixtureSet) | Should -BeFalse
        }

        It 'is $true after Save-JiraRunState with the identical hook_event' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -HookEvent 'after_plan' -ArtifactSetJson (Get-FixtureSet)
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -HookEvent 'after_plan' -ArtifactSetJson (Get-FixtureSet) | Should -BeTrue
        }

        It 'is $false when the recorded file is corrupt JSON' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $recordedPath = Get-JiraRunStatePath -SpecPath $script:Spec
            [System.IO.File]::WriteAllText($recordedPath, 'not json')
            Test-JiraRunStateMatch -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet) | Should -BeFalse
        }
    }

    Describe 'Save-JiraRunState' {
        It 'writes a document byte-identical to a fresh compose' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $recorded = [System.IO.File]::ReadAllText((Get-JiraRunStatePath -SpecPath $script:Spec))
            $fresh = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            $recorded | Should -Be $fresh
        }

        It 'creates the state directory and its self-ignoring .gitignore' {
            $stateDir = Join-Path $env:JIRA_CONFIG_DIR 'state'
            Test-Path -LiteralPath $stateDir | Should -BeFalse
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
            Test-Path -LiteralPath $stateDir | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $stateDir '.gitignore') -Raw).Trim() | Should -Be '*'
        }

        It 'leaves no sibling temp file behind on success' {
            Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet)
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
            { Save-JiraRunState -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -ArtifactSetJson (Get-FixtureSet) } | Should -Not -Throw
        }
    }

    Describe 'Get-JiraRunStatePath' {
        It 'names the recorded document after the spec''s feature directory' {
            # The expectation is the BASH twin's spelling —
            # `printf '%s/state/%s.json'`, lib/run_state.sh:31 — and not
            # Join-Path's. Written with Join-Path this was a tautology against
            # the very primitive whose renormalisation is the #46 D1 defect:
            # it passed on Windows precisely because both sides were wrong in
            # the same way, while `state_file` reached stdout spelled with
            # backslashes in nine conformance scenarios. The separator between
            # the config dir and `state` comes from the port, so it is the
            # port's `/`; whatever separators the config dir itself carries are
            # the caller's own bytes and are preserved untouched.
            $want = "$env:JIRA_CONFIG_DIR/state/021-example.json"
            (Get-JiraRunStatePath -SpecPath $script:Spec) | Should -Be $want
        }
    }

    Describe 'T023 [022] — task_mirror edits invalidate the short-circuit' {
        It 'editing task_mirror in config.yml changes the recorded config.yml hash' {
            $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
            # $cfgPath REACHES the file; $cfgKey LOOKS IT UP in the recorded
            # document, where the key is spelled with a forward slash on every
            # host to match the Bash twin. On Windows those two strings differ,
            # and using $cfgPath as the key found nothing — both hashes came
            # back $null, which made "changed" trivially false. Green on macOS,
            # red on windows-latest only.
            $cfgKey = "$env:JIRA_CONFIG_DIR/config.yml"
            [System.IO.File]::WriteAllText($cfgPath, "projects:`n  - key: CONSUMER`n    style: company_managed`nrouting_default: CONSUMER`n")
            $before = (New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -FieldValues '' -ArtifactSetJson (Get-FixtureSet) | ConvertFrom-Json -Depth 10).inputs.$cfgKey
            # Fail on a missing key HERE rather than letting two $nulls reach
            # the comparison below, where "changed" is vacuously false and the
            # message names the wrong thing.
            $before | Should -Not -BeNullOrEmpty
            Add-Content -LiteralPath $cfgPath -Value "task_mirror:`n  CONSUMER: checklist`n"
            $after = (New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://acme.atlassian.net' -Email 'user@example.com' -OnDrift 'abort' -FieldValues '' -ArtifactSetJson (Get-FixtureSet) | ConvertFrom-Json -Depth 10).inputs.$cfgKey
            $after | Should -Not -Be $before
            $expected = (& git hash-object --no-filters $cfgPath 2>$null | Select-Object -First 1).Trim()
            $after | Should -Be $expected
        }
    }
}

# --- T162 [Phase 12, US10]: invariant S6 under a NEW event -- a lifecycle
# event that resolves an actual transition. Mirror of test_run_state.bats's
# S6 (T161).

Describe 'Invoke-JiraReconcile — S6, --dry-run under a resolved transition (contracts/run-state-v2.md §5)' {
    BeforeAll {
        $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
        $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
        $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-bound-story-due'
        Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
        Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
        # Re-imported LAST and forced: Reconcile.psm1's own (unforced) import
        # of RunState.psm1 as its dependency can otherwise leave
        # Get-JiraRunStatePath unresolved in this scope (the same defect
        # class as project memory powershell-import-force-clobbers-caller-scope).
        Import-Module $ModulePath -Force

        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

        function Invoke-Captured {
            param([string[]] $ArgList)
            $sw = [System.IO.StringWriter]::new()
            $se = [System.IO.StringWriter]::new()
            $oo = [Console]::Out
            $oe = [Console]::Error
            [Console]::SetOut($sw)
            [Console]::SetError($se)
            try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
            return $sw.ToString() + $se.ToString()
        }
    }

    It '--dry-run under a hook event that resolves a transition neither reads nor writes the state document' {
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $spec = Join-Path $work 'specs/001-declared-mapping/spec.md'
        # 036, contracts/run-state-v3.md: the recorded inputs ARE the artifact
        # set, and the set is `git ls-files` over the feature directory. Outside
        # a repository the set is empty, and an empty set is never recorded and
        # never short-circuits (it would otherwise match the next empty one).
        # Every consumer tree is a repository; this fixture has to be one too,
        # or the state write these cases turn on never happens.
        & git -C $work init --quiet
        & git -C $work config user.email 'fixture@example.invalid'
        & git -C $work config user.name 'fixture'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-declared-mapping'

        $m = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/comp-bound-story-due-seed.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $m.BaseUrl
        try {
            $null = Invoke-Captured @('reconcile', $spec, '--json')

            # The priming run above (no hook event, zero warnings) already
            # recorded state -- so "unwritten" is proven by content staying
            # IDENTICAL across the dry-run, not by the file's absence.
            $stateFile = Get-JiraRunStatePath -SpecPath $spec
            Test-Path -LiteralPath $stateFile | Should -Be $true
            $beforeDry = Get-Content -Raw -LiteralPath $stateFile

            $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
            $null = Invoke-Captured @('reconcile', $spec, '--json', '--dry-run')
            $afterDry = Get-Content -Raw -LiteralPath $stateFile
            $afterDry | Should -Be $beforeDry

            $null = Invoke-Captured @('reconcile', $spec, '--json')
            Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
            $afterReal = Get-Content -Raw -LiteralPath $stateFile
            $afterReal | Should -Not -Be $beforeDry
            (ConvertFrom-Json $afterReal).hook_event | Should -Be 'after_plan'
        }
        finally {
            Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
            Stop-JiraMock -Mock $m
        }
    }
}
