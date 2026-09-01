# T072/T075 [Phase 4, 036] — Pester twin of
# tests/bash/lib/test_run_state_artifacts.bats.
#
# Run state schema 3: the short-circuit considers EVERY artifact, not three
# fixed documents (contracts/run-state-v3.md C1-C5, FR-011, US2 AS4).
#
# WHY THE CONSEQUENCE EXISTS (contract C4). Under schema 2 the recorded inputs
# were `spec.md`, `plan.md` and `tasks.md`. A run fired after only `research.md`
# changed found all three hashes matching, short-circuited, made zero Jira
# calls — and the artifact was never published. The publication feature would
# have been unreachable for exactly the files it exists to add.
#
# The T071 red-proof against the schema-2 module lives in the Bash twin alone:
# it retrieves the previous module from git and runs it, which is a Bash-shaped
# manoeuvre and proves the same historical fact once.

BeforeAll {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $Root 'scripts/powershell/engine/ArtifactSet.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/RunState.psm1') -Force
    Import-Module (Join-Path $Root 'tests/powershell/helpers/ArtifactFixture.psm1') -Force

    function New-Document {
        param([string] $Spec, [string] $Dir)
        return (New-JiraRunStateDocument -SpecPath $Spec -BaseUrl 'https://x.invalid' `
                -Email 'u@example.com' -OnDrift 'abort' -HookEvent '' -FieldValues '' `
                -ArtifactSetJson (Get-JiraArtifactSet -FeatureDirectory $Dir))
    }

    function Save-Document {
        param([string] $Spec, [string] $Dir)
        Save-JiraRunState -SpecPath $Spec -BaseUrl 'https://x.invalid' `
            -Email 'u@example.com' -OnDrift 'abort' -HookEvent '' -FieldValues '' `
            -ArtifactSetJson (Get-JiraArtifactSet -FeatureDirectory $Dir)
    }

    function Test-Document {
        param([string] $Spec, [string] $Dir)
        return (Test-JiraRunStateMatch -SpecPath $Spec -BaseUrl 'https://x.invalid' `
                -Email 'u@example.com' -OnDrift 'abort' -HookEvent '' -FieldValues '' `
                -ArtifactSetJson (Get-JiraArtifactSet -FeatureDirectory $Dir))
    }
}

Describe 'Run state schema 3 — the inputs are the artifact set (036)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $script:FeatureDir = New-ArtifactFixture -Root $script:Work -Name '001-artifacts'
        $script:Spec = Join-Path $script:FeatureDir 'spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: COMP`n")
    }

    AfterEach {
        Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
    }

    It 'C1 the recorded schema is 3' {
        # The set of recorded inputs changed, which is the module's own stated
        # rule for a bump. Every schema-2 file is thereby invalidated, and the
        # first run after an upgrade does real work — correct, because those
        # artifacts are published and no record says so.
        $doc = New-Document -Spec $script:Spec -Dir $script:FeatureDir | ConvertFrom-Json
        $doc.schema | Should -Be 3
    }

    It 'C1 a recorded schema-2 document does not match, so the next run proceeds' {
        Save-Document -Spec $script:Spec -Dir $script:FeatureDir
        $recorded = Get-JiraRunStatePath -SpecPath $script:Spec
        $text = [System.IO.File]::ReadAllText($recorded) -replace '"schema":3', '"schema":2'
        [System.IO.File]::WriteAllText($recorded, $text)

        (Test-Document -Spec $script:Spec -Dir $script:FeatureDir) | Should -BeFalse
    }

    It 'C3.1 every artifact of the directory is an input key' {
        $inputs = (New-Document -Spec $script:Spec -Dir $script:FeatureDir | ConvertFrom-Json).inputs
        foreach ($p in (Get-ArtifactFixtureExpectedPath)) {
            $inputs.PSObject.Properties.Name | Should -Contain $p
        }
    }

    It 'C3.1 a git-ignored file is NOT an input key' {
        # The set is `git ls-files --exclude-standard`, so an ignored file is
        # not an artifact — and a document that hashed it would invalidate on
        # every editor save.
        $inputs = (New-Document -Spec $script:Spec -Dir $script:FeatureDir | ConvertFrom-Json).inputs
        $inputs.PSObject.Properties.Name | Should -Not -Contain 'editor.log'
        $inputs.PSObject.Properties.Name | Should -Not -Contain 'scratch/notes.md'
    }

    It 'C3.3 artifact input paths are relative and /-separated, never absolute' {
        # The document is byte-compared across ports and machines, so a `\`
        # separator or an absolute path would make it match only on the machine
        # that wrote it. This is the assertion the PowerShell port has to work
        # for: Join-Path renormalises to `\` on Windows, and the set is built
        # by string work rather than by a path provider for exactly that reason.
        #
        # SCOPED TO THE ARTIFACT KEYS, exactly as the Bash twin is. The three
        # configuration keys beside them are spelled `$configDir/<file>`
        # verbatim and have been since schema 1, so on Windows they carry the
        # backslashes $env:TEMP is spelled with. Sweeping every key for `\`
        # therefore passed on macOS — where the temp path has none — and failed
        # on windows-latest against keys this test was never about. Measured on
        # the real runner, which is the only place that difference exists.
        $inputs = (New-Document -Spec $script:Spec -Dir $script:FeatureDir | ConvertFrom-Json).inputs
        $inputs.PSObject.Properties.Name | Should -Contain 'contracts/api.md'
        foreach ($p in (Get-ArtifactFixtureExpectedPath)) {
            $p | Should -Not -Match '\\'
            $inputs.PSObject.Properties.Name | Should -Contain $p
        }
    }

    It 'C3.6 a set the module cannot read returns $null' {
        $doc = New-JiraRunStateDocument -SpecPath $script:Spec -BaseUrl 'https://x.invalid' `
            -Email 'u@example.com' -OnDrift 'abort' -ArtifactSetJson 'not json at all'
        $doc | Should -BeNullOrEmpty
    }

    It 'C4 FR-011 changing ONLY research.md invalidates the state — the run proceeds' {
        # The assertion the feature rests on. Under schema 2 all three recorded
        # hashes still matched and the run short-circuited with zero Jira calls,
        # leaving research.md unpublished forever.
        Save-Document -Spec $script:Spec -Dir $script:FeatureDir
        (Test-Document -Spec $script:Spec -Dir $script:FeatureDir) | Should -BeTrue

        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'research.md'),
            "# Phase 0 — Research`n`nA decision recorded after the last run.`n")

        (Test-Document -Spec $script:Spec -Dir $script:FeatureDir) | Should -BeFalse
    }

    It 'C4 a NEW artifact — a checklist that did not exist — invalidates the state' {
        # The `after_checklist` scenario at the state layer: a file appearing is
        # a change to the key SET, which schema 2 could not represent at all.
        Save-Document -Spec $script:Spec -Dir $script:FeatureDir
        [System.IO.File]::WriteAllText((Join-Path $script:FeatureDir 'checklists/ux.md'),
            "# Checklist: UX`n- [x] Understandable`n")

        (Test-Document -Spec $script:Spec -Dir $script:FeatureDir) | Should -BeFalse
    }

    It 'C4 a genuinely unchanged directory still matches — the short-circuit survives' {
        # The other half. A schema that invalidated on every run would make the
        # short-circuit useless and every reconcile expensive.
        Save-Document -Spec $script:Spec -Dir $script:FeatureDir
        (Test-Document -Spec $script:Spec -Dir $script:FeatureDir) | Should -BeTrue
    }

    It 'both ports compose the identical inputs map for one fixture (Principle VI)' {
        # Byte equivalence where it is cheapest to check: the `inputs` object.
        # The two ports build it from the same artifact set through completely
        # different JSON machinery, and the whole short-circuit is a byte
        # comparison of the document they produce.
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'no bash on this host'
            return
        }
        $mine = (New-Document -Spec $script:Spec -Dir $script:FeatureDir | ConvertFrom-Json).inputs |
        ConvertTo-Json -Depth 5 -Compress

        $prog = 'cd "$1" && source scripts/bash/engine/artifact_set.sh && ' +
        'source scripts/bash/lib/run_state.sh && ' +
        'export JIRA_CONFIG_DIR="$4" && ' +
        'run_state_compose "$2" "https://x.invalid" "u@example.com" "abort" "" "" ' +
        '"$(artifact_set_build "$3")" | jq -c ".inputs"'
        $theirs = & bash -c $prog '_' $Root $script:Spec $script:FeatureDir $env:JIRA_CONFIG_DIR

        # Compared as parsed objects rather than as strings: both ports
        # canonicalise, but only the Bash port's output has passed through jq's
        # own number/escape rendering, and this assertion is about the map's
        # CONTENT rather than about two JSON writers agreeing on whitespace.
        $theirsObj = ($theirs -join '') | ConvertFrom-Json
        foreach ($k in ($mine | ConvertFrom-Json).PSObject.Properties.Name) {
            $theirsObj.PSObject.Properties.Name | Should -Contain $k
            $theirsObj.$k | Should -Be (($mine | ConvertFrom-Json).$k)
        }
    }
}
