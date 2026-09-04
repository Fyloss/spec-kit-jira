# T013 [Phase 2, 036] — Pester twin of
# tests/bash/sink/test_privacy_guard_artifacts.bats.
#
# The privacy guard over feature-artifact content (036 C5.1–C5.5; FR-016,
# SC-007; Constitution IX).
#
# 036 widens the guard's surface materially: research.md, data-model.md,
# contracts/ and checklists/ become write payloads for the first time.
#
# The binary case is not padding. In the Bash port, raw binary through a shell
# variable made `grep` stop reporting matches at all, so an `ATATT…` token
# appended to a PNG sat in the file, vanished from the payload, and the guard
# returned clear. This port has no grep and could not reproduce that defect —
# but it MUST reach the same verdict on the same bytes (Constitution VI), which
# is why it performs the identical byte normalisation and why the last case
# below compares the two ports directly rather than trusting either alone.

BeforeAll {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $Root 'tests/powershell/helpers/ArtifactFixture.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/engine/ArtifactSet.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/PrivacyGuard.psm1') -Force

    function Add-Line {
        param([string] $Path, [string] $Text)
        $existing = [System.IO.File]::ReadAllText($Path)
        [System.IO.File]::WriteAllText($Path, $existing + $Text + "`n")
    }
    function Add-BinaryToken {
        param([string] $Path, [string] $Token)
        $b = [System.Collections.Generic.List[byte]]::new()
        $b.AddRange([System.IO.File]::ReadAllBytes($Path))
        $b.AddRange([System.Text.Encoding]::ASCII.GetBytes($Token))
        [System.IO.File]::WriteAllBytes($Path, $b.ToArray())
    }
}

Describe 'Get-JiraArtifactPrivacyReason / Test-JiraArtifactPrivacy (036 T013)' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $script:Dir = New-ArtifactFixture -Root $script:Repo
    }

    It 'C5.3 a live Cloud host in research.md blocks, naming that artifact' {
        Add-Line (Join-Path $script:Dir 'research.md') 'see https://acme-real.atlassian.net/browse/X-1'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        $reason = Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set
        $reason | Should -Match 'research\.md'
        $reason | Should -Match 'Atlassian Cloud host'
        (Test-JiraArtifactPrivacy -FeatureDirectory $script:Dir -SetJson $set 2>$null) | Should -Be 9
    }

    It 'C5.3 an API token in research.md blocks, naming that artifact' {
        Add-Line (Join-Path $script:Dir 'research.md') 'token ATATTabc123XYZ456'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        $reason = Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set
        $reason | Should -Match 'research\.md'
        $reason | Should -Match 'ATATT prefix'
    }

    It 'C5.2 a token inside the BINARY artifact blocks, naming the binary' {
        Add-BinaryToken (Join-Path $script:Dir 'assets/diagram.png') 'ATATTdeadbeef99'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        $reason = Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set
        $reason | Should -Match 'assets/diagram\.png'
    }

    It 'C5.3 a token in a NESTED artifact blocks, naming its relative path' {
        Add-Line (Join-Path $script:Dir 'contracts/api.md') 'ATATTzzz99988'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        (Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set) | Should -Match 'contracts/api\.md'
    }

    It 'C5.3 a known coordinate in an artifact blocks' {
        Add-Line (Join-Path $script:Dir 'data-model.md') 'the project lives at acme-internal-coordinate'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        $reason = Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set `
            -KnownCoordinatesJson '["acme-internal-coordinate"]'
        $reason | Should -Match 'data-model\.md'
        $reason | Should -Match 'known coordinate'
    }

    It 'NFR-3 the message names the shape and NEVER the offending value' {
        Add-Line (Join-Path $script:Dir 'research.md') 'token ATATTsecretvalue00099'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        $reason = Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set
        $reason | Should -Match 'ATATT prefix'
        $reason | Should -Not -Match 'ATATTsecretvalue00099'
    }

    It 'SC-007 an allowlisted host inside artifact content neither blocks nor warns' {
        Add-Line (Join-Path $script:Dir 'research.md') 'see https://acme-real.atlassian.net/wiki/spaces/X'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        $reason = Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set `
            -AllowlistJson '["acme-real.atlassian.net"]'
        $reason | Should -BeNullOrEmpty
    }

    It 'FR-053 an allowlist entry never neutralises an UNRELATED token' {
        Add-Line (Join-Path $script:Dir 'research.md') 'https://acme-real.atlassian.net/x and ATATTunrelated999'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        $reason = Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set `
            -AllowlistJson '["acme-real.atlassian.net"]'
        $reason | Should -Match 'ATATT prefix'
    }

    It 'C5.3 a clean artifact set returns nothing and exits 0' {
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        (Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set) | Should -BeNullOrEmpty
        (Test-JiraArtifactPrivacy -FeatureDirectory $script:Dir -SetJson $set) | Should -Be 0
    }

    It 'C5.3 an empty artifact set is clear, not an error' {
        (Test-JiraArtifactPrivacy -FeatureDirectory $script:Dir -SetJson '[]') | Should -Be 0
    }

    It 'Constitution VI both ports reach the SAME verdict on the same bytes' {
        # The assertion the twin exists for. The normalisation the Bash port
        # needs for grep's sake is performed here too, so that a shape found on
        # one port is found on the other — including inside a binary.
        Add-BinaryToken (Join-Path $script:Dir 'assets/diagram.png') 'ATATTdeadbeef99'
        $set = Get-JiraArtifactSet -FeatureDirectory $script:Dir
        $mine = Get-JiraArtifactPrivacyReason -FeatureDirectory $script:Dir -SetJson $set

        $script = @(
            "source '$Root/scripts/bash/engine/artifact_set.sh'",
            "source '$Root/scripts/bash/sink/jira/privacy_guard.sh'",
            "s=`$(artifact_set_build '$($script:Dir)')",
            "privacy_guard_artifact_reason '$($script:Dir)' `"`$s`""
        ) -join "`n"
        $theirs = & bash -c $script

        $theirs | Should -Be $mine
        $mine | Should -Match 'assets/diagram\.png'
    }
}
