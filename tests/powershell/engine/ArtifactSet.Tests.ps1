# T006 [Phase 2, 036] — Pester twin of tests/bash/engine/test_artifact_set.bats
# (036 data-model.md §1; research R4/R5/R7; FR-001, FR-005, FR-007, FR-023).
#
# The twin exists to prove the two ports emit the SAME set, in the SAME order,
# for the same directory. Order is not cosmetic: the manifest, the comment body
# and the multipart part list are all derived from it, so a divergence here
# becomes a divergence in every Jira artifact the feature writes.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $script:Root 'tests/powershell/helpers/ArtifactFixture.psm1') -Force
    Import-Module (Join-Path $script:Root 'scripts/powershell/engine/ArtifactSet.psm1') -Force
}

Describe 'Get-JiraArtifactSet' {

    BeforeEach {
        $script:Repo = Join-Path ([System.IO.Path]::GetTempPath()) ("as-" + [guid]::NewGuid().ToString('N'))
        New-ArtifactRepo -Root $script:Repo
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:Repo) {
            Remove-Item -LiteralPath $script:Repo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'data-model §1 holds every non-ignored file, at any depth' {
        $dir = New-ArtifactFixture -Root $script:Repo
        $set = Get-JiraArtifactSet -FeatureDirectory $dir | ConvertFrom-Json
        $paths = @($set | ForEach-Object { $_.path })
        $paths | Should -Be (Get-ArtifactFixtureExpectedPath)
    }

    It 'FR-007 a file the repository ignores is absent from the set' {
        $dir = New-ArtifactFixture -Root $script:Repo
        $set = Get-JiraArtifactSet -FeatureDirectory $dir | ConvertFrom-Json
        $paths = @($set | ForEach-Object { $_.path })
        $paths | Should -Not -Contain 'editor.log'
        $paths | Should -Not -Contain 'scratch/notes.md'
    }

    It 'FR-001 a nested artifact is found at depth two' {
        $dir = New-ArtifactFixture -Root $script:Repo
        Write-FixtureText -Path (Join-Path $dir 'contracts/v2/deep.md') -Lines @('deep')
        $set = Get-JiraArtifactSet -FeatureDirectory $dir | ConvertFrom-Json
        @($set | ForEach-Object { $_.path }) | Should -Contain 'contracts/v2/deep.md'
    }

    It 'data-model §1 sorted byte-wise on path, so a capital precedes a lowercase' {
        $dir = New-ArtifactFixture -Root $script:Repo
        Write-FixtureText -Path (Join-Path $dir 'Zebra.md') -Lines @('z')
        Write-FixtureText -Path (Join-Path $dir 'apple.md') -Lines @('a')
        $set = Get-JiraArtifactSet -FeatureDirectory $dir | ConvertFrom-Json
        $paths = @($set | ForEach-Object { $_.path })
        $paths.IndexOf('Zebra.md') | Should -BeLessThan $paths.IndexOf('apple.md')
    }

    It 'FR-005 a top-level artifact keeps its exact filename' {
        $dir = New-ArtifactFixture -Root $script:Repo
        $set = Get-JiraArtifactSet -FeatureDirectory $dir | ConvertFrom-Json
        ($set | Where-Object { $_.path -eq 'spec.md' }).attachment_name | Should -Be 'spec.md'
        ($set | Where-Object { $_.path -eq 'data-model.md' }).attachment_name | Should -Be 'data-model.md'
    }

    It 'FR-005 a nested artifact flattens its path with a double underscore' {
        $dir = New-ArtifactFixture -Root $script:Repo
        $set = Get-JiraArtifactSet -FeatureDirectory $dir | ConvertFrom-Json
        @($set | ForEach-Object { $_.attachment_name }) | Should -Be (Get-ArtifactFixtureExpectedName)
    }

    It 'FR-005 a two-level nesting flattens every separator' {
        Convert-JiraArtifactPathToName -Path 'checklists/ux/a.md' | Should -Be 'checklists__ux__a.md'
    }

    It 'data-model §1 each entry carries the git hash of its own bytes' {
        $dir = New-ArtifactFixture -Root $script:Repo
        $set = Get-JiraArtifactSet -FeatureDirectory $dir | ConvertFrom-Json
        $want = (& git hash-object --no-filters (Join-Path $dir 'spec.md')).Trim()
        ($set | Where-Object { $_.path -eq 'spec.md' }).hash | Should -Be $want
    }

    It 'data-model §1 the binary artifact keeps its real bytes' {
        $dir = New-ArtifactFixture -Root $script:Repo
        $set = Get-JiraArtifactSet -FeatureDirectory $dir | ConvertFrom-Json
        $entry = $set | Where-Object { $_.path -eq 'assets/diagram.png' }
        $want = (& git hash-object --no-filters (Join-Path $dir 'assets/diagram.png')).Trim()
        $entry.hash | Should -Be $want
        $entry.size | Should -Be 64
    }

    It 'data-model §1 a path is relative and never absolute' {
        $dir = New-ArtifactFixture -Root $script:Repo
        $json = Get-JiraArtifactSet -FeatureDirectory $dir
        $json | Should -Not -Match ([regex]::Escape($script:Repo))
        (($json | ConvertFrom-Json) | Where-Object { $_.path.StartsWith('/') }) | Should -BeNullOrEmpty
    }

    It 'data-model §1 an empty feature directory yields an empty set, not an error' {
        $dir = Join-Path $script:Repo 'specs/empty'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Get-JiraArtifactSet -FeatureDirectory $dir | Should -Be '[]'
    }

    It 'FR-005 two artifacts flattening to one name are BOTH reported' {
        $dir = New-ArtifactFixture -Root $script:Repo
        Write-FixtureText -Path (Join-Path $dir 'contracts/collide.md') -Lines @('x')
        Write-FixtureText -Path (Join-Path $dir 'contracts__collide.md') -Lines @('z')
        $set = Get-JiraArtifactSet -FeatureDirectory $dir
        $lines = @(Get-JiraArtifactNameCollision -SetJson $set)
        $lines.Count | Should -BeGreaterThan 0
        ($lines -join "`n") | Should -Match 'contracts/collide\.md'
        ($lines -join "`n") | Should -Match 'contracts__collide\.md'
    }

    It 'FR-005 a set with no colliding name reports nothing' {
        $dir = New-ArtifactFixture -Root $script:Repo
        $set = Get-JiraArtifactSet -FeatureDirectory $dir
        @(Get-JiraArtifactNameCollision -SetJson $set) | Should -BeNullOrEmpty
    }

    It 'Principle VI the emitted JSON is byte-identical to the Bash port for the same fixture' {
        # The assertion the whole twin exists for. The Bash port builds the same
        # fixture in its own repository and emits its own canonical JSON; the two
        # documents must be the same bytes, key order included.
        $dir = New-ArtifactFixture -Root $script:Repo
        $mine = Get-JiraArtifactSet -FeatureDirectory $dir

        $bashRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("as-bash-" + [guid]::NewGuid().ToString('N'))
        try {
            $script = @(
                "source '$($script:Root)/tests/bash/helpers/artifact_fixture.bash'",
                "source '$($script:Root)/scripts/bash/engine/artifact_set.sh'",
                "d=`$(helper_make_artifact_fixture '$bashRepo')",
                'artifact_set_build "$d"'
            ) -join "`n"
            $theirs = & bash -c $script
            $theirs | Should -Be $mine
        }
        finally {
            if (Test-Path -LiteralPath $bashRepo) {
                Remove-Item -LiteralPath $bashRepo -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
